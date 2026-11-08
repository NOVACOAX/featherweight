# Featherweight: design

Date: 2026-11-08
Owner: Hugh Herschell (GitHub: NOVACOAX)
Tagline: *node_modules, but light.*

## Why

JavaScript projects waste a lot of disk space. Every project has its own `node_modules`,
often holding the same package versions as a dozen other projects, and frameworks leave
behind large build caches that regenerate themselves. Featherweight is a small native Mac
app that wins that space back automatically, without changing how anyone works on their
projects.

It started as a tool for Hugh's Mac: the drive was 95% full with 24 GB free. Measured
there on 2026-11-08:

- About **2.8 GB** of the 7.85 GB of `node_modules` content is byte-identical duplicates.
- Build caches (`.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`, `.cache`) total
  about **12.6 GB**. `.next` alone is about 4.7 GB, 4 GB of it in one project.

It will be published on GitHub as a free, open-source project anyone can install, so
nothing may be specific to Hugh's machine.

## What it is

A native macOS app, **Featherweight**, made of three pieces that share one core:

1. **Background helper.** Starts at login, has no Dock or menu bar presence, and does all
   the scheduled work.
2. **The app.** A normal windowed app opened from Applications or Spotlight to see what
   has happened, change settings, and run jobs by hand. Closing it does not stop the
   helper. There is no menu bar icon.
3. **The `featherweight` terminal command** for the same manual actions.

It saves space three ways:

- **Share duplicates (automatic).** Identical files across all `node_modules` trees become
  APFS clones of one another. Every project keeps its own real `node_modules` folder with
  every file in place, but identical files share physical blocks on disk. APFS clones are
  copy-on-write: if a project later modifies a cloned file, that file silently gets its
  own blocks, so one project can never affect another.
- **Clear build caches (automatic, weekly by default).** Regenerable cache folders are
  deleted.
- **Convert a project to pnpm (manual, per project).** pnpm keeps one global copy of
  every package, so converting saves space at install time. This is the only feature that
  changes a project's files. It is always the user's explicit choice and offers to commit
  and push the change.

### The key property: dedupe and cache clearing never change projects

Sharing duplicates and clearing caches leave `package.json`, lockfiles, and
package-manager commands (npm, pnpm, yarn, bun) exactly as they are. Nothing is committed.
On GitHub or another machine, `npm install` behaves as it always has, because Featherweight
acts on the files on this disk from outside the projects. pnpm conversion is the one
deliberate exception.

## Goals

- Free as much disk space as is safe, automatically, with no change to how people work.
- Work for anyone: they pick their projects folders and which cache folders get cleared.
  Nothing is hard-coded to one machine.
- Pick up new projects in the chosen folders without any setup.
- Show what it has done (space freed, per project, history), and run any job on demand
  from the app or the terminal.
- Notify when a run frees space or something goes wrong.
- Stay light: small to download, near-zero CPU and memory when idle, and gentle on the
  disk while working.
- Be easy to release: Hugh builds on his Mac, and pushing a version bump to `main`
  publishes a GitHub release.

## Non-goals

- Automatically changing package managers or project configuration. pnpm conversion only
  happens per project, on request.
- Deleting whole `node_modules` folders of old or inactive projects.
- Touching anything outside the folders the user chose.
- Python environments, `.venv`, or other non-JavaScript artifacts.
- Speeding up installs.
- Windows or Linux. The space-sharing mechanism is APFS-specific.
- A menu bar icon.
- Analytics or telemetry. The only network use is the optional update check.
- Apple notarization. Hugh has no paid Apple Developer account.

## Anti-goals (failure even if it "works")

- **Any project breaks** or behaves differently after dedupe, cache clearing, or a pnpm
  conversion it reported as successful. File contents, permissions, and executability
  matter more than space saved.
- Touching a file while a package manager is still writing to it.
- Deleting anything that does not regenerate itself, or anything tracked in git.
- Clearing caches out from under a project the user is actively working on, for example
  while a dev server is running.
- Committing or pushing anything without the user clicking to do so, or staging files
  the conversion didn't change.
- Notification spam.
- Leaving anything behind that breaks projects if the app is removed. Cloned files are
  ordinary files, so uninstalling must leave every project working.
- A heavy app: an Electron-sized bundle, a helper that polls, or noticeable fan or disk
  activity.

## Behaviour

### Projects

A project is any directory inside a chosen projects folder, at any depth, that contains
a `package.json` and is not itself inside a `node_modules` tree, a cache folder, or a
Python environment (`.venv`, `venv`, and similar). Examples from Hugh's machine:
`linkbreeze`, `artwork-kenya/functions`, `forex-system/dashboard`. Paths may contain
spaces, including trailing spaces such as `Lightroom `, and must be handled correctly.

- **Nested projects.** A project inside another project (e.g. `artwork-kenya/functions`)
  is shown under its parent. Activity in it counts as activity for the parent for the
  activity-window rule.
- **Package manager.** Detected from the lockfile: `package-lock.json` or
  `npm-shrinkwrap.json` means npm, `pnpm-lock.yaml` means pnpm, `yarn.lock` means yarn,
  and `bun.lock` or `bun.lockb` means bun. A project with no lockfile is labelled as
  having none.
- **Git status.** Whether the project is in a git repo, its current branch, and whether
  that branch has a remote. Used for the git-tracked rule and the commit/push offer.

### Share duplicates (dedupe)

- **Scope:** regular files inside any `node_modules` tree in a chosen folder, including
  duplicates within one project.
- **Skip:**
  - symlinks
  - empty files
  - files with a hard-link count above 1. pnpm hard-links into its store, so cloning one
    would break that link and free nothing.
  - files on a different volume from the copy they would be cloned from
  - files already sharing blocks with their match. Bun, for example, already clones from
    its own cache. APFS exposes this through `getattrlist` clone-id and extended-flag
    attributes; use whatever reliable signal exists so repeat sweeps are cheap.
- **Matching:** files are identical only when their size and a full-content
  cryptographic hash match (e.g. SHA-256 via CryptoKit). Cache hashes keyed by path,
  inode, size, and mtime, so sweeps don't re-read unchanged files.
- **Replacing a duplicate must be atomic and lossless:**
  1. Clone the keeper file to a temporary name in the duplicate's directory.
  2. Give the clone the duplicate's mode, owner, timestamps, and extended attributes.
  3. Rename it over the duplicate.

  A failure at any step leaves the original untouched, and no temp files are left behind.
- **Dev servers keep running** (my call). Dedupe doesn't wait for dev servers to stop. A
  replaced file keeps its contents, mode, and mtime; only its inode changes. Common
  watchers (Vite, webpack/Next, Jest) ignore `node_modules` or treat it as immutable by
  version. If testing shows a mainstream tool reloads because of a replacement, the
  builder adds a "skip recently active projects" guard for automatic dedupe.
- **Not during installs:** a `node_modules` tree is processed only once it has been quiet
  (no file-system events) for about 60 seconds. Files modified in the last 60 seconds are
  skipped.
- **When it runs:**
  - after installs: the helper watches the chosen folders with FSEvents and dedupes a
    project once changes in its `node_modules` settle
  - a full sweep on a schedule (default: daily at 3:00 AM)
  - on demand from the app or the CLI
- **Preview:** the app's **Preview** button and `featherweight dedupe --dry-run` report
  what would be freed without changing anything.

### Clear build caches

- **Configurable list.** The user chooses which folder names to clear from a checklist
  and can add their own names.
- **On by default:**
  - at a project's root: `.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`, `.cache`
  - inside `node_modules`: `node_modules/.cache`, `node_modules/.vite`
- **Off by default: `.output`.** Many projects deploy from it. On Hugh's machine Firebase
  and Cloudflare deploy from it, a `start` script runs from it, and one deploy script
  patches files inside it. The checklist explains why it's off.
- **Always skipped:**
  - **Tracked in git:** a folder containing any file tracked by git in the project's
    repository.
  - **Recently active:** projects with activity within the activity window (default 24
    hours, configurable). Activity means any file in the project was modified in that
    window, including in the cache folder itself but excluding `.git`. This protects
    running dev servers, which write to `.next` continuously.
  - **No git:** this rule doesn't skip anything by itself. Projects without git still have
    their checked cache folders cleared.
- **Deletion:** permanent, not moved to the Trash. These folders regenerate, and the Trash
  would not free space until emptied.
- **When it runs:**
  - on a schedule (default: weekly, Sunday at 3:00 AM). If the Mac was asleep or off at
    that time, the job runs as soon as it's overdue.
  - on demand from the app or the CLI, following the same skip rules
  - **per project:** "Clear caches" on a project also follows the same rules. It is
    disabled with the reason shown when the project is skipped.
- **Preview:** the app's **Preview** button and `featherweight clean --dry-run` list what
  would be cleared and what would be skipped, and why.

### Convert to pnpm (per project, manual)

pnpm's built-in `pnpm import` command converts an existing `package-lock.json`,
`npm-shrinkwrap.json`, or `yarn.lock` into a `pnpm-lock.yaml` with the same resolved
versions. No AI is involved.

**Eligibility.** The **Convert to pnpm…** button appears for npm and yarn projects. It
is disabled, with the reason shown, for:

- bun projects: `pnpm import` doesn't read bun lockfiles
- projects that already use pnpm
- monorepos that use `workspaces` in `package.json`, in v1
- projects skipped by the activity rule

**pnpm missing.** If pnpm isn't installed, the sheet says so and offers to install it via
Corepack (`corepack enable pnpm`), falling back to `npm install -g pnpm`. It shows the
exact command and runs it only on click.

**Confirmation sheet** (see mockup screen 3, left). It lists the steps and warns that
anyone cloning the project will need pnpm. An option, "Run the build script to check it
still works", is on by default when `package.json` has a `build` script.

**Steps:**

1. Back up the original lockfile to
   `~/Library/Application Support/Featherweight/backups/<project>/<timestamp>/`.
2. Run `pnpm import` in the project.
3. Remove the project's `node_modules` and run `pnpm install`.
4. If the option is on, run the project's `build` script with pnpm.
5. Remove the old lockfile from the project.

If any step fails, revert automatically: restore the original lockfile, remove
`pnpm-lock.yaml`, and reinstall with the original package manager. Then show the failing
command's output.

**Kept as-is:** no `.npmrc` is written, and no new `packageManager` field is added.
`package.json` changes only as described under the minimal edits and script rewrites
below.

**Backups:** step 1 backs up every file the conversion will touch, not just the
lockfile.

**Done sheet** (see mockup screen 3, right):

- space freed
- the files that changed, e.g. `− package-lock.json`, `+ pnpm-lock.yaml`
- an editable commit message, defaulting to "Switch from npm to pnpm" (or "from yarn")
- buttons:
  - **Revert:** restores the backup and reinstalls with the original manager
  - **Not now**
  - **Commit:** shown only in a git repo
  - **Commit & Push:** shown only when the current branch has an upstream remote. The
    sheet names the destination, e.g. `origin/main`.

**Commit rules:**

- Only files the conversion changed are staged. Other uncommitted work in the repo is
  left alone.
- Push failures (auth, rejected) show git's output, and the commit stays local.

**Minimal pnpm-required edits** (Hugh's decision: conversion may change files beyond the
lockfile). These edits are made when pnpm needs them:

- `onlyBuiltDependencies` in `pnpm-workspace.yaml`, listing the dependencies that have
  install scripts (e.g. esbuild, sharp, prisma), so they still build as they did under
  npm.
- An existing `packageManager` field in `package.json` that names npm or yarn is updated
  to the installed pnpm version.

These are the only `package.json` changes allowed, apart from the script rewrites below.

**CI, deploy and script configs are updated too** (Hugh's decision). After the install
succeeds, Featherweight rewrites references to npm or yarn in the project's configs, but
only for patterns it recognises with certainty. The rewrites are deterministic, with no
AI involved:

- **GitHub Actions** (`.github/workflows/*.yml`):
  - `npm ci` becomes `pnpm install --frozen-lockfile`, and `npm install` / `yarn` become
    `pnpm install`
  - `npm run X` / `yarn X` become `pnpm run X`, and `npx` becomes `pnpm exec`
  - a `pnpm/action-setup` step is added before `actions/setup-node`
  - `cache: npm` / `cache: yarn` become `cache: pnpm`
- **Dockerfile:**
  - `COPY` of the old lockfile is changed to `pnpm-lock.yaml`
  - `RUN npm ci` / `npm install` become `RUN corepack enable && pnpm install
    --frozen-lockfile`
- **`firebase.json` predeploy steps:** `npm --prefix X run Y` becomes
  `pnpm --dir X run Y`, and `npm run Y` becomes `pnpm run Y`.
- **`netlify.toml` and `vercel.json`:** install and build commands get the same
  rewrites.
- **`package.json` scripts:** `npm run X` and `yarn X` inside scripts become
  `pnpm run X`.

Anything it finds that it can't rewrite with certainty is left untouched. That includes
`npm install --prefix …` to another folder, unfamiliar CI providers, and shell scripts.
Each one is listed on the done sheet with a warning showing the file and line, so the
user can fix it by hand.

**What the done sheet shows:**

- **Changes:** every changed file, with a viewable diff.
- **Warnings:** the list above, if any. When there are warnings, **Commit** becomes the
  primary button instead of **Commit & Push**.
- **Staging:** every file the conversion changed (lockfiles, `pnpm-workspace.yaml`,
  `package.json`, and the rewritten configs) is staged, and nothing else.
- **Revert:** undoes all of it. Every edited file is backed up first.

**Later revert.** **Revert to npm** (or yarn) stays available on the project while its
backup exists.

### Notifications

- **After a run that freed space:** one notification per run with the amount, e.g.
  "Freed 340 MB after install in linkbreeze" or "Weekly cleanup freed 4.2 GB".
- **On errors:** a notification for errors that need attention.
- **Silent runs:** runs that freed nothing don't notify.
- **Bursts:** several automatic runs close together are coalesced into one notification.
- **Toggle:** notifications can be turned off in Settings.

### The app

The mockups in `assets/app-screens-mockup.html` were approved by Hugh and are the
reference for layout and content. The app follows the system's light or dark setting;
the mockups show dark. The accent colour is amber, matching the icon.

**Sidebar:**
- three sections: Overview, Projects, and Activity
- at the bottom:
  - helper status ("Running in background", or a problem with a fix button)
  - an "Automatic cleanup" pause switch

**Overview:**

- **Saving now** (Hugh's decision): the headline number. It is the space currently saved
  by shared duplicates, measured live, so it is always true at the moment it's shown.
  This replaces the mockup's all-time "Space reclaimed" total.
- **Caches cleared this month:** shown beside the headline, separately. The all-time
  history lives in Activity, because cleared caches regenerate.
- **Drive:** the startup drive's free space, with a meter.
- **Two job cards, Share duplicates and Clear build caches:** each shows its last run
  (when it ran and what it freed), its next run, and **Run now** and **Preview** buttons.
- **Recent activity:** the latest runs.

The app must explain somewhere visible that Finder's "Get Info" still reports
`node_modules` at full size. Finder sums logical sizes, so the reclaimed number is the
real figure.

**Projects:**

- **Table columns:**
  - project
  - package-manager badge
  - `node_modules` logical size
  - bytes shared (or "via pnpm")
  - cache size
  - last active
  - status ("Up to date", "Cleared 4.0 GB", "Skipped: active", ".output kept",
    "Tracked in git", …)
- **Toolbar:** filter by package manager and search.
- **Selected project:** shows its path, git branch, and remote, with Show in Finder,
  Clear caches, and Convert to pnpm… (or Revert to npm) buttons.

**Activity:** full history of runs and conversions, with what was freed and any errors.

**Settings (⌘,):**

- **Projects folders:** a list with +/−. Multiple folders are supported.
- **Cache folders to clear:** the checklist above, plus "Add folder name…". It notes that
  git-tracked folders are never cleared.
- **Schedules:**
  - Share duplicates: frequency and time
  - Clear build caches: frequency, day, and time
- **Leave projects alone if active within:** an activity window (default 24 hours).
- **General:**
  - run in background at login
  - show notifications
  - check GitHub for new versions
  - install the `featherweight` terminal command

**First launch** (mockup screen 5):

- **Folder choice:** defaults to `~/Developer` if it exists, otherwise asks the user to
  pick a folder.
- **Scan:** shows what would be freed ("Found 23 projects. About 2.8 GB … 12.6 GB …
  Nothing has been changed yet").
- **Buttons:** **Start saving space** turns on the helper. **Customise settings** opens
  Settings first. Nothing is modified before one of these is clicked.

**Starting:** clicking **Start saving space** runs both jobs right away, and they then
follow the schedule (my call). The first-launch scan already showed what will happen,
and the click is the user's consent.

**Protected folders:** if a chosen folder is privacy-protected by macOS (Desktop,
Documents, Downloads), the app explains what access it needs and guides the user through
granting it, rather than failing silently.

**iCloud Drive:** folders inside iCloud Drive, or any other File Provider sync folder,
can't be added (my call). The app explains why: offloaded files would have to be
downloaded, and every change would re-sync.

**Updates:** at most once a day, the app checks the GitHub Releases API for the latest
release (unauthenticated, no data sent). If a newer version exists, it shows a small
"Version x.y.z is available" link to the release page. It never installs updates itself.

### The `featherweight` command

**Installing it.** From Settings → General, the app links the bundled CLI into a
directory on the user's `PATH`. It prefers `~/.local/bin` when that's on `PATH`. If no
writable directory on `PATH` is found, it shows the exact line to add to the user's
shell profile.

**Subcommands:**

- `status`: the same numbers the app shows
- `dedupe [--dry-run]`
- `clean [--dry-run]`
- `projects`: list with sizes and status
- `pause` and `resume`
- `log`
- `uninstall`: removes the helper, the login item, and the command. Projects stay intact.

Runs started from the CLI or the app appear in the app's history like any other.

### Lightweight budget (targets)

- **Download:** the zipped app is under 10 MB. No bundled runtimes or web views.
- **Idle helper:** under 30 MB of memory and effectively 0% CPU. It sleeps on FSEvents
  and timers and never polls.
- **While working:** background QoS with throttled disk I/O, so it never makes the Mac
  feel slow.
- **App closed:** the helper does not keep the app's UI in memory.

### Install and first run for other people (no Apple Developer account)

Releases are not notarized. They are signed with a stable self-signed code-signing
certificate on Hugh's Mac (my call), created once by a setup script in the repo. Ad-hoc
signing would make every release look like a new app to macOS, so users would have to
re-grant folder access, notifications, and login-item approval after each update. The
release hook falls back to ad-hoc signing with a warning if the certificate is missing.
Building from source uses ad-hoc signing.

Either way, macOS refuses the first launch with an "Apple could not verify…" message.

**README "First launch" section.** It must explain:

- **Allowing the app:** open System Settings → Privacy & Security, scroll to the message
  about Featherweight, and click **Open Anyway**.
- **Terminal alternative:**
  `xattr -dr com.apple.quarantine /Applications/Featherweight.app`
- **Why:** the project isn't notarized, and the source is open to inspect.

## Repository, README, and releases

- **Repo:** `/Users/hughherschell/Developer/Node Modules` (already a local git repo) will
  be published as a public GitHub repo, `featherweight` under NOVACOAX. Creating and
  pushing the repo is Hugh's step, or happens on his explicit say-so.
- **License:** MIT.
- **README must cover:**
  - what it does
  - how sharing duplicates saves space without changing projects, including the Finder
    "Get Info" caveat
  - the three features
  - safety rules: what is never touched
  - requirements: macOS 14+ and an APFS volume
  - install and first launch, as described above
  - settings
  - the terminal command
  - pnpm conversion and its effect on collaborators
  - uninstalling
  - building from source
  - how releases are made
  - license

  It uses the logo and screenshots of the real app.
- **Logo:** the approved icon is `assets/featherweight-logo.svg`: two dashed amber hexagon
  outlines folding into one solid amber hexagon on a dark slate tile. The app icon set is
  generated from it.
- **Versioning:** semantic versions with one source of truth in the repo. The app's
  displayed version and the release tag (`vX.Y.Z`) derive from it.
- **Releases (local build on push to `main`):** a git hook kept in the repo, installed
  with one setup command, runs when Hugh pushes to `main`.
  - **If the version changed since the latest GitHub release:**
    1. Build a Release configuration on his Mac.
    2. Sign the app with the self-signed certificate (see above).
    3. Zip it with `ditto`.
    4. Once the commit is on GitHub, create the tag and a GitHub release with `gh`. Attach
       the zip and auto-generated notes from commits since the previous tag.
  - **If the build fails:** the push is stopped with a clear message, so a version bump
    never reaches `main` without its release.
  - **If the version didn't change:** the push goes through untouched.

## Constraints

- **Platform:** macOS 14 Sonoma or later, Apple silicon and Intel, APFS. Hugh develops on
  macOS 27 with Xcode 27.2 and Swift 6.4.
- **Language:** native Swift and SwiftUI. No third-party runtime dependencies unless one
  clearly earns its place.
- **One job at a time:** jobs from the helper, app, and CLI must never run concurrently.
- **Shared state:** the app, helper, and CLI share state (settings, history, totals, hash
  cache, backups) in `~/Library/Application Support/Featherweight/`.
- **Notifications need a bundle:** UNUserNotificationCenter needs code inside an app
  bundle, so the helper must be bundled, for example as a background-only login-item app
  inside the main app.
- **Login items must work without Apple signing:** starting at login must work for a
  self-signed or ad-hoc signed app downloaded from GitHub. If `SMAppService` doesn't work reliably in that
  situation, fall back to a LaunchAgent plist. The builder must verify this on a
  quarantined download, not only a local build.

## Left to the builder

- **Login and communication:** the login mechanism (within the constraint above), and
  how the app and CLI talk to the helper (XPC, a socket, or a lock plus a shared work
  queue). Either way, the one-job-at-a-time rule must hold.
- **Project setup:** the Xcode project (e.g. XcodeGen or hand-made) and module layout.
- **Storage:** the format of state and hash-cache storage.
- **Small files:** a minimum file size for dedupe, if measurements justify one.
  Otherwise, include all non-empty files.
- **Visual polish:** within the approved mockups.
- **Release hook:** how the hook waits for the push to land before creating the release.
- **Testing:** must include tests that:
  - cloned files are byte-identical
  - permissions and executable bits are kept
  - clones diverge correctly on write
  - interrupted replacements leave originals intact
  - the cache-clearing skip rules hold (git-tracked, recently active, `.output` off)
  - a failed pnpm conversion fully reverts

## Calls made by Claude (not explicitly decided by Hugh)

- **Tech:** native Swift and SwiftUI. macOS 14+ minimum. MIT license.
- **Cache clearing:**
  - caches are deleted permanently, not moved to the Trash
  - `node_modules/.cache` and `node_modules/.vite` are on by default
  - the activity rule counts any file modification
  - nested projects count toward their parent
- **Dedupe:** hard-linked files are skipped, which protects pnpm and bun projects.
- **pnpm conversion:**
  - Corepack is the first choice for installing pnpm
  - the build-check option is on by default
  - workspace monorepos and bun projects can't be converted in v1
  - only files the conversion changed are staged
- **Updates:** a notify-only check against GitHub Releases, with no auto-install.
- **Lightweight budget:** the targeted numbers.
- **Releases:** a failed build blocks the push. Release notes are auto-generated from
  commits. Releases are signed with a stable self-signed certificate rather than ad-hoc.
- **Dedupe timing:** automatic dedupe doesn't wait for dev servers to stop.
- **Folders:** iCloud Drive and other sync folders are excluded.
- **First launch:** "Start saving space" runs both jobs right away.
- **pnpm conversion:** it checks CI and deploy files and warns, but never edits them.
- **CLI:** the `featherweight` command and its subcommands. `~/.local/bin` is the
  preferred install location.
