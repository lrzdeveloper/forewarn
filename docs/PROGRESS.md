# Progress

## Phase 0 — Setup and spike (in progress)

Done:
- Repo, Apache-2.0 license, README, CI (lint + `swift test` + app build on `macos-26`).
- Menu bar app (`MenuBarExtra`, `.window` style), `LSUIElement`, Settings scene with launch at login
  via `SMAppService.mainApp`.
- `ForewarnKit` package with the `ForecastEngine` contract of plan §3.3 and its tests.
- XCUITest end-to-end test: menu bar icon → popover → Settings.
- graphify knowledge graph, rebuilt by git hooks.

Next:
- Timestral spike in `tools/convert/` (uv project), outcome recorded as an ADR.
