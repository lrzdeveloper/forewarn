import ForewarnKit
import SwiftUI

extension ShapeStyle where Self == Color {
    /// Secondary text for Forewarn's own views. The system's secondary label falls under 4.5:1 on the popover's
    /// card fills (Xcode's accessibility audit); the primary color at 70% passes in
    /// light and dark and still reads as secondary.
    static var subdued: Color { .primary.opacity(0.7) }
}

/// The menu bar popover. Its one job: say whether something runs out before you can deal with it, and when.
/// A row opens its feature in detail in place of the overview: the overview slides out to the leading edge and the
/// page in from the trailing one, back the other way (a crossfade under Reduce Motion).
struct PopoverView: View {
    let overview: Overview
    let onRefresh: () -> Void
    @Environment(OverviewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = PopoverPage.overview
    @State private var health: Overview.HealthDetail?
    @State private var disk: Overview.DiskDetail?

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .overview:
                VStack(alignment: .leading, spacing: 12) {
                    HeaderBar(onRefresh: onRefresh)
                    if let battery = overview.battery {
                        BatterySection(battery: battery)
                    }
                    StatusRows(overview: overview, onOpen: open)
                    Footer(ownEnergyPercent: overview.ownEnergyTodayPercent)
                }
                .transition(slide(from: .leading))
            case .health:
                DetailPage(title: "Battery Health", onBack: back) {
                    if let health {
                        HealthPage(detail: health)
                    }
                }
                .transition(slide(from: .trailing))
            case .disk:
                DetailPage(title: "Disk", onBack: back) {
                    if let disk {
                        DiskPage(detail: disk)
                    }
                }
                .transition(slide(from: .trailing))
            }
        }
        .padding(16)
        .frame(width: 340)
        .clipped() // the page sliding out stays inside the popover
        // Opaque system background: over a busy desktop the window's translucent default washes out text.
        // `.background` resolves to the panel's own material inside a MenuBarExtra (translucent in dark mode).
        .background(Color(nsColor: .windowBackgroundColor))
        // Opening the popover again starts from the overview, as Control Center does.
        .onAppear { page = .overview }
    }

    /// Reads what a page shows when it opens: nothing about the pages runs periodically.
    private func open(_ next: PopoverPage) {
        if next == .health {
            health = store.healthDetail()
        }
        if next == .disk {
            disk = store.diskDetail()
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.32)) { page = next }
    }

    private func back() {
        open(.overview)
    }

    private func slide(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    let onRefresh: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spins = 0

    var body: some View {
        HStack(alignment: .center) {
            // The app icon, as macOS shows an app beside its name.
            Label {
                Text(verbatim: "Forewarn")
            } icon: {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            .font(.headline)
            Spacer()
            Button {
                onRefresh()
                spins += 1
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    // Reduce Motion: the click still refreshes, the arrow just stays still.
                    .symbolEffect(.rotate, value: reduceMotion ? 0 : spins)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("r")
            .help("Read battery and disk now")
            .accessibilityIdentifier("refresh")
        }
    }
}

// MARK: - Battery

private struct BatterySection: View {
    let battery: Overview.Battery

    /// Something to act on: the battery runs low before the usual plug-in, or the charger can't keep up (F6).
    private var risky: Bool { battery.runsLowBeforePlugIn || battery.shortfall != nil }
    private var tint: Color { risky ? .orange : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .figure(.largeTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if risky {
                    // Black warning shape on the orange tint: the yellow multicolor symbol fell under 3:1 there.
                    Label(explanation, systemImage: "exclamationmark.triangle.fill")
                        .card(fill: AnyShapeStyle(Color.orange.opacity(0.14)))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(explanation)
                        .foregroundStyle(.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Title and explanation read one after the other; combined, the audit measured the text against the
            // callout's tint instead of its own background.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("statusTitle")

            StatStrip(stats: stats)

            if battery.forecast != nil || !battery.history.isEmpty {
                BatteryChart(battery: battery, tint: battery.isOnAC && !risky ? .green : tint)
                    .card()
                    .accessibilityIdentifier("batteryChart")
            } else if !battery.isOnAC {
                LearningCard()
            }
        }
    }

    // MARK: Words

    private var percent: String {
        (battery.percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// When charging stops: at the charge limit when one is set, else at 100%. From when it was measured, so the
    /// time stays put however often the popover redraws.
    private var fullAt: Date? {
        battery.systemEstimateEnds
    }

    /// The last step the forecast reaches.
    private var forecastEnd: Date? {
        battery.forecast.map { $0.start.addingTimeInterval(Double(max($0.quantiles.horizon - 1, 0)) * $0.step) }
    }

    /// Whole hours the forecast covers.
    private var forecastHours: Int {
        battery.forecast.map { Int(Double($0.quantiles.horizon) * $0.step / 3600) } ?? 0
    }

    /// Short answer to "do I need to do anything, and by when?"
    private var title: String {
        if battery.shortfall != nil {
            return String(localized: "The charger can't keep up")
        }
        if battery.isCharging, let limit = battery.chargeLimit {
            return fullAt.map { String(localized: "Charged to \(limit)% at \(clockTime($0))") }
                ?? String(localized: "Charging to \(limit)%")
        }
        if battery.isCharging {
            return fullAt.map { String(localized: "Full at \(clockTime($0))") } ?? String(localized: "Charging")
        }
        if battery.isHeldAtLimit, let limit = battery.chargeLimit {
            return String(localized: "Held at \(limit)%")
        }
        if battery.isOnAC {
            return String(localized: "Plugged in")
        }
        guard battery.forecast != nil else {
            let left = battery.systemEstimateEnds.map(\.timeIntervalSinceNow).flatMap { $0 > 0 ? $0 : nil }.map {
                Duration.seconds($0).formatted(.units(
                    allowed: [.hours, .minutes],
                    width: .narrow,
                    maximumUnitCount: 2
                ))
            }
            return left.map { String(localized: "About \($0) left") } ?? String(localized: "Battery at \(percent)")
        }
        if let low = battery.runsLowAt {
            return risky ? String(localized: "Plug in before \(clockTime(low))")
                : String(localized: "Lasts until \(clockTime(low))")
        }
        return String(localized: "Lasts more than \(forecastHours) hours")
    }

    /// One plain sentence that says why, with the numbers it is based on.
    private var explanation: String {
        if let shortfall = battery.shortfall {
            let rate = (shortfall.percentPerHour / 100).formatted(.percent.precision(.fractionLength(0)))
            if let charger = watts(shortfall) {
                return String(
                    // swiftlint:disable:next line_length
                    localized: "The Mac uses more power than this \(charger) charger gives, so the battery drops about \(rate) an hour while plugged in. A more powerful charger, or a lighter load, fixes it."
                )
            }
            return String(
                // swiftlint:disable:next line_length
                localized: "The Mac uses more power than the charger gives, so the battery drops about \(rate) an hour while plugged in. A more powerful charger, or a lighter load, fixes it."
            )
        }
        if battery.isCharging, let limit = battery.chargeLimit {
            return String(localized: "Charging up to the \(limit)% limit set in System Settings › Battery.")
        }
        if battery.isCharging {
            return String(localized: "Charging now. Forecasts resume when you unplug.")
        }
        if battery.isHeldAtLimit, let limit = battery.chargeLimit {
            return String(
                // swiftlint:disable:next line_length
                localized: "macOS stops charging here because of the \(limit)% limit set in System Settings › Battery. Forecasts start from this level when you unplug."
            )
        }
        if battery.isOnAC {
            return String(
                // swiftlint:disable:next line_length
                localized: "On power, but not charging right now. macOS sometimes pauses at a high level to protect the battery."
            )
        }
        guard battery.forecast != nil else {
            return String(localized: "macOS's estimate, based on how you are using the Mac right now.")
        }
        // No 10% within the forecast: all it says is that the battery lasts at least that long.
        guard let low = battery.runsLowAt else {
            if let plugIn = battery.usualPlugIn, let end = forecastEnd, plugIn <= end {
                return String(
                    // swiftlint:disable:next line_length
                    localized: "You usually plug in at \(clockTime(plugIn)), and at this pace the battery stays above 10% until then."
                )
            }
            return String(
                localized: "At this pace the battery stays above 10% for at least the next \(forecastHours) hours."
            )
        }
        guard let plugIn = battery.usualPlugIn else {
            return String(
                localized: "At this pace, the battery gets to 10%, the level where Forewarn warns you, at that time."
            )
        }
        if risky || plugIn > low {
            let gap = Duration.seconds(plugIn.timeIntervalSince(low))
                .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
            return String(
                // swiftlint:disable:next line_length
                localized: "At this pace the battery is down to 10% at \(clockTime(low)). You usually plug in at \(clockTime(plugIn)), \(gap) too late."
            )
        }
        return String(localized: "You usually plug in at \(clockTime(plugIn)), well before the battery runs low.")
    }

    /// The numbers behind the headline, side by side so the two times can be compared.
    private var stats: [StatStrip.Stat] {
        let level = StatStrip.Stat(
            symbol: battery.isCharging ? "battery.100percent.bolt" : battery
                .isOnAC ? "powerplug.portrait.fill" : battery.levelSymbol,
            caption: String(localized: "Battery"), value: percent
        )
        let estimate = battery.systemEstimateMinutes.map {
            Duration.seconds($0 * 60).formatted(.units(
                allowed: [.hours, .minutes],
                width: .narrow,
                maximumUnitCount: 2
            ))
        }
        if battery.isCharging {
            let caption = battery.chargeLimit
                .map { String(localized: "Time to \($0)%") } ?? String(localized: "Time to full")
            return [level, .init(caption: caption, value: estimate ?? "–")]
        }
        if let shortfall = battery.shortfall {
            // How strong the charger is, and how long the battery lasts at this pace.
            let empty = clockTime(battery.measuredAt
                .addingTimeInterval(battery.percent / shortfall.percentPerHour * 3600))
            return [
                level,
                .init(caption: String(localized: "Charger"), value: watts(shortfall) ?? "–"),
                .init(caption: String(localized: "Empty around"), value: empty, highlighted: true),
            ]
        }
        if battery.isOnAC {
            return [level]
        }
        guard battery.forecast != nil else {
            // The headline already says how long; this says until when.
            let empty = battery.systemEstimateEnds.map(clockTime)
            return [level, .init(caption: String(localized: "Empty around"), value: empty ?? "–")]
        }
        return [
            level,
            .init(caption: String(localized: "Down to 10%"), value: battery.runsLowAt.map(clockTime) ?? "–",
                  highlighted: risky),
            .init(caption: String(localized: "You charge at"), value: battery.usualPlugIn.map(clockTime) ?? "–"),
        ]
    }
}

/// "30 W", in the user's locale.
private func watts(_ shortfall: Overview.ChargerShortfall) -> String? {
    shortfall.adapterWatts.map {
        Measurement(value: Double($0), unit: UnitPower.watts).formatted(.measurement(width: .abbreviated))
    }
}

/// "7:15" today, "7:15 tomorrow" otherwise, so a time is never ambiguous.
private func clockTime(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) {
        return time
    }
    if Calendar.current.isDateInTomorrow(date) {
        return String(localized: "\(time) tomorrow")
    }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

private func energyText(_ percent: Double) -> String {
    (percent / 100).formatted(.percent.precision(.significantDigits(1 ... 2)))
}

private struct Footer: View {
    let ownEnergyPercent: Double?
    @Environment(\.openSettings) private var openSettings
    @State private var panel: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ownEnergyPercent {
                Label {
                    Text(
                        "Forewarn used \(energyText(ownEnergyPercent)) of the battery today"
                    )
                } icon: {
                    Image(systemName: "leaf.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.subdued)
            }
            HStack(spacing: 8) {
                Button {
                    // LSUIElement apps are never active on their own; without this Settings opens behind other windows.
                    NSApplication.shared.activate()
                    openSettings()
                    // Then close the panel so only Settings stays open (`dismiss` does not reach a MenuBarExtra panel).
                    panel?.close()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(",")
                .help("Open Forewarn settings")
                .accessibilityIdentifier("openSettings")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit Forewarn", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q")
                .help("Quit Forewarn")
            }
            .controlSize(.large)
        }
        .background(HostingWindowReader(window: $panel).accessibilityHidden(true))
    }
}
