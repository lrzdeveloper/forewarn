# Forewarn — Implementation Plan (v1, macOS only)

## 1. Product in one paragraph

A menu bar app that learns how this Mac is used and warns *before* something runs out:
battery before the user's usual charging time, disk space weeks ahead, metered data before the
monthly allowance ends, and abnormal battery drain during sleep. Each alert explains the cause
and offers one action. Everything runs locally and the app measures and shows its own energy use.

Out of scope for v1: Windows/Linux, iOS, calendar integration, charge-limit control, LLM
explanations, widgets. They are in §9 (backlog).

## 2. Features and notifications (v1)

| # | Feature | Signal | Notification |
|---|---|---|---|
| F1 | Battery runway | battery %, power draw, charging state | "Charge when you can: you reach 10% around 15:40, and you usually plug in after 18:00." Actions: **OK**, **I'll have power** |
| F2 | Disk runway | available capacity for important usage | "Your disk fills up in about 3 weeks. 42 GB in Downloads haven't been opened in 6 months." Action: **Show me** |
| F3 | Sleep drain | % at sleep vs wake, power assertions | "You lost 18% while asleep (usually 2%). Docker kept the Mac awake." Action: **Show details** |
| F4 | Metered data | bytes on expensive interfaces (Personal Hotspot) | "At this pace you run out of data on the 24th." Action: **Adjust limit** |
| F5 | Battery health | cycle count, max vs design capacity | Monthly at most, only if something changed meaningfully |

Desktop Macs (no battery): F1, F3, F5 are hidden automatically; F2 and F4 remain.

## 3. Architecture

```
 Collectors ──► Store (SQLite) ──► Forecasting ──► Insights ──► Notifications
   (events)      samples/events     Engine API      rules +       rate limiter
                 downsampling       Baseline |      habits        UN categories
                                    Timestral                         │
                                                                      ▼
                                      UI (MenuBarExtra popover, Settings, Onboarding)
```

### 3.1 Collectors (actor each, protocol + fake)

| Collector | API | Trigger |
|---|---|---|
| Battery | `IOPSCopyPowerSourcesInfo`, `IOPSNotificationCreateRunLoopSource` (IOKit/ps); `AppleSmartBattery` registry entry for `InstantAmperage`, `Voltage`, `CycleCount`, `AppleRawMaxCapacity`, `DesignCapacity` | event on change + sample every 5 min on battery, 10 min on AC |
| Power state | `ProcessInfo.thermalState`, `isLowPowerModeEnabled` + notifications | event |
| Disk | `URLResourceValues.volumeAvailableCapacityForImportantUsage`, `volumeTotalCapacity` | hourly |
| Disk suggestions | directory enumeration with `totalFileAllocatedSize`, `contentAccessDate` on user-approved folders (Downloads, Xcode DerivedData, caches, Docker data) | weekly, low priority, only on AC |
| Network | `NWPathMonitor` (`isExpensive`, `isConstrained`); byte counters via `sysctl` `NET_RT_IFLIST2` / `if_data64` (64-bit; do **not** use `getifaddrs` 32-bit counters, they wrap at 4 GB) | event on path change; 5 min while on an expensive path |
| Sleep | `NSWorkspace.willSleepNotification` / `didWakeNotification`; `IOPMCopyAssertionsByProcess` before sleep | event |
| Self energy | `proc_pid_rusage(getpid(), RUSAGE_INFO_V6)` energy fields (verify field names in the SDK headers) | hourly |

### 3.2 Store

- SQLite via GRDB. Tables: `samples(metric, ts, value)`, `events(kind, ts, payload_json)`,
  `notifications(kind, ts, action_taken)`, `settings`.
- Retention: full resolution 30 days, 1-hour aggregates for 1 year, daily forever (health).
- Location: `~/Library/Application Support/Forewarn/`. Settings has **Export data (CSV)** and
  **Delete all data**.

### 3.3 Forecasting

```swift
protocol ForecastEngine: Sendable {
    func forecast(_ request: ForecastRequest) async throws -> QuantileForecast
}
// ForecastRequest: target series (regular grid, NaN = missing), past covariates,
// known-future covariates (hour-of-day, day-of-week, on-AC indicator), horizon.
// QuantileForecast: 21 levels (0.01 … 0.99) × horizon, plus median accessor.
```

- **BaselineEngine** (ships first, always available): seasonal-naive by hour-of-week blended with
  linear trend; quantiles from empirical residuals. Also the fallback whenever history is short.
- **TimestralEngine**: Timestral-5M (default) or 28M converted to Core ML, fp16, fixed context
  window and horizon per metric. Runs on CPU/ANE, loaded lazily, unloaded after use.
- **Backtest harness**: rolling-origin evaluation on recorded data; metrics MASE and weighted
  quantile loss. Per metric, the app uses Timestral **only if it beats the baseline** on this
  Mac's own history; otherwise baseline. Store the choice and re-evaluate weekly.
- Grid per metric: battery 5 min (horizon 12 h), disk 1 h (horizon 60 days, aggregated daily for
  the forecast), data 1 h (horizon to end of month).

### 3.4 Insights (deterministic, no AI)

- **Charging habits**: plug-in events → hour-of-week histogram with exponential decay (half-life
  ~3 weeks) → "expected next plug-in time" with its own quantiles.
- **Risk**: from the battery quantile forecast, probability of crossing 10% before the expected
  plug-in time. Same pattern for disk (crossing 10% free or 10 GB) and data (crossing the limit).
- **Reason builders**: produce the cause in plain words (top energy apps from the period, folders
  that grew, assertions held during sleep). Every string localized.

### 3.5 Notifications

- `UNUserNotificationCenter`, one category per feature with its actions; interruption level
  `.active` (never `.timeSensitive` in v1).
- Permission requested at the first moment a notification would actually help, not at launch.
- Rate limiter: max one per kind per day; F1 max one per discharge session; F5 max one per month.
- Feedback: if a kind is dismissed without action 3 times in a row, raise its threshold one step
  and show that in Settings ("Forewarn now warns you later about battery").
- "I'll have power" on F1 mutes F1 until the next charge and is stored as an event (useful later).

## 4. Dependencies (allowed list)

- **GRDB.swift** — SQLite.
- **Sparkle 2** — updates outside the App Store (EdDSA-signed appcast).
- Apple frameworks only otherwise: SwiftUI, Swift Charts, Observation, IOKit, Network,
  UserNotifications, ServiceManagement, CoreML, os.

## 5. Default thresholds (change only with owner approval)

| Feature | Fires when | Not before |
|---|---|---|
| F1 | P(battery < 10% before expected plug-in) ≥ 0.6 | battery ≥ 25%, on battery for ≥ 10 min, ≥ 3 days of history |
| F2 | median "disk full" date ≤ 21 days **or** free < 10% | ≥ 7 days of history |
| F3 | sleep drain/hour > 3× personal median and > 1%/h | ≥ 5 sleep sessions recorded |
| F4 | median forecast exceeds the user's monthly limit before reset day | user has set a limit |
| F5 | max capacity drops ≥ 2 points since last report, or forecast reaches 80% within 6 months | once per month |

Before enough history exists, the UI shows wide bands and says "Still learning your habits".

## 6. Energy budget (acceptance criteria)

- Activity Monitor "Energy Impact" average ≈ 0 and "Low" over 24 h of normal use.
- Own energy ≤ 0.05% of battery per day (measured by the self-energy collector and with
  `powermetrics --samplers tasks`).
- Idle wake-ups: no timer more frequent than 5 min while the popover is closed.
- All periodic work through `NSBackgroundActivityScheduler` with tolerance, `qualityOfService`
  `.utility` or `.background`. Never wake the Mac from sleep.
- Adaptive sampling: halve frequency below 20% battery; pause disk scans on battery.
- Inference: model loaded on demand, unloaded after; battery forecast at most every 15 min or on a
  significant state change.
- The popover shows "Forewarn used X% of battery today".

## 7. UI (follow the HIG pages in REFERENCES)

- **Menu bar item**: `MenuBarExtra` with `.window` style; SF Symbol template image; state
  variants (normal / attention). Optional text (e.g. "~3h") off by default. `LSUIElement = YES`
  (no Dock icon).
- **Popover** (≈ 320 pt wide): status line ("All good until ~19:30"), battery chart with p10–p90
  band (`AreaMark`) and median (`LineMark`) plus expected plug-in marker, disk runway row, data row,
  last alerts, footer with own energy use and **Settings…**, **Quit**.
- **Settings** (`Settings` scene, tabs): General (launch at login via `SMAppService.mainApp`,
  menu bar text), Notifications (per-feature toggles, current learned thresholds), Data (metered
  limit and reset day, folders approved for scanning), Privacy (what is stored, export, delete,
  network calls disclosed), About (versions, model and licenses).
- **Onboarding**: one window at first launch, three short pages (what it does, privacy, launch at
  login). Notification permission is asked later, in context.
- Accessibility: labels and values on charts (`accessibilityChartDescriptor`), full keyboard
  navigation, light/dark, Increase Contrast, Reduce Motion, Reduce Transparency.
- Localization: String Catalog, English base + Italian, plural rules, localized dates/numbers.
- App icon built with Icon Composer (macOS 26 layered icon).

## 8. Phases

Each phase ends with a short demo note in `docs/PROGRESS.md`.

### Phase 0 — Setup and spike (first)
- Repo, Apache-2.0 license for code, README skeleton, CI on GitHub Actions (macOS runner):
  build + `swift test` + SwiftLint/SwiftFormat check.
- Empty menu bar app with Settings scene, launch at login, LSUIElement.
- **Timestral spike** in `tools/convert/` (uv project):
  1. Run the reference package on CPU with recorded sample data.
  2. Convert Timestral-5M and 28M to Core ML with coremltools at fixed shapes; fp16.
  3. Export parity vectors (inputs + expected quantiles) and check Swift output within tolerance.
  4. Measure latency and energy on the Mac.
  If conversion fails, try an MLX Swift port of the inference path; if that fails too, v1 ships
  with the baseline only and Timestral stays behind a feature flag. Record the outcome as an ADR.
- **Exit**: app launches into the menu bar; spike ADR written.

### Phase 1 — Collection and storage
- All collectors of §3.1, store with retention, a hidden debug window (raw series, event log).
- Run on the owner's Mac for at least 7 days to build real fixtures (anonymized, committed under
  `Tests/Fixtures`).
- **Exit**: 24 h trace with correct data and energy within §6.

### Phase 2 — Forecasting
- `ForecastEngine`, BaselineEngine, TimestralEngine (if spike passed), backtest harness, per-metric
  engine selection.
- **Exit**: backtest report on fixtures in `docs/backtest.md`; forecasts available to Insights.

### Phase 3 — Insights and notifications
- Charging habits, risk computation, reason builders, notification categories, rate limiter,
  feedback loop, thresholds of §5.
- **Exit**: replaying fixtures produces the expected notifications and nothing else
  (snapshot tests on the notification log).

### Phase 4 — UI
- Popover, charts, settings, onboarding, localization, accessibility, icon.
- **Exit**: HIG checklist in `docs/hig-review.md` completed; screenshots in light/dark, EN/IT.

### Phase 5 — Energy and quality audit
- Instruments (Energy Log, Time Profiler), `powermetrics`, 72 h soak test on battery.
- Edge cases: desktop Mac, external displays, battery service state, clock/timezone changes,
  long sleep, disk nearly full, first run with no history.
- **Exit**: §6 met, results written in `docs/energy-report.md`.

### Phase 6 — Distribution
- Developer ID signing, hardened runtime, notarization with `notarytool`, stapled DMG.
- GitHub Releases via Actions; Sparkle appcast; own tap `homebrew-tap` with cask
  `forewarn` (`auto_updates true`).
- README (what, privacy, energy numbers, install via brew), model attribution and license notice
  for the Timestral weights (Modified MIT, includes a revenue threshold — owner to confirm wording).
- **Exit**: `brew install --cask <owner>/tap/forewarn` installs and updates correctly.

## 9. Backlog (not v1)

- Charge to 100% before a trip, asked the evening before (calendar as a question, not a forecast).
- Charge-limit control (requires privileged helper; high risk, separate ADR).
- On-device explanations with Apple Foundation Models (macOS 26), on demand only.
- App Intents / Shortcuts actions; WidgetKit widgets.
- Per-process network attribution.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Timestral does not convert to Core ML | MLX port, else baseline only (v1 still useful) |
| Timestral no better than baseline on short personal histories | per-Mac backtest decides the engine |
| Weights license (Modified MIT, revenue threshold) unclear for an open-source app used by employees of large companies | owner verifies; download weights at first run with license shown, keep code Apache-2.0 |
| IOKit keys differ across Mac models / macOS versions | defensive parsing, fixtures from several Macs, feature degrades gracefully |
| TCC prompts for Downloads scanning feel invasive | scanning is opt-in per folder in Settings |
| Notification fatigue | §3.5 limiter + feedback loop |
