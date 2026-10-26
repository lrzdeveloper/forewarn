# ADR 0001: Project structure

Status: accepted (2026-10-27)

## Context

No public template covered a modern menu bar app with tests, lint and CI together. The closest
reference is [Menuet](https://github.com/jkasky/Menuet) (2026, XcodeGen, Icon Composer icon,
host-less logic tests, signed and notarized release workflow).

## Decision

- **XcodeGen** (`project.yml`) generates the Xcode project; `project.pbxproj` is not committed, so
  there are no merge conflicts on it.
- **App target + local Swift package.** `App/` holds UI and system wiring; `ForewarnKit/` holds the
  logic and runs under `swift test` without launching the app (plan Phase 0 CI requirement).
- **Signing** defaults to ad-hoc in `Forewarn.xcconfig`; developers set their team in a gitignored
  `Forewarn.local.xcconfig`. Release signing happens in CI (Phase 6).
- **Info.plist** is generated from build settings (`INFOPLIST_KEY_*`); a real file is added when
  Sparkle needs custom keys.
- **Not sandboxed** (Developer ID distribution): IOKit power data, `sysctl` counters and folder
  scans need it. Hardened runtime is on for notarization.
- **graphify** knowledge graph lives in `graphify-out/` (gitignored), rebuilt by post-commit and
  post-checkout hooks, so it never blocks or bloats a commit.

## Consequences

- Run `make generate` after cloning or after adding files to `App/`.
- Phase 6 reuses Menuet's `release.yml` shape: tag-triggered, Developer ID import into a temp
  keychain, `notarytool` with an App Store Connect API key, build number from `git rev-list --count`.
