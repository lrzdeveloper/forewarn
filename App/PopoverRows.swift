import ForewarnKit
import SwiftUI

// MARK: - Rows

struct StatusRows: View {
    let overview: Overview
    /// Opens a feature's page in place of the overview.
    let onOpen: (PopoverPage) -> Void
    /// Mobile data is opt-in (Settings › Data): no row until the user sets a limit.
    @AppStorage(SettingsKey.meteredLimitEnabled) private var trackData = false

    var body: some View {
        // Battery health and disk first, alike: a ring for the figure, a line on where it is heading, a page behind
        // each.
        VStack(spacing: 0) {
            if let health = overview.health {
                Button { onOpen(.health) } label: {
                    StatusRow(
                        symbol: "bolt.heart.fill", title: "Battery health",
                        value: (health.maximumCapacity / 100).formatted(.percent.precision(.fractionLength(0))),
                        detail: healthDetail(health), progress: health.maximumCapacity / 100,
                        attention: health.needsAttention,
                        opensPage: true
                    )
                }
                .buttonStyle(RowButtonStyle())
                .help("Show battery health details")
                .accessibilityIdentifier("batteryHealth")
            }
            if let disk = overview.disk {
                Button { onOpen(.disk) } label: {
                    StatusRow(
                        symbol: "internaldrive.fill", title: "Disk",
                        value: String(localized: "\(bytes(disk.freeBytes)) free"),
                        detail: disk.fullDate
                            .map { String(localized: "Full \($0.formatted(.relative(presentation: .named))).") }
                            ?? String(localized: "Learning how fast it fills."),
                        progress: disk.usedFraction, attention: disk.fillsSoon, opensPage: true
                    )
                }
                .buttonStyle(RowButtonStyle())
                .help("Show disk details")
                .accessibilityIdentifier("disk")
            }
            if trackData, let data = overview.meteredData {
                StatusRow(
                    symbol: "cellularbars", title: "Mobile data",
                    value: String(localized: "\(bytes(data.usedBytes)) of \(bytes(data.limitBytes))"),
                    detail: data.runsOutAt.flatMap { data.runsOutBeforeReset ? $0 : nil }
                        .map { String(localized: "Runs out \($0.formatted(.relative(presentation: .named))).") }
                        ?? String(localized: "Resets on \(data.resetDate.formatted(.dateTime.day().month()))."),

                    progress: data.usedFraction, attention: data.runsOutBeforeReset
                )
            }
            if let sleep = overview.sleepDrain {
                StatusRow(
                    symbol: "moon.zzz.fill", title: "Last sleep",
                    value: "−" + (sleep.lastSleepDropPercent / 100).formatted(.percent.precision(.fractionLength(0))),
                    detail: sleep.isAbnormal
                        ? String(localized: "Usually \(Int(sleep.usualDropPercent.rounded()))%.")
                        + (sleep.cause.map { " " + String(localized: "\($0) kept the Mac awake.") } ?? "")
                        : String(localized: "Normal for this Mac."),
                    progress: nil, attention: sleep.isAbnormal
                )
            }
        }
        .padding(.vertical, 4)
        .card(padding: 0) // the rows carry their own padding, so their highlight can fill the card's width
    }

    /// One line on where it is heading, like the disk row's; condition and cycles are on the page. The cycles stand
    /// in until there is an outlook, the condition when macOS recommends service.
    private func healthDetail(_ health: Overview.BatteryHealth) -> String {
        if health.serviceRecommended {
            return String(localized: "macOS recommends service.")
        }
        // Already there: no forecast to give, and "80% around" this month would read as still to come.
        if health.maximumCapacity <= 80 {
            return String(localized: "Below 80%, the usual service threshold.")
        }
        if let at = health.reaches80At, at > .now, at.timeIntervalSinceNow < 2 * 365 * 86400 {
            let when = at.formatted(.dateTime.month(.wide).year())
            return String(localized: "At this pace, 80% around \(when).")
        }
        if let year = health.inOneYear {
            let percent = (year / 100).formatted(.percent.precision(.fractionLength(0)))
            return String(localized: "In a year, about \(percent).")
        }
        return health.designCycleCount.map {
            String(localized: "Normal. \(health.cycleCount) of \($0.formatted()) cycles.")
        } ?? String(localized: "Normal. \(health.cycleCount) cycles.")
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

/// One status line in the style of the system's menu bar extras: a symbol in a filled circle, then text.
/// The circle turns orange when the row needs attention; the detail text always says why.
private struct StatusRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let detail: String
    let progress: Double?
    let attention: Bool
    /// Clicking the row opens its page: a chevron says so, as in Control Center.
    var opensPage = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(value).monospacedDigit().foregroundStyle(.subdued)
                    if opensPage {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.subdued)
                            .accessibilityHidden(true)
                    }
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.subdued) // attention is the orange icon; orange text fails contrast
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// The symbol in a filled circle; with a quantity, in a ring filled up to it instead, as Apple's Batteries
    /// widget draws a device's charge.
    @ViewBuilder private var icon: some View {
        let glyph = Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        if let progress {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0.02), 1))
                    // 3:1 against the card for indicators; orange is the attention state, with the text saying why.
                    .stroke(attention ? Color.orange : Color.primary.opacity(0.75),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                glyph.foregroundStyle(attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            }
            .padding(1.5)
        } else {
            glyph
                .foregroundStyle(attention ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background(attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary), in: Circle())
        }
    }
}

/// A status row that opens something: the row itself highlights under the pointer and while pressed.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                // Inset the highlight, not the row: its text stays aligned with the rows that are not buttons.
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))
                        .padding(.horizontal, 4)
                )
                .onHover { hovering = $0 }
        }
    }
}

/// The numbers behind the headline in one light strip: caption above, value below.
struct StatStrip: View {
    struct Stat: Hashable {
        var symbol: String?
        var caption: String
        var value: String
        var highlighted = false
    }

    let stats: [Stat]

    /// Side by side when the values fit (they are never shortened: a cut time is a wrong time); one line each,
    /// caption leading and value trailing, when a language's words are too long for that (German).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(stats, id: \.self) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        caption(stat)
                        value(stat)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            VStack(spacing: 8) {
                ForEach(stats, id: \.self) { stat in
                    HStack(alignment: .firstTextBaseline) {
                        caption(stat)
                        Spacer(minLength: 8)
                        value(stat)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .card()
        .accessibilityIdentifier("powerTiles")
    }

    private func caption(_ stat: Stat) -> some View {
        Text(stat.caption)
            .font(.subheadline)
            .foregroundStyle(.subdued)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func value(_ stat: Stat) -> some View {
        HStack(spacing: 5) {
            // The warning shape, not the color, says "this one": the yellow multicolor symbol and orange text both
            // fall under 3:1 on the card.
            if stat.highlighted {
                Image(systemName: "exclamationmark.triangle.fill")
            } else if let symbol = stat.symbol {
                // Monochrome: the hierarchical outline fell under 3:1 on the card.
                Image(systemName: symbol)
            }
            Text(stat.value)
                .figure(.title3)
                .fixedSize()
        }
    }
}

/// Where the chart will be. Not the hourglass: that is Forewarn's mark, and means nothing else.
struct LearningCard: View {
    var body: some View {
        Module(title: "Still learning your habits", symbol: "chart.line.downtrend.xyaxis") {
            Text("The chart appears after about 3 days on battery.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
