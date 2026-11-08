# Node Modules: design

Date: 2026-11-08
Owner: Hugh Herschell (single user, single Mac)

## Why

The Mac's data volume is 95% full (24 GB free of 460 GB). JavaScript projects under
`/Users/hughherschell/Developer` hold about 7.85 GB of `node_modules`, and many of
them contain the same package versions. Storage is the only motivation, not install
speed or download volume.

Measured on 2026-11-08:

- About **2.8 GB** of `node_modules` content is byte-identical duplicates of other files.
- Build caches (`.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`, `.cache`) total about
  **12.6 GB**. `.next` alone is about 4.7 GB, 4 GB of it in `spin-and-gears`. `.output`
  (about 660 MB) is excluded; see below.
- There are no Time Machine local snapshots, so freed blocks are returned right away.

## What it is

A native macOS app called **Node Modules**, made of three pieces that share one core:

1. **Background helper.** Starts at login, has no Dock or menu bar presence, and does all
   scheduled work.
2. **The app.** A normal windowed app opened from Applications or Spotlight to see what
   has happened and to run jobs manually. Closing it does not stop the helper.
3. **A `nodemodules` terminal command** for the same manual actions.

It reclaims space two ways:

- **Dedupe.** Identical files across all `node_modules` trees become APFS clones of one
  another. Every project keeps its own real `node_modules` folder with every file in
  place, but identical files share physical blocks on disk. APFS clones are copy-on-write:
  if any project later modifies a cloned file, that file silently gets its own blocks, so
  one project can never affect another.
- **Build cache clearing.** Once a week, regenerable build-cache folders are deleted.

### The key property: nothing about the projects changes

Projects are not configured, edited, or converted. `package.json`, lockfiles, and
package-manager commands (npm, pnpm, yarn, bun) stay exactly as they are. Nothing is
committed. On GitHub or another machine, `npm install` behaves as it always has, because
the app acts on the files on this disk from outside the projects. This is how the
original requirement ("only runs on my machine, normal behaviour everywhere else") is met.

## Goals

- Free as much disk space as is safe, automatically, with no change to how Hugh works.
- Pick up new projects added under `~/Developer` without any setup.
- Let Hugh see what it has done (space freed, per project, history) and run either job on
  demand from the app or the terminal.
- Notify Hugh when a run frees space or something goes wrong.

## Non-goals

- Changing package managers or project configuration (pnpm-style shared stores were
  considered and rejected in favour of this approach).
- Deleting whole `node_modules` folders of old or inactive projects.
- Touching anything outside `/Users/hughherschell/Developer`.
- Clearing `dist`, `build`, or other output folders a project might ship or deploy from.
- Python environments, `.venv`, or non-JavaScript artifacts (e.g. `ACE-Step-1.5`'s Python side).
- Speeding up installs.
- A menu bar icon.

## Anti-goals (failure even if it "works")

- **Any project breaks** or behaves differently after dedupe or clearing. Correctness of
  file contents, permissions, and executability beats space saved.
- Touching a file while a package manager is still writing to it.
- Deleting anything that does not regenerate itself, or anything tracked in git.
- Clearing caches out from under a project Hugh is actively working on (e.g. a running
  dev server).
- Notification spam.
- Leaving anything behind that breaks projects if the app is removed. Cloned files are
  ordinary files, so uninstalling must leave every project working.

## Behaviour

### Projects

A project is any directory under `~/Developer`, at any depth, that contains a
`package.json` and is not itself inside a `node_modules` tree or a build-cache folder.
Examples: `linkbreeze`, `artwork-kenya/functions`, `forex-system/dashboard`,
`Open Design/<uuid>`. Paths contain spaces (`MAgPIE Studio`, `Lightroom `, with a
trailing space) and must be handled correctly.

- **Python environments are excluded** (my call). `package.json` files inside `.venv`,
  `venv`, and similar folders are not projects. One example is
  `ACE-Step-1.5/.venv/.../gradio`.
- **Nested projects count toward their parent** (my call). Activity in a nested project
  (e.g. `artwork-kenya/functions`) counts as activity for the project that contains it,
  for the 24-hour rule.
- **Projects without git** (my call). 11 top-level folders have no git repo. For them
  the git check doesn't apply, and the standard cache folders are still cleared.

### Dedupe

- **Scope:** regular files inside any `node_modules` tree under `~/Developer`, including
  duplicates within a single project.
- **Skip:**
  - symlinks
  - empty files
  - files with a hard-link count above 1 (pnpm projects hard-link into the pnpm store;
    cloning one would break that link and free nothing)
  - files on a different volume from the copy they would be cloned from
  - files already sharing blocks with their match. APFS exposes this through
    `getattrlist` clone-id and extended-flag attributes; the builder should use whatever
    reliable signal exists so repeat sweeps are cheap.
- **Matching:** files are identical only if their size and full-content hash match. The
  hash must be cryptographic (e.g. SHA-256 via CryptoKit). Cache hashes, keyed by path,
  inode, size, and mtime, so the daily sweep doesn't re-read unchanged files.
- **Replacing a duplicate must be atomic and lossless:**
  1. Clone the keeper file to a temporary name in the duplicate's directory.
  2. Give the clone the duplicate's mode, owner, timestamps, and extended attributes.
  3. Rename it over the duplicate.

  A failure at any step leaves the original untouched, and no temp files are left behind.
- **Not while installing:** a `node_modules` tree is processed only once it has been quiet
  (no file-system events) for about 60 seconds, and files modified in the last 60 seconds
  are skipped.
- **When:**
  - **After installs:** the helper watches `~/Developer` (FSEvents) and dedupes a project
    after an install or other change in its `node_modules` settles.
  - **Daily:** a full sweep across all projects.
  - **On demand:** from the app or the CLI.
- **Dry run:** `nodemodules dedupe --dry-run` reports what would be freed without
  changing anything.

### Build cache clearing

- **Folders cleared:**
  - at a project's root: `.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`, `.cache`
  - **never `.output`** (Hugh's decision). Several projects deploy from it: Firebase in
    `ej-and-associates`, `hugh-herschell-folio`, `magpie_executive_web` and
    `artwork-kenya`, and Cloudflare in `MAgPIE Studio`. `hugh-herschell-folio`'s `start`
    script runs from it, and `magpie_executive_web`'s `deploy-app` patches files inside
    it before deploying.
  - inside `node_modules`: `node_modules/.cache` and `node_modules/.vite` (my call; both
    are tool caches that regenerate)
- **Skip a folder if:**
  - **Tracked in git:** any file inside it is tracked by git in the project's repository.
  - **Recent activity:** the project has had activity in the last 24 hours, meaning any
    file in the project, including the build folder itself but excluding `.git`, was
    modified in that window. This protects running dev servers, which write to `.next`
    continuously.
- **Deletion:** permanent, not moved to the Trash (my call). These folders regenerate, and
  the Trash would not free space until emptied.
- **When:**
  - **Weekly:** if the Mac was asleep or off at the scheduled time, the job runs as soon
    as it's overdue.
  - **On demand:** from the app or the CLI. Manual runs follow the same skip rules.

### Notifications

- **After a run that freed space:** one notification per run with the amount freed, e.g.
  "Freed 340 MB after install in linkbreeze" or "Weekly cleanup freed 4.2 GB".
- **On errors:** a notification for errors that need Hugh's attention.
- **Silent runs:** runs that freed nothing don't notify.
- **Bursts:** several automatic runs close together are coalesced into one notification.
- **Toggle:** the app can turn notifications off.

### The app

A standard SwiftUI window. It shows:

- **Space reclaimed:** total all-time, split between dedupe and cache clearing, plus the
  drive's current free space.
- **Per-project table:**
  - project path
  - `node_modules` logical size
  - bytes shared via dedupe
  - build-cache size
  - last activity
  - whether it was skipped and why, e.g. "active in last 24h" or "tracked in git"
- **Schedule:** last run and next scheduled run for each job.
- **History:** a log of recent runs showing what ran, when, how much was freed, and any
  errors.
- **Controls:**
  - Run dedupe now
  - Clear build outputs now
  - Pause/Resume the helper
  - notifications on/off
- **Helper status:** whether the helper is running. If it isn't, the app offers to start
  or reinstall it.

Finder's "Get Info" will keep showing each `node_modules` at full size, because it sums
logical sizes. The app must explain the difference and report real freed space.

### The `nodemodules` command

Installed into `~/.local/bin`, which is already on Hugh's `PATH`. Subcommands:

- `status`: summary of the same numbers the app shows
- `dedupe [--dry-run]`
- `clean [--dry-run]`
- `pause` and `resume`
- `log`
- `uninstall`: removes the helper and the command; projects stay intact

Manual runs started from the CLI or the app show up in the app's history like any other
run.

## Constraints

- macOS 27 on Apple silicon, APFS data volume. Xcode 27.2 and Swift 6.4 are installed.
- `~/Developer` is not a privacy-protected folder, so Full Disk Access should not be needed.
- Single user, local build, no distribution, no App Store. Ad-hoc or personal-team signing
  is fine.
- **One job at a time:** jobs from the helper, app, and CLI must never run concurrently.
- **Shared state:** the app, helper, and CLI share state (history, totals, settings, hash
  cache) in `~/Library/Application Support/Node Modules/`.
- **Source location:** `/Users/hughherschell/Developer/Node Modules`, as a local git repo
  with no remote. Nothing gets pushed.
- **Notifications need a bundle:** UNUserNotificationCenter only works for code inside an
  app bundle, so the helper must be bundled, e.g. as a background-only login-item app
  inside the main app.

## Left to the builder

- **Launch mechanism:** how the helper starts at login, either `SMAppService` or a
  LaunchAgent plist.
- **Communication:** how the app and CLI talk to the helper, e.g. XPC, a Unix socket,
  distributed notifications, or a lock plus a shared work queue. It must satisfy the
  one-job-at-a-time rule.
- **Project generation:** Xcode project setup, for example XcodeGen versus a hand-made
  project, and the module layout.
- **Storage:** the format of state and hash-cache storage, either SQLite or JSON.
- **Scheduling:** exact times of the daily and weekly runs. They should be overnight
  where possible.
- **Small files:** a minimum file size for dedupe, if it helps performance. Default to
  including all non-empty files unless measurements show it isn't worth it.
- **Visual design:** the app's visual design within the content listed above.
- **Testing approach:** must include tests that verify cloned files are byte-identical,
  keep permissions and executable bits, diverge correctly on write, and that interrupted
  replacements leave originals intact.

## Calls made by Claude (not explicitly decided by Hugh)

- **Language:** Swift and SwiftUI, native, for direct access to `clonefile` and
  notifications.
- **Build caches:** permanent deletion instead of moving to the Trash. Also clearing
  `node_modules/.cache` and `node_modules/.vite`.
- **Recent activity:** the "touched in last 24h" rule counts any file modification in
  the project.
- **Pause switch:** the pause/resume control.
- **CLI:** the command's name and its install location.
- **Hard links:** skipping hard-linked files, which protects the pnpm projects.
- **Repo:** making this folder a local git repo.
