# Featherweight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Featherweight, a native macOS app with a background helper and a CLI. It
reclaims disk space from JavaScript projects by sharing duplicate `node_modules` files
as APFS clones, clearing regenerable build caches, and converting projects to pnpm on
request.

**Architecture:**

- **One Swift package with four products:**
  - `FeatherweightCore`: a library holding all logic, fully unit-tested
  - `featherweight`: the CLI
  - `FeatherweightHelper`: a background agent
  - `FeatherweightApp`: SwiftUI
- **No IPC:** every process runs jobs in-process through `JobRunner`. A file lock
  (`flock`) makes jobs run one at a time.
- **Shared state:** state is shared through JSON and SQLite files in Application
  Support. The app watches that folder to refresh.
- **Starting at login:** a plain LaunchAgent plist starts the helper. This works the same
  for self-signed, ad-hoc and source builds.
- **App bundle:** `scripts/build-app.sh` assembles the `.app` from SwiftPM build output.
  No Xcode project and no third-party tools.

**Tech Stack:**

- **Language:** Swift 6.4, SwiftUI with `@Observable`, minimum macOS 14.
- **Testing:** Swift Testing (`import Testing`).
- **System libraries:**
  - CryptoKit (SHA-256)
  - the SQLite3 C API (system `libsqlite3`)
  - CoreServices FSEvents
  - UserNotifications
  - `clonefile(2)` and `getattrlist(2)` (APFS)
- **External tools:** `/usr/bin/git`, `launchctl`, `ditto`, `iconutil` and `gh`, all
  invoked as processes.
- **Dependencies:** no third-party packages.

**Spec:** `docs/superpowers/specs/2026-11-08-featherweight-design.md`. The approved
screens are in `docs/superpowers/specs/assets/app-screens-mockup.html` and the logo is
`docs/superpowers/specs/assets/featherweight-logo.svg`.

**Milestones.** Each one ends with working, testable software:
- **A (Tasks 1–8):** core engine and CLI. `featherweight dedupe` and `featherweight clean`
  work on real folders.
- **B (Task 9):** the background helper runs at login, after installs and on schedule.
- **C (Tasks 10–15):** the app, including pnpm conversion.
- **D (Tasks 16–18):** bundle, icon, signing, release hook and README.

## Global Constraints

- **Platform:** macOS 14 Sonoma or later, on Apple silicon and Intel. Releases are
  universal binaries. APFS only.
- **Dependencies:** native Swift and SwiftUI only, with no third-party runtime
  dependencies.
- **Identifiers:**
  - bundle IDs: `com.novacoax.featherweight` (app) and
    `com.novacoax.featherweight.helper` (helper)
  - LaunchAgent label: `com.novacoax.featherweight.helper`
  - GitHub repo: `NOVACOAX/featherweight`
- **State directory:** `~/Library/Application Support/Featherweight/`, injectable in tests
  via `AppPaths`.
- **Lightweight budget:**
  - the zipped app is under 10 MB
  - the idle helper uses under 30 MB of memory and effectively 0% CPU, and never polls
  - work runs at background QoS with low-priority I/O
- **Dedupe:** never touches files modified in the last 60 seconds, or trees with
  file-system events in the last 60 seconds.
- **Cache defaults:**
  - on: `.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`, `.cache`,
    `node_modules/.cache`, `node_modules/.vite`
  - off: `.output`
- **Default schedules:**
  - dedupe: daily at 03:00
  - clean: weekly on Sunday at 03:00
  - activity window: 24 hours
- **Cache deletion:** permanent, never to the Trash. Git-tracked cache folders are never
  cleared.
- **Git:** never commit or push without an explicit click. Stage only files the
  conversion changed.
- **Network:** only the update check
  (`https://api.github.com/repos/NOVACOAX/featherweight/releases/latest`), at most once a
  day. No telemetry.
- **Fixed copy:**
  - "Saving now"
  - "Caches cleared this month"
  - "Running in background"
  - "Automatic cleanup"
  - "Share duplicates"
  - "Clear build caches"
  - "Run now"
  - "Clear now"
  - "Preview"
  - "Convert to pnpm…"
  - "Revert to npm" / "Revert to yarn"
  - "Start saving space"
  - "Customise settings"
  - "Commit"
  - "Commit & Push"
  - "Not now"
  - "Revert"
  - default commit message "Switch from npm to pnpm" / "Switch from yarn to pnpm"
  - notification examples "Freed 340 MB after install in linkbreeze" and "Weekly cleanup
    freed 4.2 GB"
- **Sizes:** formatted with `ByteCountFormatter`, `.file` style.

## Review Focus

These five failure modes are the most likely to bite a real user, and no feature test
naturally covers them. Each has a pinned test in the task named.

1. **The app can't find tools when opened from Finder.** GUI apps don't get the user's
   shell `PATH`, so pnpm, node and npm installed through nvm, Homebrew or Volta are
   invisible. Commands must run with the login-shell environment. Pinned in Task 1
   (`LoginShellEnvironment`) and Task 13.
2. **Dedupe retriggers itself.** Its own renames in `node_modules` produce FSEvents. The
   helper must ignore events at or below the event ID recorded when its last job ended,
   or it loops forever. Pinned in Task 9 (`InstallDebouncer`).
3. **A file changes between hashing and replacing.** For example, an install starts
   mid-sweep. The replacement must re-check the duplicate's and the keeper's inode, size
   and mtime right before renaming, and skip if either changed. Pinned in Task 5.
4. **Paths with spaces, a trailing space, or unicode** (`Lightroom `, `MAgPIE Studio`)
   in projects, cache folders and git calls. Pinned in Tasks 2 and 6.
5. **A conversion fails partway** (pnpm import error, install failure, build failure) on
   a project with uncommitted work. The auto-revert must restore every backed-up file
   byte-for-byte and leave unrelated files untouched. Pinned in Task 13.

---

## Milestone A: core engine and CLI

### Task 1: Package scaffold, paths, settings, command runner

**Files:**
- Create: `Package.swift`, `VERSION` (contents `0.1.0`), `LICENSE` (MIT, "Copyright (c) 2026 Hugh Herschell"), update `.gitignore` (add `.build/`, `build/`, `.impeccable/`)
- Create: `Sources/FeatherweightCore/Support/AppPaths.swift`, `Settings.swift`, `SettingsStore.swift`, `CommandRunner.swift`, `LoginShellEnvironment.swift`, `ByteFormat.swift`
- Create: `Sources/FeatherweightCLI/main.swift` (placeholder printing version), `Sources/FeatherweightHelper/main.swift` (placeholder), `Sources/FeatherweightApp/FeatherweightApp.swift` (placeholder `@main` App with an empty window)
- Test: `Tests/FeatherweightCoreTests/SettingsTests.swift`, `CommandRunnerTests.swift`

**Interfaces:**
- Produces:
  - `Package.swift`:
    - `platforms: [.macOS(.v14)]`
    - products: `FeatherweightCore` (library), `featherweight` (executable, target
      `FeatherweightCLI`), `FeatherweightHelper` (executable), `FeatherweightApp`
      (executable)
    - test target: `FeatherweightCoreTests`
    - `FeatherweightCore` links `sqlite3` via `linkerSettings: [.linkedLibrary("sqlite3")]`
  - `public struct AppPaths: Sendable`:
    - `init(base: URL, launchAgentsDir: URL, home: URL)`
    - `static let standard`
    - `var settings, history, stats, projects, hashCache, jobLock, helperPID: URL`.
      Their files are `settings.json`, `history.jsonl`, `stats.json`, `projects.json`,
      `hashes.sqlite`, `jobs.lock` and `helper.pid`.
    - `var backups: URL` (directory `backups/`)
    - `func ensureExists() throws`
  - `public struct CacheFolderSetting: Codable, Equatable, Sendable { var relativePath: String; var enabled: Bool; var isBuiltIn: Bool }`
  - `public struct Schedule: Codable, Equatable, Sendable { enum Frequency: String, Codable { case daily, weekly }; var frequency: Frequency; var weekday: Int /* 1 = Sunday */; var hour: Int; var minute: Int }`
  - `public struct Settings: Codable, Equatable, Sendable`:
    - `var projectFolders: [String]`
    - `var cacheFolders: [CacheFolderSetting]`
    - `var dedupeSchedule: Schedule`
    - `var cleanSchedule: Schedule`
    - `var activityWindowHours: Int`
    - `var notificationsEnabled: Bool`
    - `var checkForUpdates: Bool`
    - `var paused: Bool`
    - `var onboardingComplete: Bool`
    - `static func defaults(home: URL) -> Settings`. Its `projectFolders` is
      `[home/Developer]` if that exists, otherwise `[]`.
  - `public struct SettingsStore`:
    - `init(paths: AppPaths)`
    - `func load() -> Settings`: returns the defaults when the file is missing or corrupt
    - `func save(_: Settings) throws`: atomic write
  - `public struct CommandResult: Sendable { let exitCode: Int32; let stdout: String; let stderr: String; var succeeded: Bool }`
  - `public protocol CommandRunner: Sendable { func run(_ command: String, _ args: [String], in directory: URL?) throws -> CommandResult }`.
    `command` is a bare name resolved on the runner's `PATH`, or an absolute path.
  - `public struct ProcessCommandRunner: CommandRunner { init(environment: [String: String] = LoginShellEnvironment.shared) }`
  - `public enum LoginShellEnvironment`:
    - `static let shared: [String: String]`
    - `static func resolve(shell: String, timeout: TimeInterval) -> [String: String]`.
      It runs `shell -ilc 'printf __FW__; env -0'`, parses everything after the marker,
      and falls back to `ProcessInfo.processInfo.environment` on timeout or failure.
  - `public enum ByteFormat { static func string(_ bytes: Int64) -> String }`

- [ ] **Step 1: Write failing tests**
  - `defaultsHaveSpecCacheFolders`: the defaults' `cacheFolders.map(\.relativePath)` ==
    `[".next", ".nuxt", ".vite", ".turbo", ".parcel-cache", ".cache", "node_modules/.cache", "node_modules/.vite", ".output"]`.
    Every one is enabled except `.output`.
  - `defaultsSchedules`:
    - dedupe is `.daily`, 3:00
    - clean is `.weekly`, weekday 1, 3:00
    - `activityWindowHours == 24`, `notificationsEnabled`, `checkForUpdates`, and
      `!paused`
  - `settingsRoundTrip`: save then load in a temp `AppPaths` gives an equal value.
  - `corruptSettingsFallsBackToDefaults`: writing `"{"` to `settings.json` makes `load()`
    return the defaults.
  - `runnerResolvesBareCommandOnPath`: `ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"]).run("echo", ["hi"], in: nil)`
    has stdout `"hi\n"` and exit code 0.
  - `loginShellEnvironmentFallsBack`: `resolve(shell: "/nonexistent", timeout: 1)`
    contains `PATH`.
  - `loginShellEnvironmentIncludesShellPath`:
    `resolve(shell: "/bin/zsh", timeout: 10)["PATH"]` is not empty.
- [ ] **Step 2:** Run `swift test --filter "SettingsTests|CommandRunnerTests"`. Expected:
  a compile failure.
- [ ] **Step 3:** Implement the interfaces above.
- [ ] **Step 4:** Run `swift test`. Expected: all tests pass. `swift build` builds all
  four products.
- [ ] **Step 5:** Commit with `git commit -m "feat: package scaffold, settings, command runner"`.

### Task 2: Project discovery and activity

**Files:**
- Create: `Sources/FeatherweightCore/Projects/Project.swift`, `ProjectScanner.swift`, `ActivityChecker.swift`
- Test: `Tests/FeatherweightCoreTests/ProjectScannerTests.swift`, `ActivityCheckerTests.swift`, `Tests/FeatherweightCoreTests/Support/TempTree.swift` (a test helper that builds file trees from a `[String: String]` path→contents map and can set mtimes)

**Interfaces:**
- Consumes: `Settings.cacheFolders` (Task 1).
- Produces:
  - `public enum PackageManager: String, Codable, Sendable { case npm, pnpm, yarn, bun, none }`
  - `public struct Project: Hashable, Codable, Sendable { let root: URL; let parentRoot: URL?; let packageManager: PackageManager; var nodeModules: URL? }`
  - `public struct ProjectScanner { init(excludedDirectoryNames: Set<String>); func scan(folders: [URL]) -> [Project] }`:
    - results are sorted by path
    - never descends into `node_modules`, `.git`, the excluded names, symlinked
      directories, or directories named `.venv`/`venv` or containing `pyvenv.cfg`
  - `public enum PackageManagerDetector { static func detect(root: URL) -> PackageManager }`:
    - `package-lock.json` or `npm-shrinkwrap.json` → npm
    - `pnpm-lock.yaml` → pnpm
    - `yarn.lock` → yarn
    - `bun.lock` or `bun.lockb` → bun
    - none of these → none
  - `public struct ActivityChecker`:
    - `init(now: @escaping @Sendable () -> Date = Date.init)`
    - `func isActive(root: URL, window: TimeInterval) -> Bool`: true if any regular
      file under `root`, excluding `.git`, has an mtime within `window`. It exits early.
    - `func lastSourceChange(root: URL) -> Date?`: the newest file mtime, excluding
      `node_modules` and `.git`. Used for the "Last active" column.

- [ ] **Step 1: Write failing tests**
  - `findsTopLevelAndNestedProjects`: a tree with `a/package.json`,
    `a/functions/package.json` and `b/dashboard/package.json` yields 3 projects.
    `a/functions` has `parentRoot == a`.
  - `skipsNodeModulesCachesAndVenvs`: `package.json` files inside `a/node_modules/x/`,
    `a/.next/`, `py/.venv/lib/gradio/` and a dir containing `pyvenv.cfg` are not
    projects.
  - `detectsEachPackageManager`: one assertion for each lockfile name above, including
    `bun.lockb`.
  - `handlesSpacesAndTrailingSpace`: projects at `MAgPIE Studio/` and `Lightroom /`
    (trailing space) are found, and `root.path` ends with the exact names.
  - `activityRecentFileIsActive`: a file with an mtime 1 hour ago gives true with a
    24-hour window.
  - `activityOldFilesInactive`: all mtimes 2 days ago gives false.
  - `activityIgnoresGitDir`: only `.git/index` is recent, so the result is false.
  - `nestedActivityMakesParentActive`: a recent file in `a/functions/` makes `a` active.
- [ ] **Step 2:** Run `swift test --filter "ProjectScannerTests|ActivityCheckerTests"`.
  Expected: fail.
- [ ] **Step 3:** Implement with `FileManager.enumerator(at:includingPropertiesForKeys:options:)`,
  pre-fetching `isDirectoryKey`, `isSymbolicLinkKey` and `contentModificationDateKey`.
- [ ] **Step 4:** Run the tests. Expected: pass.
- [ ] **Step 5:** Commit with `git commit -m "feat: project discovery and activity checks"`.

### Task 3: APFS clone primitives

**Files:**
- Create: `Sources/FeatherweightCore/Dedupe/CloneFS.swift`
- Test: `Tests/FeatherweightCoreTests/CloneFSTests.swift`

**Interfaces:**
- Produces:
  - `public struct CloneInfo: Equatable, Sendable`, with these fields:
    - `let device: UInt64`
    - `let inode: UInt64`
    - `let linkCount: UInt32`
    - `let size: Int64`
    - `let allocatedSize: Int64`
    - `let privateSize: Int64`
    - `let mtimeNanos: Int64`
    - `let cloneID: UInt64`
    - `let sharesAllBlocks: Bool`
    - `let isRegularFile: Bool`
  - `public enum CloneFS`:
    - `static func info(at: URL) throws -> CloneInfo`: uses `lstat` plus `getattrlist`
      with `ATTR_CMN_RETURNED_ATTRS | FSOPT_ATTR_CMN_EXTENDED`, and the extended
      attributes `ATTR_CMNEXT_PRIVATESIZE` (`0x8`), `ATTR_CMNEXT_CLONEID` (`0x100`) and
      `ATTR_CMNEXT_EXT_FLAGS` (`0x200`). `sharesAllBlocks` is `EF_SHARES_ALL_BLOCKS`
      (`0x40`) from `<sys/stat.h>`.
    - `static func replaceWithClone(of keeper: URL, replacing duplicate: URL, beforeRename: (() throws -> Void)? = nil) throws`
    - `static func privateBytes(under directory: URL) -> Int64`: the sum of
      `privateSize` over regular files, without following symlinks
  - `public enum CloneError: Error { case notRegularFile, differentVolume, changedDuringReplace, system(String, Int32) }`
- **Replace algorithm:**
  1. Remember the duplicate's `stat`.
  2. `clonefile(keeper, tmp, CLONE_NOFOLLOW)`, where `tmp` is `<dupdir>/.<name>.fw-<UUID>`.
  3. Copy the duplicate's xattrs and ACL onto tmp with `copyfile(dup, tmp, nil, COPYFILE_XATTR | COPYFILE_ACL)`.
  4. `chmod` tmp to the duplicate's mode. `lchown` it to the duplicate's uid and gid,
     ignoring `EPERM` when they already match.
  5. Set tmp's atime and mtime to the duplicate's with `utimensat`.
  6. Call `beforeRename`.
  7. Re-`lstat` the duplicate. If its inode, size or mtime differs from step 1, throw
     `changedDuringReplace`.
  8. `rename(tmp, dup)`.

  Any throw after step 2 unlinks tmp.

- [ ] **Step 1: Write failing tests.** Use a temp dir under
  `FileManager.default.temporaryDirectory`, which is APFS.
  - `cloneIsByteIdentical`: after replacing, both files have equal `Data`.
  - `cloneSharesBlocks`: after replacing, both have the same `cloneID`, both have
    `sharesAllBlocks == true`, and the duplicate's `privateSize == 0`.
  - `keepsDuplicateMetadata`: the duplicate had mode `0o755`, mtime 2020-01-01 and xattr
    `com.example.x = "1"`; the keeper had `0o644`. After replacing, the duplicate has
    `0o755`, the 2020 mtime and the xattr.
  - `divergesOnWrite`: append to the duplicate after replacing. The keeper's contents are
    unchanged, and the duplicate's `sharesAllBlocks` is false.
  - `interruptedReplaceLeavesOriginal`: `beforeRename` throws. The duplicate's contents
    and inode are unchanged, and the directory has no `.fw-` files.
  - `changedDuringReplaceIsDetected`: `beforeRename` writes to the duplicate. The call
    throws `changedDuringReplace`, the duplicate holds the new write, and no temp file
    remains.
  - `hardlinkReportsLinkCount`: after `link(a, b)`, `info(a).linkCount == 2`.
- [ ] **Step 2:** Run `swift test --filter CloneFSTests`. Expected: fail.
- [ ] **Step 3:** Implement as specified above.
- [ ] **Step 4:** Run the tests. Expected: pass.
- [ ] **Step 5:** Commit with `git commit -m "feat: APFS clone primitives"`.

### Task 4: Content hashing and hash cache

**Files:**
- Create: `Sources/FeatherweightCore/Dedupe/HashCache.swift`
- Test: `Tests/FeatherweightCoreTests/HashCacheTests.swift`

**Interfaces:**
- Consumes: `CloneInfo` (Task 3).
- Produces:
  - `public final class HashCache: @unchecked Sendable`:
    - `init(url: URL) throws`. The SQLite table is
      `hashes(path TEXT PRIMARY KEY, inode INTEGER, size INTEGER, mtime INTEGER, digest BLOB)`,
      with WAL journal mode.
    - `func digest(for url: URL, info: CloneInfo) throws -> Data`: returns the cached
      digest when inode, size and mtime match. Otherwise it streams SHA-256 in 1 MB
      chunks and upserts the result.
    - `func prune(keepingPathsWithPrefixes: [String]) throws`
  - Also exposes `private(set) var hashesComputed: Int`, for tests.

- [ ] **Step 1: Write failing tests**
  - `digestMatchesCryptoKit`: the result equals `SHA256.hash(data:)` of the contents.
  - `cachedDigestNotRecomputed`: the second call on an unchanged file leaves
    `hashesComputed == 1`.
  - `changedFileRecomputed`: after changing the contents (and so the mtime),
    `hashesComputed == 2` and the digest differs.
  - `persistsAcrossInstances`: a new `HashCache` on the same URL doesn't recompute.
  - `pruneRemovesOtherPaths`.
- [ ] **Step 2:** Run `swift test --filter HashCacheTests`. Expected: fail.
- [ ] **Step 3:** Implement with the `SQLite3` module and prepared statements.
- [ ] **Step 4:** Run the tests. Expected: pass.
- [ ] **Step 5:** Commit with `git commit -m "feat: hash cache"`.

### Task 5: Deduper and Saving-now meter

**Files:**
- Create: `Sources/FeatherweightCore/Dedupe/Deduper.swift`, `SavingsMeter.swift`
- Test: `Tests/FeatherweightCoreTests/DeduperTests.swift`, `SavingsMeterTests.swift`

**Interfaces:**
- Consumes: `Project` (Task 2), `CloneFS` (Task 3), `HashCache` (Task 4).
- Produces:
  - `public struct DedupeReport: Codable, Sendable, Equatable { var filesScanned: Int; var filesReplaced: Int; var bytesFreed: Int64; var perProject: [String: Int64]; var errors: [String] }`
  - `public struct Deduper`:
    - `init(hashCache: HashCache, quietPeriod: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init)`
    - `func run(projects: [Project], dryRun: Bool) -> DedupeReport`
  - `public struct SavingsSnapshot: Codable, Sendable, Equatable { var sharedBytes: Int64; var perProject: [String: Int64]; var measuredAt: Date }`
  - `public struct SavingsMeter { func measure(projects: [Project], now: Date) -> SavingsSnapshot }`
- **Dedupe algorithm:**
  1. Collect candidates: regular files under each `project.nodeModules`. Skip:
     - symlinks
     - size 0
     - `linkCount > 1`
     - mtimes within `quietPeriod`
  2. Group by `(device, size)` and keep groups with at least 2 files. Then group by
     digest.
  3. In each digest group, pick the keeper: the most common `cloneID` among members that
     have `sharesAllBlocks`. Break ties, or choose when none share, by the
     lexicographically smallest path.
  4. Skip a member if it has the keeper's `cloneID` and both have `sharesAllBlocks`.
  5. Otherwise, re-read the keeper's info. If its inode, size or mtime changed since
     hashing, skip the group.
  6. Add the member's `privateSize` to `bytesFreed` and to `perProject[project.root.path]`.
     Unless this is a dry run, call `replaceWithClone`.
  7. Record errors per file and continue.

  Run with background QoS and `setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)`.
- **Savings meter:** over the same candidate files (no quiet-period filter), group the
  files with `sharesAllBlocks` by `(device, cloneID)`. A group of `n` files saves
  `(n−1) × allocatedSize`. Credit the savings to each non-first member's project, in path
  order.

- [ ] **Step 1: Write failing tests.** Build two fake projects, each with
  `node_modules/react/index.js` (identical, 64 KB), a unique file and an empty file, and
  set mtimes to 1 day ago.
  - `dryRunReportsWithoutChanging`: `bytesFreed > 0` and `filesReplaced == 1`, but the
    inodes are unchanged and the files don't share blocks.
  - `runSharesIdenticalFiles`: afterwards both `index.js` files share a `cloneID` with
    `sharesAllBlocks`. `bytesFreed` is within 4096 of 65536.
  - `secondRunIsNoOp`: the second run has `filesReplaced == 0` and `bytesFreed == 0`.
  - `skipsHardlinks`: a hard-linked pair is never replaced.
  - `skipsRecentFiles`: with the duplicate's mtime 10 seconds ago, nothing is replaced.
  - `skipsEmptyAndUniqueFiles`.
  - `keeperChangedSkipsGroup` (Review Focus 3): use a `Deduper` test hook
    `afterHashing: (() -> Void)?` (internal, `@testable`) to rewrite the keeper. Nothing
    is replaced, and the contents of both files are unchanged.
  - `perProjectAttribution`: the freed bytes are credited to the project whose file was
    replaced.
  - `meterCountsSharedBytes`: after a real run,
    `SavingsMeter.measure(...).sharedBytes ≈ 65536` (within 4096).
  - `meterZeroBeforeRun`.
- [ ] **Step 2:** Run `swift test --filter "DeduperTests|SavingsMeterTests"`. Expected:
  fail.
- [ ] **Step 3:** Implement as specified above.
- [ ] **Step 4:** Run the tests. Expected: pass.
- [ ] **Step 5:** Commit with `git commit -m "feat: deduper and savings meter"`.

### Task 6: Git client and cache cleaner

**Files:**
- Create: `Sources/FeatherweightCore/Projects/GitClient.swift`, `Sources/FeatherweightCore/Clean/CacheCleaner.swift`
- Test: `Tests/FeatherweightCoreTests/GitClientTests.swift`, `CacheCleanerTests.swift`

**Interfaces:**
- Consumes: `CommandRunner` (Task 1), `Project` and `ActivityChecker` (Task 2), `Settings` (Task 1).
- Produces:
  - `public struct GitClient: Sendable`:
    - `init(runner: CommandRunner)`
    - `func repoRoot(for: URL) -> URL?`
    - `func isTracked(_ path: URL, repoRoot: URL) -> Bool`: true when
      `git ls-files -z -- <rel>` returns non-empty output
    - `func currentBranch(_ root: URL) -> String?`
    - `func upstream(_ root: URL) -> String?`: e.g. `"origin/main"`, from
      `rev-parse --abbrev-ref @{u}`
    - `func remoteURL(_ root: URL, remote: String) -> String?`
    - `func commit(files: [String], message: String, repoRoot: URL) throws`: runs
      `git add -A -- <files>` then `git commit -m <message> -- <files>`
    - `func push(repoRoot: URL) throws -> CommandResult`
  - `public enum SkipReason: String, Codable, Sendable { case recentlyActive, trackedInGit, notEnabled }`
  - `public struct CacheCandidate: Codable, Sendable, Hashable { let projectRoot: String; let folder: String; let relativePath: String; let allocatedBytes: Int64; let skip: SkipReason? }`
  - `public struct CleanReport: Codable, Sendable, Equatable { var cleared: [CacheCandidate]; var skipped: [CacheCandidate]; var bytesFreed: Int64; var errors: [String] }`
  - `public struct CacheCleaner`:
    - `init(git: GitClient, activity: ActivityChecker)`
    - `func plan(projects: [Project], settings: Settings) -> [CacheCandidate]`: covers
      every configured relative path that exists as a directory under each project root.
      Disabled paths get `skip = .notEnabled`. Otherwise the skip is `.trackedInGit` or
      `.recentlyActive`, checked in that order.
    - `func run(projects: [Project], settings: Settings, dryRun: Bool) -> CleanReport`:
      clears only the candidates with `skip == nil`, using `FileManager.removeItem`

- [ ] **Step 1: Write failing tests.** These use a real temp git repo initialised with
  `/usr/bin/git`, with `user.email` and `user.name` set via `-c`.
  - `isTrackedDetectsCommittedFolder`: a committed `.cache/keep.txt` gives true. An
    untracked `.next/` gives false.
  - `commitStagesOnlyListedFiles`: with `a.txt` and `b.txt` both modified,
    `commit(files: ["a.txt"])` leaves `b.txt` still modified in `git status --porcelain`.
  - `commitIncludesDeletion`: delete tracked `package-lock.json` and commit with it
    listed. HEAD no longer contains it.
  - `upstreamNilWithoutRemote`.
  - `cleanerClearsEnabledUntrackedInactive`: an inactive project's `.next` (1 MB) is
    removed, with `bytesFreed ≥ 1_000_000`.
  - `cleanerSkipsOutputByDefault`: `.output` is present after the run and appears in
    `skipped` with `.notEnabled`.
  - `cleanerSkipsTracked`: a tracked `.cache` gets `.trackedInGit` and still exists.
  - `cleanerSkipsRecentlyActive`: a recently modified `src/index.ts` skips `.next` with
    `.recentlyActive`.
  - `cleanerNodeModulesCache`: `node_modules/.cache` is cleared.
  - `cleanerDryRunDeletesNothing`.
  - `cleanerCustomFolder`: an added `{relativePath: "storybook-static", enabled: true}`
    is cleared.
  - `pathsWithSpaces` (Review Focus 4): the same behaviour holds for a project at
    `Lightroom /` (trailing space) inside a git repo.
- [ ] **Step 2:** Run `swift test --filter "GitClientTests|CacheCleanerTests"`. Expected:
  fail.
- [ ] **Step 3:** Implement as specified above. Measure folder size by summing
  `totalFileAllocatedSizeKey` over its contents.
- [ ] **Step 4:** Run the tests. Expected: pass.
- [ ] **Step 5:** Commit with `git commit -m "feat: git client and cache cleaner"`.

### Task 7: History, job lock, schedule, job runner, project summaries

**Files:**
- Create: `Sources/FeatherweightCore/Jobs/History.swift`, `JobLock.swift`, `Schedule+Next.swift`, `JobRunner.swift`, `ProjectSummary.swift`
- Test: `Tests/FeatherweightCoreTests/HistoryTests.swift`, `JobLockTests.swift`, `ScheduleTests.swift`, `JobRunnerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces:
  - `public enum JobKind: String, Codable, Sendable { case dedupe, clean, convert, revert }`
  - `public enum JobTrigger: String, Codable, Sendable { case scheduled, afterInstall, manualApp, manualCLI, firstLaunch }`
  - `public struct RunRecord: Codable, Sendable, Identifiable, Equatable`, with these
    fields:
    - `let id: UUID`
    - `let kind: JobKind`
    - `let trigger: JobTrigger`
    - `let startedAt: Date`
    - `let finishedAt: Date`
    - `let bytesFreed: Int64`
    - `let summary: String`
    - `let projects: [String]`
    - `let skipped: [String]`
    - `let errors: [String]`
    - `let lastFSEventID: UInt64`
  - `public final class HistoryStore`:
    - `init(url: URL)`
    - `func append(_: RunRecord) throws`: appends one JSON line
    - `func all() -> [RunRecord]`: newest first, skipping corrupt lines
    - `func lastRun(of: JobKind) -> RunRecord?`
    - `func cachesClearedThisMonth(now: Date, calendar: Calendar) -> Int64`
  - `public final class JobLock`:
    - `init(url: URL)`
    - `func tryLock() -> Bool`
    - `func lock()`: blocking
    - `func unlock()`

    It is backed by `flock(LOCK_EX)` on an open fd. The lock is released if the process
    dies.
  - `extension Schedule`:
    - `func nextRun(after: Date, calendar: Calendar) -> Date`
    - `func isOverdue(lastRun: Date?, now: Date, calendar: Calendar) -> Bool`: true when
      the most recent scheduled time at or before `now` is later than `lastRun`, or when
      `lastRun` is nil
  - `public struct ProjectSummary: Codable, Sendable, Identifiable`, with these fields:
    - `id`: the root path
    - `name`
    - `parentRoot: String?`
    - `packageManager`
    - `nodeModulesBytes: Int64`: logical size
    - `sharedBytes: Int64`
    - `cacheBytes: Int64`
    - `lastActive: Date?`
    - `status: String`: one of "Up to date", "Cleared X", "Skipped: active",
      ".output kept", "Tracked in git", "Linked by pnpm"
    - `gitBranch: String?`
    - `upstream: String?`
    - `remoteURL: String?`
  - `public final class JobRunner: @unchecked Sendable`:
    - `init(paths: AppPaths, runner: CommandRunner = ProcessCommandRunner())`
    - `func dedupe(trigger: JobTrigger, only: [URL]? = nil, dryRun: Bool, onWaiting: (() -> Void)? = nil) -> (DedupeReport, RunRecord?)`
    - `func clean(trigger: JobTrigger, only: [URL]? = nil, dryRun: Bool, onWaiting: (() -> Void)? = nil) -> (CleanReport, RunRecord?)`
    - `func refreshSummaries() -> [ProjectSummary]`: writes `projects.json`
    - `func refreshSavings() -> SavingsSnapshot`: writes `stats.json`
    - `func withLock<T>(onWaiting: (() -> Void)?, _ body: () throws -> T) rethrows -> T`
      (used by conversion)
  - **Runs:** a non-dry run takes the lock (calling `onWaiting` if it has to wait),
    scans the projects from the settings, runs, and appends a `RunRecord`. It sets
    `lastFSEventID = FSEventsGetCurrentEventId()` after the work, then refreshes the
    savings and summaries.
  - **Dry runs:** they take no lock and record nothing.
  - **Summary strings:**
    - dedupe: "Shared duplicates in N projects"
    - clean: "Cleared caches in N projects, M skipped"

- [ ] **Step 1: Write failing tests**
  - `historyAppendAndReadNewestFirst`.
  - `historySkipsCorruptLine`.
  - `cachesClearedThisMonthSumsOnlyCleanThisMonth`.
  - `lockExcludesSecondHolder`: two `JobLock` instances on one file in the same process
    use separate fds. The second `tryLock()` is false until the first unlocks.
  - `nextRunDaily`: from 2026-11-08 10:00, daily at 03:00 gives 2026-11-09 03:00.
  - `nextRunWeekly`: from Sunday 2026-11-08 02:00, weekly Sunday 03:00 gives 2026-11-08
    03:00. From 04:00 the same day it gives 2026-11-15 03:00.
  - `overdueWhenMissedWhileAsleep`: last run Sun 2026-11-01 03:00, now Mon 2026-11-09
    09:00, weekly → true.
  - `notOverdueRightAfterRun`.
  - `runnerDedupeRecordsHistoryAndStats`: a temp `AppPaths` with settings pointing at a
    temp folder holding the two fake projects from Task 5. After `dedupe(trigger: .manualCLI, dryRun: false)`:
    - `history.jsonl` has 1 record with `bytesFreed > 0`
    - `stats.json` has `sharedBytes > 0`
    - `projects.json` lists 2 projects
  - `runnerDryRunRecordsNothing`.
- [ ] **Step 2:** Run `swift test --filter "HistoryTests|JobLockTests|ScheduleTests|JobRunnerTests"`.
  Expected: fail.
- [ ] **Step 3:** Implement as specified above.
- [ ] **Step 4:** Run the tests. Expected: pass.
- [ ] **Step 5:** Commit with `git commit -m "feat: job runner, history, schedules, lock"`.

### Task 8: The `featherweight` CLI

**Files:**
- Modify: `Sources/FeatherweightCLI/main.swift`
- Create: `Sources/FeatherweightCLI/Commands.swift`
- Create: `Sources/FeatherweightCore/Support/Version.swift`
- Test: `Tests/FeatherweightCoreTests/CLIArgumentsTests.swift`. The argument parser lives
  in Core as `CLIArguments`, so it can be tested.

**Interfaces:**
- Consumes: `JobRunner`, `SettingsStore`, `HistoryStore`, `ProjectSummary` (Tasks 1–7).
  `LaunchAgent` and `CLIInstaller` arrive in Tasks 9 and 12. Until then, `uninstall`
  prints "not installed".
- Produces:
  - `public enum CLICommand: Equatable`:
    - `case status`
    - `case dedupe(dryRun: Bool)`
    - `case clean(dryRun: Bool)`
    - `case projects`
    - `case pause`
    - `case resume`
    - `case log(limit: Int)`
    - `case uninstall`
    - `case version`
    - `case help`
  - `public enum CLIArguments { static func parse(_ args: [String]) -> Result<CLICommand, CLIError> }`.
    `log` takes `--limit N` (default 20).
  - `public enum AppVersion { static var current: String }`. It reads
    `CFBundleShortVersionString` from the enclosing `.app`'s `Info.plist`, found by
    resolving symlinks on `CommandLine.arguments[0]`, and falls back to `"dev"`.
- **Output:** plain text. `status` prints:
  - Saving now
  - Caches cleared this month
  - disk free
  - the last and next run of each job
  - whether paused, and whether the helper is running

  When the lock is held, `dedupe` and `clean` print `Waiting for another Featherweight
  job to finish…`. Their final line is `Freed <size>` (`Would free <size>` for dry
  runs). Exit codes: 0 on success, 1 on errors, 2 on usage errors.

- [ ] **Step 1: Write failing tests**
  - `parsesEachSubcommand`: one case per command above.
  - `dryRunFlag`.
  - `logLimit`.
  - `unknownCommandIsUsageError`.
- [ ] **Step 2:** Run `swift test --filter CLIArgumentsTests`. Expected: fail.
- [ ] **Step 3:** Implement the parser and commands.
- [ ] **Step 4:** Run the tests, then smoke-test:
  - `swift run featherweight dedupe --dry-run` on a temp folder configured via settings.
    Expected: `Would free …`.
  - `swift run featherweight status` prints the numbers.
- [ ] **Step 5:** Commit with `git commit -m "feat: featherweight CLI"`.

---

## Milestone B: background helper

### Task 9: LaunchAgent, install watcher, scheduler loop, notifications

**Files:**
- Create: `Sources/FeatherweightCore/Helper/LaunchAgent.swift`, `InstallDebouncer.swift`, `NotificationComposer.swift`, `HelperHeartbeat.swift`
- Modify: `Sources/FeatherweightHelper/main.swift`
- Create: `Sources/FeatherweightHelper/HelperService.swift`, `FSEventsWatcher.swift`, `Notifier.swift`
- Test: `Tests/FeatherweightCoreTests/LaunchAgentTests.swift`, `InstallDebouncerTests.swift`, `NotificationComposerTests.swift`

**Interfaces:**
- Consumes: `JobRunner`, `Settings`, `Schedule`, `HistoryStore`, `RunRecord` (Task 7).
- Produces:
  - `public struct LaunchAgent`:
    - `static let label = "com.novacoax.featherweight.helper"`
    - `init(paths: AppPaths, runner: CommandRunner)`
    - `func plist(helperExecutable: URL) -> [String: Any]`, with keys:
      - `Label`
      - `ProgramArguments`: `[path]`
      - `RunAtLoad`: true
      - `KeepAlive`: `{SuccessfulExit: false}`
      - `ProcessType`: "Background"
      - `LowPriorityIO`: true
      - `LowPriorityBackgroundIO`: true
      - `Nice`: 10
    - `func install(helperExecutable: URL) throws`: writes
      `<launchAgentsDir>/<label>.plist`, then runs
      `launchctl bootout gui/<uid>/<label>` (ignoring failure) and
      `launchctl bootstrap gui/<uid> <plist>`
    - `func uninstall() throws`
    - `func isInstalled() -> Bool`
  - `public struct HelperHeartbeat`:
    - `init(paths: AppPaths)`
    - `func write(pid: Int32) throws`
    - `func isAlive() -> Bool`: reads the pid and checks `kill(pid, 0) == 0`
  - `public struct InstallDebouncer`:
    - `init(quietPeriod: TimeInterval = 60)`
    - `mutating func record(path: String, eventID: UInt64, at: Date, ignoreAtOrBelow: UInt64, projects: [Project])`:
      only paths containing `/node_modules/` count, and each maps to the project with the
      longest matching `nodeModules` prefix
    - `mutating func due(now: Date) -> [URL]`: returns the project roots whose last event
      is at least `quietPeriod` old, and removes them
  - `public struct NotificationText: Equatable { let title: String; let body: String }`
  - `public struct NotificationComposer`:
    - `init(coalesceWindow: TimeInterval = 300)`
    - `mutating func add(_ record: RunRecord, projectName: String?)`
    - `mutating func flush(now: Date) -> NotificationText?`
- **Notification rules:**
  - Ignore records with `bytesFreed == 0` and no errors.
  - Ignore `.manualApp` records, since the app shows those itself.
  - **One record:** title "Featherweight", with this body:
    - `afterInstall`: "Freed 340 MB after install in linkbreeze"
    - scheduled clean: "Weekly cleanup freed 4.2 GB" (or "Daily cleanup…" when the
      schedule is daily)
    - scheduled dedupe: "Daily sweep freed X"
    - CLI: "Freed X"
  - **Several within the window:** "Freed X across N runs".
  - **Any errors:** title "Featherweight hit a problem", body showing the first error.
  - `flush` returns nil until `coalesceWindow` has passed since the first unflushed
    record.
- **Helper service behaviour** (`HelperService`, not unit-tested; covered by the manual
  check in Step 4):
  - **Startup:**
    1. Write the heartbeat.
    2. Request notification authorization.
    3. Load the settings.
    4. Start an `FSEventStream` on `settings.projectFolders` with `kFSEventStreamCreateFlagFileEvents`
       and 5-second latency.
    5. Start a `DispatchSource` watching the state directory, and reload settings and
       history when they change.
    6. Schedule a one-shot `DispatchSourceTimer` for the earliest of the debouncer's next
       due time, the next dedupe and clean schedule times, and the next notification
       flush.
  - **On wake** (`NSWorkspace.didWakeNotification`) and on startup: run any overdue job.
  - **Paused:** while `settings.paused` is true, no automatic job runs, but events are
    still debounced.
  - **Events:** FSEvents are fed to the debouncer, with `ignoreAtOrBelow` = the max
    `lastFSEventID` in history (Review Focus 2).
  - **Jobs:** due projects run `dedupe(trigger: .afterInstall, only: roots)`. Scheduled
    jobs use `.scheduled`. All jobs run on a background-QoS queue.
  - **Notifications:** posted only when `settings.notificationsEnabled` is true. The
    `NotificationComposer` still flushes, so nothing piles up.
  - **Idle:** no polling. The process sleeps between events.

- [ ] **Step 1: Write failing tests**
  - `plistHasBackgroundKeys`: every key and value listed above.
  - `debouncerIgnoresNonNodeModules`: an event for `proj/src/a.ts` → `due` is empty.
  - `debouncerQuietPeriod`: an event at t0 → `due(t0+59s)` is empty and `due(t0+60s)`
    is `[proj]`.
  - `debouncerResetsOnNewEvent`.
  - `debouncerIgnoresOwnEvents` (Review Focus 2): event ID 100 with
    `ignoreAtOrBelow: 150` → `due` is empty forever.
  - `debouncerMapsNestedToInnermostProject`: `a/functions/node_modules/x` → `a/functions`.
  - `composerSingleAfterInstall`: the body equals "Freed 340 MB after install in
    linkbreeze" when `bytesFreed = 340_000_000`.
  - `composerWeekly`: the body equals "Weekly cleanup freed 4.2 GB".
  - `composerSilentWhenNothingFreed`.
  - `composerIgnoresManualApp`.
  - `composerCoalesces`: 3 records within 300 seconds give one text, "Freed … across 3
    runs".
  - `composerErrorTitle`.
- [ ] **Step 2:** Run `swift test --filter "LaunchAgentTests|InstallDebouncerTests|NotificationComposerTests"`.
  Expected: fail.
- [ ] **Step 3:** Implement the Core types and the helper executable.
  `FeatherweightHelper/main.swift` runs `NSApplication.shared` with
  `.setActivationPolicy(.prohibited)` and starts `HelperService`.
- [ ] **Step 4: Manual check.**
  1. `swift build -c release`.
  2. Install the agent pointing at `.build/release/FeatherweightHelper`, using a scratch
     `AppPaths` and a test projects folder.
  3. Run `npm install` in a test project. Within about 70 seconds, `history.jsonl` gains
     an `afterInstall` record.
  4. Wait 2 more minutes. No second record appears (no self-retrigger).
  5. Note the helper's RSS from `ps -o rss= -p <pid>`. It should be under 30 MB.
- [ ] **Step 5:** Commit with `git commit -m "feat: background helper"`.

---

## Milestone C: the app

The app is SwiftUI, follows the system's light or dark appearance, and uses amber accent
`#F59E0B`. The layout follows the approved mockup. Views stay thin, and all logic sits in
Core or `AppModel`. Verify views by running the app (`swift run FeatherweightApp`) and
taking screenshots. There are no UI test targets.

### Task 10: App shell, Overview and Activity

**Files:**
- Modify: `Sources/FeatherweightApp/FeatherweightApp.swift`
- Create: `Sources/FeatherweightApp/AppModel.swift`, `StateDirectoryWatcher.swift`, `Views/SidebarView.swift`, `Views/OverviewView.swift`, `Views/JobCard.swift`, `Views/ActivityView.swift`, `Views/PreviewSheet.swift`, `Theme.swift`
- Create: `Sources/FeatherweightCore/Support/DiskSpace.swift`
- Test: `Tests/FeatherweightCoreTests/DiskSpaceTests.swift`

**Interfaces:**
- Consumes: `JobRunner`, `SettingsStore`, `HistoryStore`, `SavingsSnapshot`,
  `ProjectSummary`, `Schedule`, `HelperHeartbeat`.
- Produces:
  - `public struct DiskSpace { static func forVolume(containing: URL) throws -> (free: Int64, total: Int64) }`.
    It uses `volumeAvailableCapacityForImportantUsageKey` and `volumeTotalCapacityKey`.
  - `@MainActor @Observable final class AppModel`, with these properties:
    - `var settings: Settings`
    - `var savings: SavingsSnapshot?`
    - `var history: [RunRecord]`
    - `var projects: [ProjectSummary]`
    - `var helperRunning: Bool`
    - `var disk: (free: Int64, total: Int64)?`
    - `var runningJob: JobKind?`
    - `var waitingForLock: Bool`
    - `var previewResult: PreviewResult?`
    - `var availableUpdate: AvailableUpdate?` (filled in Task 12)
  - `AppModel` methods:
    - `func reload()`
    - `func runDedupe(preview: Bool) async`
    - `func runClean(preview: Bool, only: [URL]? = nil) async`
    - `func setPaused(_: Bool)`
    - `func saveSettings(_: Settings)`

    Jobs run via `Task.detached(priority: .background)` with trigger `.manualApp`.
  - `enum PreviewResult { case dedupe(DedupeReport), clean(CleanReport) }`
- **Window and sidebar:**
  - `WindowGroup` with `NavigationSplitView`.
  - Sidebar sections: Overview, Projects (with a count badge), Activity.
  - Sidebar footer:
    - "Running in background" with a green dot, or "Helper not running" with a
      **Start** button that calls `LaunchAgent.install`
    - the "Automatic cleanup" toggle, bound to `!settings.paused`
- **Overview:**
  - **Headline:** "Saving now", with `ByteFormat` of `savings.sharedBytes`.
  - **Beside the headline:** "Caches cleared this month" with
    `history.cachesClearedThisMonth`.
  - **Drive card:** free of total, with a meter.
  - **Finder caveat** (fixed copy): "Finder's Get Info still shows each node_modules at
    full size, because it adds up every file without knowing they share space. Saving now
    is the real figure." Shown as an info popover on the headline.
  - **Job cards:**
    - "Share duplicates" with "Run now" and "Preview"
    - "Clear build caches" with "Clear now" and "Preview"
    - each shows its last run (date and freed amount) and next run, computed from
      `Schedule.nextRun`
  - **Recent activity:** the latest 5 records.
- **Activity:** the full history list, showing kind icon, summary, freed amount, time,
  and errors expanded inline.
- **Preview sheet:**
  - **Dedupe:** files that would be shared and bytes per project.
  - **Clean:** folders that would be cleared and folders skipped with their reason. The
    reasons read "Active in the last 24 hours" (using the configured window),
    "Tracked in git" and "Turned off in Settings".

- [ ] **Step 1: Write the failing test** `diskSpaceForHome`: `free > 0` and
  `total > free`.
- [ ] **Step 2:** Run `swift test --filter DiskSpaceTests`. Expected: fail.
- [ ] **Step 3:** Implement `DiskSpace`, `AppModel`, the watcher (a
  `DispatchSource.makeFileSystemObjectSource` on the state directory, with `.write`) and
  the views.
- [ ] **Step 4:** Run the tests, then run `swift run FeatherweightApp`:
  - **Overview:** shows "Saving now" and the drive numbers.
  - **Preview:** lists real projects.
  - **Run now:** updates the headline and Recent activity without a relaunch.
  - **Light and dark:** take a screenshot of each and compare with the mockup's screen 1.
- [ ] **Step 5:** Commit with `git commit -m "feat: app shell, overview, activity"`.

### Task 11: Projects screen

**Files:**
- Create: `Sources/FeatherweightApp/Views/ProjectsView.swift`, `Views/ProjectInspector.swift`, `Views/PackageManagerBadge.swift`, `Views/StatusPill.swift`

**Interfaces:**
- Consumes: `AppModel.projects`, `runClean(preview:only:)` (Task 10), and `ConversionEligibility` (Task 13). Until Task 15, the Convert button is wired to a placeholder action.
- **Table:**
  - columns: Project, Manager, node_modules, Shared, Caches, Last active, Status
  - nested projects are indented under their parent
  - the Shared column shows "via pnpm" for pnpm projects
  - toolbar: a segmented filter (All, npm, pnpm, yarn, bun) and a search field
    (`.searchable`)
- **Inspector**, at the bottom of the selected row:
  - name, path, git branch, and remote host and path
  - buttons:
    - **Show in Finder:** `NSWorkspace.activateFileViewerSelecting`
    - **Clear caches:** disabled with a `.help` tooltip giving the skip reason when the
      project is skipped
    - **Convert to pnpm…** or **Revert to npm/yarn**

- [ ] **Step 1:** Implement the views. There are no unit tests, because the logic already
  lives in Core types tested in Tasks 2, 6 and 7.
- [ ] **Step 2:** Run `swift run FeatherweightApp` against the real `~/Developer`:
  - **Projects:** 23 rows are visible, with `functions` folders nested.
  - **Status:** `MAgPIE Studio` shows ".output kept", and active projects show
    "Skipped: active".
  - **Filter and search:** both work.
  - **Mockup:** take a screenshot and compare with the mockup's screen 2.
- [ ] **Step 3:** Commit with `git commit -m "feat: projects screen"`.

### Task 12: Settings, first launch, folder policy, CLI install, update check

**Files:**
- Create: `Sources/FeatherweightCore/Install/FolderPolicy.swift`, `CLIInstaller.swift`, `UpdateChecker.swift`
- Create: `Sources/FeatherweightApp/Views/SettingsView.swift`, `Views/OnboardingView.swift`
- Modify: `Sources/FeatherweightApp/FeatherweightApp.swift` (add a `Settings` scene, and show onboarding when `!settings.onboardingComplete`), `Sources/FeatherweightCLI/Commands.swift` (`uninstall` now calls `LaunchAgent.uninstall` and `CLIInstaller.uninstall`)
- Test: `Tests/FeatherweightCoreTests/FolderPolicyTests.swift`, `CLIInstallerTests.swift`, `UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `LaunchAgent` (Task 9), `JobRunner` (Task 7), `LoginShellEnvironment` (Task 1).
- Produces:
  - `public enum FolderVerdict: Equatable { case ok, needsAccess, rejectedSync }`
  - `public struct FolderPolicy`:
    - `init(home: URL)`
    - `func evaluate(_ url: URL) -> FolderVerdict`:
      - `rejectedSync` for paths under `~/Library/Mobile Documents` or
        `~/Library/CloudStorage`, or when `ubiquitousItemIsUploadedKey`/`isUbiquitousItemKey`
        is set
      - `needsAccess` for paths under `~/Desktop`, `~/Documents` or `~/Downloads` when
        `contentsOfDirectory` throws a permission error
      - `ok` otherwise
  - `public struct CLIInstaller`:
    - `init(home: URL, pathEnv: String, fileManager: FileManager = .default)`
    - `func targetDirectory() -> URL?`: the first entry of `[~/.local/bin, /opt/homebrew/bin, /usr/local/bin]`
      that is on `PATH` and writable
    - `func install(cli: URL) throws -> URL`: creates a symlink named `featherweight`.
      Throws `CLIInstallError.noWritableDirectoryOnPath(suggestedLine: "export PATH=\"$HOME/.local/bin:$PATH\"")`.
    - `func uninstall() throws`
  - `public struct AvailableUpdate: Equatable { let version: String; let url: URL }`
  - `public struct UpdateChecker`:
    - `static let latestReleaseURL`
    - `static func isNewer(_ candidate: String, than current: String) -> Bool`: numeric
      semver comparison that ignores a leading "v"
    - `func check(current: String, fetch: @Sendable (URL) async throws -> Data) async throws -> AvailableUpdate?`:
      parses `tag_name` and `html_url`
- **Settings window:** sections match the mockup's screen 4.
  - **Projects folders:** a list with +/−. Additions go through `NSOpenPanel` and
    `FolderPolicy`:
    - `rejectedSync` shows an alert: "Featherweight can't manage folders in iCloud Drive
      or other synced folders. Offloaded files would need downloading and every change
      would re-sync."
    - `needsAccess` shows instructions to allow access for both "Featherweight" and
      "Featherweight Helper" in System Settings → Privacy & Security → Files and
      Folders, with a button that opens
      `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`.
  - **Cache folders:** a checklist, with the note ".output is off by default because
    many projects deploy from it." There's "Add folder name…" for custom relative paths,
    and the note "Folders tracked in git are never cleared."
  - **Schedules:** frequency, weekday and time pickers.
  - **Activity window:** a picker with 6, 12, 24, 48 and 72 hours.
  - **General toggles:**
    - **Run in background when I log in:** calls `LaunchAgent` install or uninstall
    - **Show notifications**
    - **Check GitHub for new versions**
    - **Install the `featherweight` terminal command:** calls `CLIInstaller`, using the
      login-shell `PATH`. On `noWritableDirectoryOnPath`, it shows the suggested line in
      a copyable field.
- **First launch** (mockup screen 5):
  1. Pick the folder, defaulting to `~/Developer` if it exists.
  2. Run `JobRunner` dry runs to show "Found N projects. About X of duplicate files can be
     shared, and Y of build caches can be cleared. Nothing has been changed yet."
  3. **Start saving space:**
     - saves the settings with `onboardingComplete = true`
     - installs the LaunchAgent with the bundled helper path (see Task 16)
     - runs `dedupe` then `clean` with trigger `.firstLaunch`
  4. **Customise settings:** opens Settings before starting.
- **Update check:** on app launch, if `checkForUpdates` is on and more than 24 hours have
  passed since `AppState.lastUpdateCheck`. `AppState` is defined in this task as
  `public struct AppState: Codable { var lastUpdateCheck: Date? }`, stored at
  `AppPaths.base/state.json` (add `var appState: URL` to `AppPaths`). When an update exists, a footer link reads
  "Version x.y.z is available" and opens `html_url`.

- [ ] **Step 1: Write failing tests**
  - `iCloudPathsRejected`: `~/Library/Mobile Documents/com~apple~CloudDocs/x` and
    `~/Library/CloudStorage/GoogleDrive-a/x` → `.rejectedSync`. Use a fake home in a temp
    dir.
  - `ordinaryFolderOK`.
  - `cliTargetPrefersLocalBin`: with PATH `"<home>/.local/bin:/usr/bin"` and that
    directory existing → `<home>/.local/bin`.
  - `cliNoWritableDirThrowsWithSuggestion`.
  - `cliInstallCreatesSymlink`, then `uninstall` removes it.
  - `isNewer`: `("v0.2.0","0.1.9")` is true, `("0.1.0","0.1.0")` false and
    `("0.10.0","0.9.0")` true.
  - `checkParsesRelease`: a fake fetch returning `{"tag_name":"v0.2.0","html_url":"https://github.com/NOVACOAX/featherweight/releases/tag/v0.2.0"}`
    with current `0.1.0` gives an update. With current `0.2.0` it gives nil.
- [ ] **Step 2:** Run `swift test --filter "FolderPolicyTests|CLIInstallerTests|UpdateCheckerTests"`.
  Expected: fail.
- [ ] **Step 3:** Implement the Core types, then the views.
- [ ] **Step 4:** Run the tests, then manually:
  1. Delete `settings.json` in a scratch state directory. Launch, and the first launch
     shows with real estimates.
  2. "Customise settings" opens Settings. Toggling `.output` persists.
  3. Adding `~/Library/Mobile Documents/…` is refused with the alert text.
- [ ] **Step 5:** Commit with `git commit -m "feat: settings, onboarding, folder policy, CLI install, updates"`.

> **Shipped after v1:** pnpm conversion (Tasks 13–15) was deferred from v0.1.x on
> 2026-11-09 and finished on the `pnpm-conversion` branch on 2026-11-12. The "Convert to
> pnpm…" button is back and the README documents conversion.

### Task 13: pnpm conversion engine

**Files:**
- Create: `Sources/FeatherweightCore/Pnpm/RewriteTypes.swift`, `ConversionEligibility.swift`, `PnpmToolchain.swift`, `BuildScriptDetector.swift`, `ConversionBackup.swift`, `PnpmConverter.swift`
- Test: `Tests/FeatherweightCoreTests/ConversionEligibilityTests.swift`, `BuildScriptDetectorTests.swift`, `ConversionBackupTests.swift`, `PnpmConverterTests.swift`, `Tests/FeatherweightCoreTests/Support/FakeCommandRunner.swift`

**Interfaces:**
- Consumes:
  - `CommandRunner` and `ProcessCommandRunner` (Task 1)
  - `Project`, `PackageManager` and `ActivityChecker` (Task 2)
  - `CloneFS.privateBytes` (Task 3)
- Produces:
  - In `RewriteTypes.swift` (Task 14 implements the rewriter against these, and Task 13's
    tests use a stub):
    - `public struct RewriteWarning: Codable, Sendable, Hashable { let file: String; let line: Int; let text: String }`
    - `public struct FileRewrite: Sendable { let relativePath: String; let original: String; let rewritten: String; let warnings: [RewriteWarning]; var changed: Bool }`
    - `public protocol ConfigRewriting: Sendable { func rewriteProject(root: URL, from: PackageManager, pnpmVersion: String) throws -> [FileRewrite] }`
  - `public enum Ineligibility: String, Codable, Sendable { case bun, alreadyPnpm, workspaces, recentlyActive, noLockfile }`.
    Each case has a `message`:
    - bun: "pnpm can't import bun lockfiles"
    - alreadyPnpm: "Already uses pnpm"
    - workspaces: "Monorepos with workspaces aren't supported yet"
    - recentlyActive: "Active in the last N hours"
    - noLockfile: "No lockfile to import"
  - `public enum ConversionEligibility { static func check(_ project: Project, activity: ActivityChecker, windowHours: Int) -> Ineligibility? }`
  - `public struct PnpmToolchain`:
    - `init(runner: CommandRunner)`
    - `static let minimumMajor = 10`
    - `func installedVersion() -> String?`: from `pnpm --version`
    - `func isSupported(_ version: String) -> Bool`
    - `static let installCommands: [[String]] = [["corepack", "enable", "pnpm"], ["npm", "install", "-g", "pnpm@latest"]]`
    - `func install() throws -> String`: tries each command in order and returns the
      command that succeeded
  - `public struct BuildScriptDetector`:
    - `func packagesWithInstallScripts(root: URL) -> [String]`, sorted and unique
    - for npm, it reads `package-lock.json` `packages` entries with
      `"hasInstallScript": true`, taking the name from the key's last
      `node_modules/<name or @scope/name>`
    - otherwise it scans `node_modules/*/package.json` and
      `node_modules/@*/*/package.json` for `scripts.preinstall`, `scripts.install` or
      `scripts.postinstall`, or a sibling `binding.gyp`
  - `public struct ConversionBackup: Codable`, with these members:
    - `let id: UUID`
    - `let projectRoot: String`
    - `let createdAt: Date`
    - `let originalManager: PackageManager`
    - `let entries: [String: Bool]`: relative path → existed before
    - `static func create(root: URL, relativePaths: [String], manager: PackageManager, paths: AppPaths) throws -> ConversionBackup`
    - `func restore(paths: AppPaths) throws`: rewrites the files that existed
      byte-for-byte and deletes the ones that didn't
    - `static func latest(for root: URL, paths: AppPaths) -> ConversionBackup?`

    Stored at `backups/<sha256(root path) prefix 16>/<id>/` with a `manifest.json`.
  - `public enum ConversionStep: String, Sendable { case backingUp, importing, installing, buildCheck, rewritingConfigs, cleaningUp }`
  - `public struct FileChange: Sendable, Hashable { enum Kind { case added, modified, deleted }; let relativePath: String; let kind: Kind; let diff: String }`
  - `public struct ConversionResult: Sendable`:
    - `let changes: [FileChange]`
    - `let warnings: [RewriteWarning]`
    - `let bytesFreed: Int64`
    - `let backupID: UUID`
    - `let pnpmVersion: String`
  - `public struct ConversionFailure: Error`:
    - `let step: ConversionStep`
    - `let command: String`
    - `let output: String`
    - `let reverted: Bool`
  - `public struct PnpmConverter`:
    - `init(runner: CommandRunner, paths: AppPaths, rewriter: ConfigRewriting)`
    - `func convert(_ project: Project, runBuildCheck: Bool, progress: @Sendable (ConversionStep) -> Void) throws -> ConversionResult`
    - `func revert(_ project: Project, backup: ConversionBackup) throws`
- **Convert sequence.** The caller, `AppModel` in Task 15, wraps `convert` and `revert`
  in `JobRunner.withLock`.
  1. **Back up** every file that may change: the old lockfile, `package.json`,
     `pnpm-workspace.yaml`, and every file the rewriter would touch (dry rewrite first).
  2. Measure `before = CloneFS.privateBytes(under: node_modules)`.
  3. Run `pnpm import`.
  4. **Allow build scripts:** if `BuildScriptDetector` finds packages, write
     `pnpm-workspace.yaml` containing only `onlyBuiltDependencies:` followed by
     `  - <name>` lines.
  5. Remove `node_modules`, then run `pnpm install --frozen-lockfile`.
  6. If `runBuildCheck` is set and `package.json` has a `build` script, run
     `pnpm run build`.
  7. Apply the rewrites.
  8. Delete the old lockfile.
  9. Compute `bytesFreed = max(0, before − privateBytes(after))`.
  10. Generate diffs with `/usr/bin/diff -u` between the backup and the new files, or
      against `/dev/null` for added and deleted files.
- **On failure:** if any command exits non-zero or anything throws, restore the backup.
  Remove `node_modules` and `pnpm-lock.yaml` (if it didn't exist before), reinstall with
  the original manager, then throw `ConversionFailure(reverted: true)`. The reinstall
  command is `npm ci` for npm and `yarn install --frozen-lockfile` for yarn.
- **Revert:** restore the backup, remove `node_modules` and `pnpm-lock.yaml`, and
  reinstall with the original manager the same way.
- **Environment:** every command runs through the injected `CommandRunner`. In
  production that's `ProcessCommandRunner` with the login-shell environment (Review
  Focus 1).

- [ ] **Step 1: Write failing tests.** `FakeCommandRunner` records calls and returns
  scripted results keyed by `"command args…"`, and can run a closure that mutates the
  temp project, for example to create `pnpm-lock.yaml`.
  - `eligibility`: one case for each `Ineligibility`. An npm project with an old mtime
    → nil. `package.json` with `"workspaces"` → `.workspaces`.
  - `detectorReadsLockfileFlags`: a lock with `node_modules/esbuild` and
    `node_modules/@prisma/engines` both `hasInstallScript` → `["@prisma/engines", "esbuild"]`.
  - `detectorFallsBackToNodeModules`: a yarn project with `node_modules/sharp/package.json`
    that has `scripts.install` → `["sharp"]`.
  - `backupRestoresByteForByte`: back up `package.json` (existed) and `pnpm-lock.yaml`
    (didn't). Then modify the first and create the second. Restoring brings back
    identical bytes and deletes `pnpm-lock.yaml`.
  - `convertHappyPath`: the fake runner succeeds, and calls happen in exactly this order:
    1. `pnpm import`
    2. `pnpm install --frozen-lockfile`
    3. `pnpm run build`

    Afterwards `package-lock.json` is gone, `pnpm-lock.yaml` exists,
    `pnpm-workspace.yaml` lists the detected packages, and `changes` includes a deleted
    `package-lock.json`.
  - `convertFailureRevertsEverything` (Review Focus 5): `pnpm install` exits 1, and the
    project contains an unrelated uncommitted file `notes.md`. The call throws
    `ConversionFailure(step: .installing, reverted: true)`. Afterwards:
    - `package-lock.json` and `package.json` are byte-identical to before
    - `pnpm-lock.yaml` and `pnpm-workspace.yaml` don't exist
    - `notes.md` is unchanged
    - the last command run is `npm ci`
  - `buildCheckSkippedWithoutBuildScript`.
  - `toolchainVersionGate`: `"9.15.0"` is unsupported and `"10.33.2"` supported.
  - `toolchainInstallFallsBack`: `corepack` fails and `npm install -g pnpm@latest`
    succeeds → returns the npm command.
  - `realPnpmIntegration`: a real temp npm project with one dependency (`is-number`),
    using `ProcessCommandRunner`. It is skipped via `.enabled(if:)` when `pnpm` isn't on
    the login-shell `PATH` or there's no network. A real convert gives a
    `pnpm-lock.yaml`, and revert brings back `package-lock.json`.
- [ ] **Step 2:** Run `swift test --filter "ConversionEligibilityTests|BuildScriptDetectorTests|ConversionBackupTests|PnpmConverterTests"`.
  Expected: fail.
- [ ] **Step 3:** Implement as specified above.
- [ ] **Step 4:** Run the tests. Expected: pass, with `realPnpmIntegration` passing on
  this machine (pnpm 10.33.2 is installed).
- [ ] **Step 5:** Commit with `git commit -m "feat: pnpm conversion engine"`.

### Task 14: Config rewriter

**Files:**
- Create: `Sources/FeatherweightCore/Pnpm/ConfigRewriter.swift`, `CommandRewriter.swift`
- Test: `Tests/FeatherweightCoreTests/CommandRewriterTests.swift`, `ConfigRewriterTests.swift`

**Interfaces:**
- Consumes: `PackageManager` (Task 2), and `RewriteWarning`, `FileRewrite` and `ConfigRewriting` (Task 13).
- Produces:
  - `public enum CommandRewriter { static func rewrite(_ command: String, from: PackageManager, scripts: Set<String>, dependencyBins: Set<String>) -> (String, uncertain: [String]) }`.
    The input is one shell command line. It is split on `&&`, `||`, `;` and `|`, and only
    segments whose first word is `npm`, `npx` or `yarn` are rewritten. The uncertain list
    holds the segments it left alone.
  - `public struct ConfigRewriter: ConfigRewriting`, providing `rewriteWorkflow`,
    `rewriteDockerfile`, `rewriteFirebase`, `rewriteNetlify`, `rewriteVercel` and
    `rewritePackageJSON`. Each has the shape `(text: String, file: String, from: PackageManager, context: RewriteContext) -> FileRewrite`.
    `RewriteContext` holds the script names, dependency bins, old lockfile name and
    pnpm version.
- **Command table.** Anything not listed here is uncertain. It is left as-is and becomes
  a warning.

  | From | To |
  |---|---|
  | `npm ci` | `pnpm install --frozen-lockfile` |
  | `npm install` / `npm i` (no further args) | `pnpm install` |
  | `npm run X [-- args]` / `npm run-script X` | `pnpm run X [-- args]` |
  | `npm test` / `npm start` | `pnpm test` / `pnpm start` |
  | `npm --prefix D run X` / `npm run X --prefix D` | `pnpm --dir D run X` |
  | `npx X …` where X ∈ dependencyBins | `pnpm exec X …` |
  | `npx X …` otherwise | `pnpm dlx X …` |
  | `yarn` / `yarn install` | `pnpm install` |
  | `yarn install --frozen-lockfile` / `--immutable` | `pnpm install --frozen-lockfile` |
  | `yarn run X` / `yarn X` where X ∈ scripts | `pnpm run X` |
  | `yarn dlx X` | `pnpm dlx X` |
- **Workflow extras:**
  - For each `- uses: actions/setup-node@…` step, insert a sibling step
    `- uses: pnpm/action-setup@v4` immediately before it, at the same indentation.
  - Inside the `with:` block, `cache: npm`, `cache: 'npm'`, `cache: "npm"` and the
    `yarn` equivalents become `cache: pnpm`.
  - If npm or yarn commands are present but there's no `setup-node` step, warn.
- **Dockerfile:**
  - `COPY` lines naming the old lockfile name `pnpm-lock.yaml` instead.
  - `RUN npm ci` and `RUN npm install` become
    `RUN corepack enable && pnpm install --frozen-lockfile`.
  - Other `RUN npm …` lines are rewritten through the command table. If no install line
    was rewritten earlier in the file, add a warning.
- **JSON files** (`firebase.json` predeploy and postdeploy arrays, `vercel.json`
  `installCommand` and `buildCommand`, and `package.json` `scripts`): edit the file
  textually so formatting and key order are kept. Parse with `JSONSerialization` to find
  the string values, then replace each old JSON-encoded string literal with the new one.
  The replacement is unique within its enclosing object.
- **`netlify.toml`:** the `command = "…"` lines.
- **`package.json`:** in addition to scripts, a `"packageManager": "npm@…"` or
  `"yarn@…"` value becomes `"pnpm@<version>"`. No new field is ever added.
- **`rewriteProject(root:from:pnpmVersion:)`:** applies the matching rewriter to:
  - `.github/workflows/*.yml` and `*.yaml`
  - `Dockerfile*`
  - `firebase.json`
  - `netlify.toml`
  - `vercel.json`
  - `package.json`

  It returns only the rewrites that changed something or have warnings.

- [ ] **Step 1: Write failing tests.** Each rewriter gets fixture strings inline.
  - **Command table:** one test per row above, with exact input and output.
  - `uncertainInstallWithArgs`: `npm install firebase-functions@6.6.0 firebase-admin@13.10.0 --prefix /tmp/fb-install`
    is unchanged and uncertain. This is the real `magpie_executive_web` `deploy-app`
    segment. The surrounding `rm -rf …` and `cp …` segments are untouched.
  - `chainedCommands`: `npm run build && npx firebase deploy` with `firebase` not in the
    bins → `pnpm run build && pnpm dlx firebase deploy`.
  - `workflowInsertsActionSetupAndCache`: a fixture job with `actions/checkout@v4`, then
    `actions/setup-node@v4` with `cache: 'npm'`, then `run: npm ci`, then
    `run: npm test`. The expected output has the inserted `pnpm/action-setup@v4` step at
    the same indent, `cache: pnpm`, `pnpm install --frozen-lockfile` and `pnpm test`.
  - `workflowWarnsWithoutSetupNode`.
  - `dockerfileRewrite`: `COPY package.json package-lock.json ./` and `RUN npm ci` →
    `COPY package.json pnpm-lock.yaml ./` and
    `RUN corepack enable && pnpm install --frozen-lockfile`.
  - `firebasePredeploy`: `"npm --prefix \"$RESOURCE_DIR\" run build"` →
    `"pnpm --dir \"$RESOURCE_DIR\" run build"`, and the rest of the file is
    byte-identical.
  - `packageJSONKeepsFormatting`: 4-space indent and key order are kept. Only the script
    values and the `packageManager` value change.
  - `packageJSONNoPackageManagerFieldAdded`.
  - `netlifyCommand`.
  - `vercelInstallCommand`.
  - `warningCarriesFileAndLine`: the warning for the uncertain line has the correct
    1-based line number.
- [ ] **Step 2:** Run `swift test --filter "CommandRewriterTests|ConfigRewriterTests"`.
  Expected: fail.
- [ ] **Step 3:** Implement as specified above, and swap the Task 13 stub for the real
  rewriter.
- [ ] **Step 4:** Run `swift test`. Expected: everything passes, including
  `PnpmConverterTests`.
- [ ] **Step 5:** Commit with `git commit -m "feat: deterministic config rewriter for pnpm conversion"`.

### Task 15: Conversion sheets in the app

**Files:**
- Create: `Sources/FeatherweightApp/Views/ConvertConfirmSheet.swift`, `Views/ConversionProgressSheet.swift`, `Views/ConversionDoneSheet.swift`, `Views/DiffView.swift`, `Views/InstallPnpmSheet.swift`
- Modify: `Sources/FeatherweightApp/AppModel.swift` (add `convert`, `revert`, `commitConversion` and `pushConversion`; `convert` and `revert` run inside `JobRunner.withLock`, showing "Waiting for another Featherweight job to finish…" while waiting), `Views/ProjectInspector.swift` (wire the buttons)

**Interfaces:**
- Consumes: `PnpmConverter`, `PnpmToolchain`, `ConversionEligibility`,
  `ConversionBackup.latest` and `ConversionResult` (Task 13); `GitClient` (Task 6);
  `ConfigRewriter` (Task 14).
- **Sheets:** the content follows the mockup's screen 3 and the spec.
  - **Install pnpm:** shown when `installedVersion()` is nil or under 10. It shows the
    exact command it will run (Corepack first) and runs it only on click.
  - **Confirm:**
    - title "Convert <name> to pnpm?"
    - the steps list
    - the warning "Anyone who clones this project from GitHub will need pnpm to install
      it."
    - a toggle "Run the build script to check it still works", on by default and shown
      only when a `build` script exists
    - buttons **Cancel** and **Convert**
  - **Progress:** the current `ConversionStep`, with a live log of command output.
  - **Failure:** "Conversion failed at <step>. Everything was put back the way it was."
    It shows a disclosure with the command output.
  - **Done:**
    - "Freed X."
    - the list of changes, each expandable to its `DiffView`
    - the warnings section "These still mention npm and weren't changed:", with each
      warning as `file:line` and its text
    - an editable commit message, defaulting to "Switch from npm to pnpm" or
      "Switch from yarn to pnpm"
  - **Done-sheet buttons:**
    - **Revert**
    - **Not now**
    - **Commit:** shown only in a git repo
    - **Commit & Push:** shown only when there's an upstream, with the caption
      "Pushes to origin/main · <remote>"
    - the primary button is **Commit & Push**, unless there are warnings, in which case
      it's **Commit**
  - **Commit and push behaviour:**
    - Commit stages exactly `changes.map(\.relativePath)` through `GitClient.commit`.
    - A push failure shows git's stderr, and the commit stays local.
  - **Inspector:** shows **Revert to npm/yarn** while `ConversionBackup.latest` exists
    for the project.
- **History:** convert and revert append `RunRecord`s with kind `.convert` or `.revert`.

- [ ] **Step 1:** Implement the sheets and the `AppModel` methods.
- [ ] **Step 2: Manual end-to-end check** on a scratch copy of a real npm project. Copy
  `~/Developer/hughvies` (npm, has a git remote) to a temp folder. In the copy, run
  `git remote set-url origin` to point at a local bare repo, so the push can't reach
  GitHub. Then:
  1. **Convert:** it succeeds, and the done sheet lists the lockfile changes and diffs.
  2. **Commit & Push:** it lands in the bare repo, and `git log` shows only the
     conversion files.
  3. **Revert:** `package-lock.json` comes back.
  4. **Forced failure:** add a broken dependency, then convert. You see the failure
     sheet, and `git status` shows no changes besides the injected break.
- [ ] **Step 3:** Commit with `git commit -m "feat: pnpm conversion UI"`.

---

## Milestone D: packaging, release, README

### Task 16: Icon, bundle assembly, signing

**Files:**
- Create: `Resources/AppIcon.svg` (copy of `docs/superpowers/specs/assets/featherweight-logo.svg`), `Resources/Info-App.plist`, `Resources/Info-Helper.plist`, `scripts/make-icon.swift`, `scripts/build-app.sh`
- Modify: `Sources/FeatherweightApp/AppModel.swift` (add `bundledHelperURL` and `bundledCLIURL`, derived from `Bundle.main`)

**Interfaces:**
- Produces:
  - **Bundle layout:**

    ```
    build/Featherweight.app/Contents/
      Info.plist                       (Info-App.plist; CFBundleIdentifier com.novacoax.featherweight,
                                        CFBundleExecutable Featherweight, LSMinimumSystemVersion 14.0,
                                        CFBundleIconFile AppIcon, CFBundleShortVersionString = VERSION)
      MacOS/Featherweight              (FeatherweightApp product)
      Helpers/featherweight            (CLI; Helpers/ avoids the case-insensitive clash with MacOS/Featherweight)
      Library/LoginItems/Featherweight Helper.app/Contents/
        Info.plist                     (com.novacoax.featherweight.helper, LSUIElement true,
                                        CFBundleDisplayName "Featherweight Helper")
        MacOS/FeatherweightHelper
        Resources/AppIcon.icns
      Resources/AppIcon.icns
    ```

  - `scripts/build-app.sh [--version X.Y.Z]`:
    1. Run `swift build -c release --arch arm64 --arch x86_64` for the 3 products.
    2. Assemble the bundle above.
    3. Write the version with `plutil -replace CFBundleShortVersionString` and
       `CFBundleVersion`.
    4. Run `make-icon.swift`, then `iconutil -c icns`.
    5. Sign inside-out (CLI, helper app, main app) with
       `codesign --force --timestamp=none --sign "$IDENTITY"`. `IDENTITY` is
       `"Featherweight Self-Signed"` if
       `security find-certificate -c "Featherweight Self-Signed"` succeeds; otherwise
       it's `-` (ad-hoc), with a printed warning.
    6. Run `codesign --verify --deep --strict`.
    7. Print the bundle path and size.
  - `scripts/make-icon.swift <svg> <iconset-dir>` renders with `NSImage(contentsOf:)`,
    which is verified to render this SVG on this machine. It writes the standard 10
    `icon_*.png` sizes (16 through 512@2x). The artwork is inset to Apple's icon grid:
    the 824×824 tile is centred in 1024×1024 with a transparent margin.
  - **Bundled paths:** the app finds the helper and CLI through `Bundle.main.bundleURL`.
    The LaunchAgent install (Task 12) uses the helper executable path inside the
    installed app. On launch, if `LaunchAgent` points at a different path (the app was
    moved), the app reinstalls it.

- [ ] **Step 1:** Write the plists and scripts.
- [ ] **Step 2:** Run `scripts/build-app.sh --version 0.1.0`. Expected:
  - `codesign --verify` passes
  - `lipo -archs build/Featherweight.app/Contents/MacOS/Featherweight` prints
    `x86_64 arm64`
  - `ditto -c -k --keepParent build/Featherweight.app /tmp/fw.zip` gives a file under
    10 MB
- [ ] **Step 3: Quarantine check** (spec constraint).
  1. Run `xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" /tmp/fw.zip`.
  2. Unzip into a scratch `Applications` folder and open it.
  3. Gatekeeper blocks the first launch.
  4. Use **Open Anyway** in System Settings → Privacy & Security, and the app launches.
  5. The first-launch flow installs the LaunchAgent.
  6. After logging out and in, `HelperHeartbeat.isAlive()` is true and notifications
     arrive.

  Record the exact Gatekeeper wording and screenshots for the README.
- [ ] **Step 4:** Commit with `git commit -m "build: app bundle, icon, signing"`.

### Task 17: Release pipeline

**Files:**
- Create: `scripts/setup.sh`, `scripts/hooks/pre-push`, `scripts/publish-release.sh`, `scripts/create-signing-cert.sh`

**Interfaces:**
- Consumes: `scripts/build-app.sh` (Task 16), the `VERSION` file (Task 1), and `gh`.
- **`setup.sh`:**
  - runs `git config core.hooksPath scripts/hooks`
  - checks that `gh auth status` succeeds
  - offers to run `create-signing-cert.sh`
- **`create-signing-cert.sh`:**
  1. Generate a self-signed code-signing certificate named "Featherweight Self-Signed"
     with `openssl req -x509` and the `extendedKeyUsage=codeSigning` extension, valid
     for 10 years.
  2. `security import` the `.p12` into the login keychain, with
     `-T /usr/bin/codesign`.
  3. `security add-trusted-cert -p codeSign` (this prompts for the user's password once).
  4. Print `security find-identity -p codesigning` so the identity shows up.
  5. If the identity already exists, exit early.
- **`hooks/pre-push`:** it reads `<local ref> <local sha> <remote ref> <remote sha>`
  lines from stdin and acts only for `refs/heads/main`.
  1. `NEW=$(git show <local sha>:VERSION)`.
  2. `LATEST=$(gh release view --repo NOVACOAX/featherweight --json tagName -q .tagName 2>/dev/null | sed 's/^v//')`.
  3. If they're equal, exit 0.
  4. Otherwise, run `scripts/build-app.sh --version $NEW`. On failure, print
     "Release build failed: push stopped so v$NEW never reaches main without its
     release." and exit 1.
  5. Zip to `build/release/Featherweight-$NEW.zip`.
  6. Start `nohup scripts/publish-release.sh $NEW <local sha> >> build/release/publish.log 2>&1 &`.
  7. Exit 0.
- **`publish-release.sh VERSION SHA`:**
  1. Poll `git ls-remote origin refs/heads/main` every 5 seconds, for up to 10 minutes,
     until it equals `SHA`.
  2. Run `gh release create v$VERSION build/release/Featherweight-$VERSION.zip --repo NOVACOAX/featherweight --target $SHA --title "Featherweight $VERSION" --generate-notes`.
  3. Show a macOS notification with `osascript -e 'display notification …'` on success
     or failure.

  If the repo doesn't exist on GitHub yet, it logs that and exits non-zero.

- [ ] **Step 1:** Write the scripts.
- [ ] **Step 2: Verify without touching GitHub.**
  1. Run `bash -n` on each script.
  2. Run `scripts/hooks/pre-push` with crafted stdin for `refs/heads/feature`. It exits
     0 without building.
  3. For `refs/heads/main`, with `gh` stubbed by a `PATH`-prefixed fake script that
     prints `v0.1.0` and `VERSION=0.1.0`, it exits 0 without building.
  4. With the fake printing `v0.0.9`, it builds and starts the publisher, which the fake
     `git ls-remote` and `gh` record.
- [ ] **Step 3:** Commit with `git commit -m "build: release pipeline on push to main"`.

### Task 18: README and repo polish

**Files:**
- Create: `README.md`, `docs/images/` (screenshots of Overview, Projects, Conversion done and Settings in both light and dark, plus `icon.png` rendered from the SVG at 256 px)

**Interfaces:**
- Consumes: the screenshots from running the built app (Tasks 10–16), and the Gatekeeper
  wording from Task 16, Step 3.
- **README sections, in order:**
  1. Logo and title, with the tagline "node_modules, but light."
  2. What it does: the three features.
  3. How sharing duplicates saves space, including the Finder "Get Info" caveat.
  4. Safety: what is never touched.
  5. Requirements: macOS 14+ and APFS.
  6. Install.
  7. **First launch:**
     - the "Apple could not verify…" message
     - System Settings → Privacy & Security → **Open Anyway**
     - the alternative `xattr -dr com.apple.quarantine /Applications/Featherweight.app`
     - why this is needed: there's no paid developer account, and the source is open
  8. Settings.
  9. The terminal command, with every subcommand.
  10. Converting to pnpm: what changes, CI and deploy rewriting and warnings,
      collaborators needing pnpm, and Revert.
  11. Uninstalling: `featherweight uninstall`, then delete the app. Projects keep
      working.
  12. Building from source: `swift build`, `scripts/build-app.sh`.
  13. How releases are made: `scripts/setup.sh`, bump `VERSION`, push to `main`.
  14. License: MIT.

  Include the measured example from the spec (2.8 GB duplicates, 12.6 GB caches on a
  real machine).

- [ ] **Step 1:** Capture the screenshots with `screencapture -l <windowid>` from the
  built app, then write the README.
- [ ] **Step 2: Verify.**
  - Every command in the README runs as written in a fresh shell.
  - Every image link resolves (`ls docs/images`).
  - Read it start to finish against the spec's list of README contents.
- [ ] **Step 3:** Commit with `git commit -m "docs: README"`.

Creating the GitHub repo and the first push are Hugh's step, or happen on his explicit
say-so. They are not part of this plan.
