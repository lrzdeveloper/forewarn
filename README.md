# Forewarn

[![CI](https://github.com/lrzdeveloper/forewarn/actions/workflows/ci.yml/badge.svg)](https://github.com/lrzdeveloper/forewarn/actions/workflows/ci.yml)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**Your Mac, warned before it runs out.**

Forewarn is a menu bar app that learns how you use your Mac and tells you *before* something runs
out: battery before your usual charging time, disk space weeks ahead, mobile data before the monthly
allowance ends, and unusual battery drain while the Mac sleeps. Each alert says why and offers one
action. Everything runs on your Mac, and Forewarn shows how much energy it uses itself.

> **Status:** early development (Phase 0). Not ready to install yet. See [`docs/PROGRESS.md`](docs/PROGRESS.md).

## What it warns you about

| | Feature | Example |
|---|---|---|
| 🔋 | **Battery runway** | "Charge when you can: you reach 10% around 15:40, and you usually plug in after 18:00." |
| 💾 | **Disk runway** | "Your disk fills up in about 3 weeks. 42 GB in Downloads haven't been opened in 6 months." |
| 🌙 | **Sleep drain** | "You lost 18% while asleep (usually 2%). Docker kept the Mac awake." |
| 📶 | **Metered data** | "At this pace you run out of data on the 24th." |
| 🩺 | **Battery health** | At most once a month, only when something changed meaningfully. |

On desktop Macs the battery features hide themselves; disk and data warnings remain.

## How it works

```
Collectors ──► Store (SQLite) ──► Forecasting ──► Insights ──► Notifications
                                                                    │
                                     UI (menu bar popover, Settings, Onboarding)
```

- **Collectors** read battery, power state, disk, network and sleep events through public Apple APIs
  (IOKit, `NWPathMonitor`, `NSWorkspace`), sampling every few minutes at most.
- **Forecasting** produces probability bands, not single guesses. A seasonal baseline ships first;
  an on-device time-series model (Timestral, Core ML) is used only when it beats the baseline
  on *your* Mac's own history.
- **Insights** are plain rules: your charging habits, the chance of hitting 10% before you usually
  plug in, the folders that grew. No cloud AI.
- **Notifications** are rate-limited (at most one per kind per day) and back off on their own
  if you keep dismissing them.

## Privacy

- All data stays in `~/Library/Application Support/Forewarn/`. No accounts, no telemetry.
- Folder scanning for disk suggestions is opt-in per folder.
- Settings lets you export everything as CSV or delete it all.
- Any network call (update checks) is listed in Settings → Privacy.

## Energy

Forewarn's own target: Activity Monitor "Energy Impact" ≈ 0, under **0.05% of battery per day**,
no timers more frequent than 5 minutes while idle, never waking the Mac. The popover shows what it
actually used today. Measured numbers will be published in `docs/energy-report.md`.

## Install

Coming with the first release, signed and notarized:

```sh
brew install --cask lrzdeveloper/tap/forewarn
```

## Development

Requirements: macOS 26+, Xcode 26+, Homebrew.

```sh
brew install xcodegen swiftlint swiftformat
git clone https://github.com/lrzdeveloper/forewarn.git && cd forewarn
make run        # generate the Xcode project, build, launch into the menu bar
```

| Command | What it does |
|---|---|
| `make generate` | Generate `Forewarn.xcodeproj` from `project.yml` (the project file is not committed) |
| `make build` | Debug build into `build/` |
| `make test` | Logic tests in `ForewarnKit` (`swift test`, no app host) |
| `make uitest` | End-to-end UI tests (XCUITest): launch the real app, click the menu bar icon, open Settings. Keep the Forewarn icon visible if you use a menu bar manager |
| `make lint` / `make format` | SwiftFormat + SwiftLint check / autofix |
| `make graph` | Rebuild the [graphify](https://github.com/Graphify-Labs/graphify) knowledge graph |

To sign with your own team, create `Forewarn.local.xcconfig`:

```
DEVELOPMENT_TEAM = YOURTEAMID
CODE_SIGN_IDENTITY = Apple Development
```

### Repository layout

```
App/            SwiftUI app: menu bar, Settings, onboarding
ForewarnKit/    Swift package with the logic: collectors, store, forecasting, insights (+ tests)
UITests/        End-to-end tests driving the real app (XCUITest)
docs/           Plan, progress notes, ADRs
project.yml     XcodeGen spec
```

The full design is in [`docs/forewarn_plan.md`](docs/forewarn_plan.md); decisions are recorded in
[`docs/adr/`](docs/adr/). AI coding agents start from [`AGENTS.md`](AGENTS.md).

## Roadmap

| Phase | Scope |
|---|---|
| 0 | Setup, empty menu bar app, Timestral → Core ML spike |
| 1 | Collectors and storage |
| 2 | Forecasting engines and backtests |
| 3 | Insights and notifications |
| 4 | UI, localization (EN/IT), accessibility |
| 5 | Energy and quality audit |
| 6 | Signed DMG, Sparkle updates, Homebrew cask |

## License

Code is licensed under [Apache-2.0](LICENSE). Forecasting model weights, when used, are downloaded
separately under their own license, shown at first run.
