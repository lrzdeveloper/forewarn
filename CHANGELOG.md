# Changelog

Every release of Forewarn. Versions follow [Semantic Versioning](https://semver.org).

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
