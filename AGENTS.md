# Forewarn

macOS menu bar app that learns how this Mac is used and warns *before* something runs out:
battery, disk space, metered data, abnormal sleep drain. Local-only, measures its own energy use.

The plan in [`docs/forewarn_plan.md`](docs/forewarn_plan.md) is the spec: features F1–F5, architecture,
thresholds, energy budget, phases. Read the section you are touching before changing behaviour.
Current phase and demo notes: [`docs/PROGRESS.md`](docs/PROGRESS.md). Decisions: [`docs/adr/`](docs/adr/).

## Layout

- `App/`: SwiftUI app target (menu bar, Settings, onboarding). UI and system wiring only.
- `ForewarnKit/`: Swift package with all testable logic (collectors, store, forecasting, insights).
  New logic goes here, behind protocols with fakes, so it runs under `swift test` with no app host.
- `UITests/`: XCUITest end-to-end tests that launch the real app and click through it (`make uitest`).
  Every user-visible flow gets one.
- `project.yml`: XcodeGen spec. `Forewarn.xcodeproj` is generated and gitignored; after editing
  `project.yml` or adding/removing files in `App/`, run `make generate`.
- `Forewarn.xcconfig`: signing defaults (ad-hoc). Your team ID goes in `Forewarn.local.xcconfig` (gitignored).

Commands are the `Makefile` targets. `make lint test build uitest` is the CI gate; run it before every commit.

## Rules

- Dependencies: GRDB.swift and Sparkle 2 only, plus Apple frameworks (plan §4). Anything else needs an ADR.
- Thresholds in plan §5 change only with owner approval.
- Energy budget (plan §6) is an acceptance criterion: periodic work through `NSBackgroundActivityScheduler`,
  no timer under 5 min while the popover is closed, never wake the Mac.
- Swift 6 with complete strict concurrency; collectors are actors.
- User-facing strings are localizable (English base + Italian).
- Each phase ends with a demo note in `docs/PROGRESS.md`; each significant decision gets an ADR.
- `LSUIElement` app: call `NSApplication.shared.activate()` before opening any window, or it opens behind others.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
