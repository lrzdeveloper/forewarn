# Changelog

Every release of Forewarn. Versions follow [Semantic Versioning](https://semver.org).

## 1.1.0 (2026-10-28)

### Battery
- The forecast no longer learns a top-up on power as a gain: its likely range is narrower and its line follows the
  drain.
- A forecast made just before you plug in no longer comes back once you are on power, and forecasts run at most every
  15 minutes, whatever happened to the last one.
- When the forecast doesn't reach 10%, the popover says how long the battery lasts at least, instead of naming a time.
- The menu bar shows macOS's time left once the forecast's 10% has passed, and "Full at" and "Empty around" stay put
  while you browse the popover.
- Your usual plug-in time is learned by the clock, so a daylight-saving change no longer shifts it by an hour.
- The charger warning needs readings minutes apart: a quick sleep or relaunch no longer sets it off.

### Battery Health and Disk pages
- Battery Health: an outlook from measured Maximum Capacity even when the Mac stays plugged in, never below 0%; a
  battery already under 80% says so instead of forecasting it.
- Disk: the forecast and the page agree on when there is a week of history, the full date follows the trend line rather
  than the last reading, and a full disk still gets a chart.
- Detail pages fit the display the popover is on, also on a second display.

### Warnings
- A warning macOS fails to show is tried again later, instead of counting as sent.
- Two checks at the same moment can no longer send the same warning twice.
- Sleep drain compares only nights spent on battery: a night plugged in is no longer taken as the usual one.
- Mobile data: an allowance already used up is flagged from the first day of the period.
- On a Mac without a battery, the menu bar still shows when the disk or mobile data need attention.

### Measurements
- Nothing measured is lost when a write fails: mobile data, Forewarn's own energy, plug-ins and unplugs are counted
  again on the next try, and the first-launch import starts over if it was interrupted.
- Mobile data is counted on the network the expensive connection actually uses, and kept in full for a whole billing
  period.
- Hourly and daily summaries weigh every reading equally, and a late reading joins its hour instead of doubling it.
- Folder sizes are rescanned folder by folder, and the apps keeping the Mac awake are named more reliably.

### Settings
- Open at login follows System Settings, and says when it waits for your approval there, with a button to open it.
- Export runs in the background, so Settings stays responsive; Delete also clears the forecast on screen.
- A language restart that fails keeps Forewarn open and says so. Return in the language list picks the top row.

### Accessibility
- VoiceOver and Audio Graphs read the likely range of the battery and Battery Health forecasts, the battery level
  now and your usual plug-in time.

## 1.0.0 (2026-10-28)

### Install
- The first release: signed by Morfex S.R.L., notarized by Apple, installed and updated with Homebrew.

### Settings, look and feel
- Settings › About: version and build, who makes Forewarn, links to the source, to report an issue and to privacy,
  these release notes, and the licenses of Forewarn and the work it builds on.
- One visual language: the same card and the same two sizes of rounded figures in the popover, its pages and the
  welcome window; the app icon wherever Forewarn names itself, the popover's header included.
- Settings grows and shrinks around its middle when you change pane.

### Charger
- When the Mac is plugged in but the battery still drains, the menu bar shows a warning and the popover says the
  charger can't keep up, with its watts, the drain per hour and when the battery would be empty.
- Battery Health: an info button beside the cycles explains Apple's design target and where the outlook comes from.

### Battery Health and Disk pages
- The battery health and disk rows open a page inside the popover; Esc or the back button returns.
- Battery Health: Maximum Capacity as System Settings shows it, where it is heading with a likely range, cycles,
  and what slows wear.
- Disk: free space over the last 30 days and the line to full, the folders Forewarn adds up each week, and
  Manage Storage… for System Settings.
- Battery health and disk rows alike: the figure in a ring around the row's symbol.

### Languages and accessibility
- 27 languages: English and 26 European languages, machine-translated and waiting for native review.
- A language of its own for Forewarn, on the first welcome page and in Settings › General.
- Battery health: Maximum Capacity, condition, cycles, and where it is heading.
- Accessibility audit on every screen, keyboard path, Reduce Motion, and an opaque popover in dark mode.

### Warnings
- Learns when you usually plug in, and the chance of reaching 10% before then.
- Warnings for battery, disk, sleep drain, mobile data and battery health, at most one of each kind a day.
- After three warnings of a kind closed in a row, Forewarn warns later about it, and says so in Settings.
- Each notification says why and offers one action.

### Forecasts
- A seasonal baseline forecast with a likely range from its own past errors.
- An optional on-device model (Timestral, Core ML) used only when it beats the baseline on this Mac's history.
- Disk full date and mobile data pace.

### Measurements
- Battery, power, disk, sleep and expensive-network totals, stored only on this Mac.
- The battery history macOS already keeps is imported on first launch.
- Respects the charge limit set in System Settings › Battery.
- Export everything as CSV, or delete it, in Settings › Privacy.

### First version
- Menu bar app with a forecast popover, Settings and a welcome window on first launch.
- Open at login.
