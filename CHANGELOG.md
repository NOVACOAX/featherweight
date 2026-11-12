# Changelog

All notable changes to Featherweight are listed here. Versions follow
[semantic versioning](https://semver.org).

## [Unreleased]

### Added

- **Convert to pnpm…** on the Projects screen converts an npm or yarn project to pnpm with
  the same package versions. It backs up every file first, updates CI, Docker and deploy
  configs it recognises with certainty, lists the ones it couldn't change, and offers
  **Commit**, **Commit & Push** and **Revert**. A failed conversion puts everything back.

## [0.1.1] - 2026-11-10

### Fixed

- The first launch screen no longer reads every file in your `node_modules` folders just to
  estimate the savings. The estimate now takes seconds on a large Developer folder instead of
  many minutes.
- The background helper no longer starts sharing duplicates or clearing caches before you click
  **Start saving space**. It also no longer runs a second full sweep straight after first launch.

## [0.1.0] - 2026-11-09

First release.

### Added

- Shares identical files across every `node_modules` folder as APFS clones, so each copy takes
  space only once. Projects keep their own folders and work exactly as before.
- Clears regenerable build caches (`.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`,
  `.cache`, `node_modules/.cache`, `node_modules/.vite`) once a week. Folders tracked in git,
  projects active in the last 24 hours and `.output` are left alone.
- A background helper that starts at login, tidies up about a minute after each install and
  sweeps on a schedule, with notifications.
- The Featherweight app: Overview ("Saving now"), Projects, Activity, Settings and a first
  launch screen that shows what can be saved before anything changes.
- The `featherweight` terminal command: `status`, `dedupe`, `clean`, `projects`, `log`,
  `pause`, `resume` and `uninstall`.
- Refuses iCloud Drive and other synced folders.
- Optional daily check for new versions on GitHub. No other network use and no telemetry.
