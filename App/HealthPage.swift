import Charts
import ForewarnKit
import SwiftUI

/// Battery Health, opened from the popover's health row: Maximum Capacity as System Settings shows it, where it is
/// heading and how sure that is, cycles, and what slows wear.
struct HealthPage: View {
    let detail: Overview.HealthDetail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var explains = false
    private var health: Overview.BatteryHealth { detail.health }
    private var tint: Color { health.needsAttention ? .orange : .green }

    var body: some View {
        capacity
        if let outlook = detail.outlook {
            StatStrip(stats: stats(outlook))
        }
        cycles
        whatHelps
    }

    // MARK: Maximum Capacity

    private var capacity: some View {
        Module(title: "Maximum Capacity", symbol: "bolt.heart.fill") {
            HStack(alignment: .firstTextBaseline) {
                ModuleValue(text: pct(health.maximumCapacity))
                Spacer()
                Label(
                    health.serviceRecommended ? LocalizedStringKey("macOS recommends service.") : "Normal",
                    systemImage: health.serviceRecommended ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("healthHeadline")
            if detail.outlook != nil {
                HealthChart(detail: detail, tint: tint, summary: chartTitle)
                    .frame(height: 140)
                    .accessibilityIdentifier("healthChart")
                legend
            }
            // The chart's message in words, so nobody has to read the lines to get it (HIG, Charting data).
            Text(chartTitle)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chartTitle: String {
        guard let outlook = detail.outlook else {
            return String(localized: "The outlook appears after about 3 days of use.")
        }
        if health.maximumCapacity <= 80 {
            return String(localized: "Below 80%, the usual service threshold.")
        }
        guard let at = outlook.reaches80At else {
            return String(localized: "Expected to stay above 80% for more than ten years.")
        }
        return String(localized: "Expected to reach 80% around \(at.formatted(.dateTime.month(.wide).year())).")
    }

    /// One row when it fits; longer languages (German) put the range on a second row instead of truncating.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                lines
                range
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) { lines }
                range
            }
        }
        .font(.caption)
        .foregroundStyle(.subdued)
        .accessibilityHidden(true) // the chart descriptor carries the same information
    }

    @ViewBuilder private var lines: some View {
        if !detail.history.isEmpty {
            LegendItem(label: "Measured") {
                Capsule().fill(tint).frame(width: 14, height: 2.5)
            }
        }
        LegendItem(label: "Expected") {
            Capsule().fill(tint).frame(width: 6, height: 2)
            Capsule().fill(tint).frame(width: 6, height: 2)
        }
    }

    private var range: some View {
        LegendItem(label: "Likely range") {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.25)).frame(width: 14, height: 9)
        }
    }

    // MARK: Numbers

    private func stats(_ outlook: HealthOutlook) -> [StatStrip.Stat] {
        let at80: String = if health.maximumCapacity <= 80 {
            String(localized: "Now")
        } else if let at = outlook.reaches80At {
            at.formatted(.dateTime.month(.abbreviated).year())
        } else {
            String(localized: "After \(outlook.start.addingTimeInterval(3650 * 86400).formatted(.dateTime.year()))")
        }
        return [
            .init(caption: String(localized: "In 1 year"), value: pct(outlook.inOneYear)),
            .init(caption: String(localized: "In 3 years"), value: pct(outlook.inThreeYears)),
            .init(caption: String(localized: "80% around"), value: at80),
        ]
    }

    // MARK: Cycles

    private var cycles: some View {
        Module(title: "Cycles", symbol: "arrow.triangle.2.circlepath") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(health.designCycleCount.map { String(localized: "\(health.cycleCount) of \($0.formatted())") }
                    ?? health.cycleCount.formatted())
                    .figure(.title3)
                if !explanation.isEmpty {
                    // What the target means and where the outlook comes from, on request: the page stays short.
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy) { explains.toggle() }
                    } label: {
                        Image(systemName: explains ? "info.circle.fill" : "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("What these numbers mean")
                    .accessibilityLabel("What these numbers mean")
                    .accessibilityIdentifier("cyclesInfo")
                }
            }
            if let design = health.designCycleCount {
                // No visible label (macOS centres it above the bar) and no VoiceOver element: the text says it.
                Gauge(value: Double(min(health.cycleCount, design)), in: 0 ... Double(design)) {}
                    .gaugeStyle(.linearCapacity)
                    .tint(Color.primary.opacity(0.75)) // 3:1 against the card for indicators
                    .accessibilityHidden(true)
            }
            if let cyclesPerDay = detail.outlook?.cyclesPerDay {
                let perDay = cyclesPerDay.formatted(.number.precision(.fractionLength(1)))
                let perYear = Int((cyclesPerDay * 365).rounded()).formatted()
                Text("About \(perDay) cycles a day, \(perYear) a year.")
                    .font(.subheadline)
                    .foregroundStyle(.subdued)
            }
            if explains {
                Text(explanation.joined(separator: " "))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("cyclesExplanation")
            }
        }
    }

    /// The design cycle count as Apple's target, then where the outlook comes from.
    private var explanation: [String] {
        var lines: [String] = []
        if let design = health.designCycleCount {
            lines.append(String(
                // swiftlint:disable:next line_length
                localized: "Apple designs this battery to keep 80% of its original capacity at \(design.formatted()) cycles."
            ))
        }
        if let outlook = detail.outlook {
            lines.append(basis(outlook))
        }
        return lines
    }

    // MARK: What helps

    private var whatHelps: some View {
        Module(title: "What helps", symbol: "leaf.fill") {
            tip(
                detail.chargeLimit.map {
                    String(localized: "Your \($0)% charge limit slows wear: the battery spends less time full.")
                } ?? String(
                    // swiftlint:disable:next line_length
                    localized: "Long hours at 100% wear the battery. If the Mac stays plugged in most of the day, a charge limit in System Settings › Battery slows that."
                ),
                symbol: detail.chargeLimit == nil ? "battery.100percent" : "battery.75percent"
            )
            tip(
                String(
                    // swiftlint:disable:next line_length
                    localized: "Heat wears a battery fastest. Keep the Mac out of the sun and off soft surfaces when it works hard."
                ),
                symbol: "thermometer.sun.fill"
            )
        }
    }

    /// Symbols in one column, so both texts start at the same edge.
    /// The symbol is decoration, kept out of the text's element: the audit measured its thin strokes as text.
    private func tip(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }

    /// Where the estimate comes from, in one sentence that follows the basis.
    private func basis(_ outlook: HealthOutlook) -> String {
        switch outlook.basis {
        case .cycles:
            return String(
                localized: "The outlook comes from your cycles a day, weighed against this battery's own wear so far."
            )
        case let .measured(days):
            let since = outlook.start.addingTimeInterval(Double(-days) * 86400)
                .formatted(.dateTime.month(.wide).year())
            return String(
                localized: "Estimated from the trend in this Mac's own Maximum Capacity readings since \(since)."
            )
        }
    }
}

private func pct(_ value: Double) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(0)))
}

// MARK: - Chart

/// Measured Maximum Capacity, then the expected straight line with its band, against the 80% service threshold.
/// The Y axis starts near the data, not at zero: the years that matter happen between 100% and 80% (HIG, Charts).
private struct HealthChart: View {
    let detail: Overview.HealthDetail
    let tint: Color
    let summary: String
    private let now: Date
    private let path: [Overview.Forecast.Point]
    private let floor: Double

    init(detail: Overview.HealthDetail, tint: Color, summary: String) {
        self.detail = detail
        self.tint = tint
        self.summary = summary
        let outlook = detail.outlook
        now = outlook?.start ?? detail.history.last?.date ?? .now
        let year = 365 * 86400.0
        // Past 80% and the three-year mark, half a year more for air, never beyond ten years.
        let at80 = outlook?.reaches80At ?? now.addingTimeInterval(5 * year)
        let end = min(max(at80, now.addingTimeInterval(3 * year)) + year / 2, now.addingTimeInterval(10 * year))
        path = outlook?.path(to: end) ?? []
        let lowest = (path.map(\.low) + detail.history.map(\.value) + [80]).min() ?? 80
        floor = max(((lowest - 2) / 5).rounded(.down) * 5, 50)
    }

    private var start: Date { detail.history.first?.date ?? now }
    private var end: Date { path.last?.date ?? now.addingTimeInterval(86400) }
    /// Every year while they fit the popover's width, every other year beyond six.
    private var years: Int { end.timeIntervalSince(start) > 6.5 * 365 * 86400 ? 2 : 1 }

    var body: some View {
        Chart {
            ForEach(path) { point in
                // The system's soft vertical gradient, as Health and Weather fill their ranges.
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Likely low", max(point.low, floor)),
                    yEnd: .value("Likely high", point.high)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [tint.opacity(0.32), tint.opacity(0.1)], startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Time", point.date), y: .value("Maximum Capacity", point.median),
                    series: .value("Series", "Expected")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            }
            ForEach(detail.history, id: \.date) { sample in
                LineMark(
                    x: .value("Time", sample.date), y: .value("Maximum Capacity", sample.value),
                    series: .value("Series", "Measured")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Maximum Capacity", 80))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("80%, the usual service threshold")
                        .font(.caption)
                        .foregroundStyle(.subdued)
                }
            PointMark(x: .value("Now", now), y: .value("Maximum Capacity", detail.health.maximumCapacity))
                .symbol {
                    Circle().fill(tint)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
        }
        .chartXScale(domain: start ... end)
        .chartYScale(domain: floor ... 100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .stride(by: 100 - floor > 25 ? 10 : 5)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel { Text(pct(value.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .year, count: years)) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel(format: .dateTime.year())
            }
        }
        // One element with an Audio Graph, as the battery chart (Swift Charts' children have no role).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Maximum Capacity, measured and expected"))
        .accessibilityValue(Text(summary))
        .accessibilityAddTraits(.isImage)
        .accessibilityChartDescriptor(self)
    }
}

extension HealthChart: @MainActor AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"),
            range: start.timeIntervalSince1970 ... end.timeIntervalSince1970,
            gridlinePositions: []
        ) {
            Date(timeIntervalSince1970: $0).formatted(.dateTime.month(.abbreviated).year())
        }
        let y = AXNumericDataAxisDescriptor(
            title: String(localized: "Maximum Capacity"),
            range: floor ... 100,
            gridlinePositions: [80]
        ) {
            pct($0)
        }
        let measured = AXDataSeriesDescriptor(
            name: String(localized: "Measured"), isContinuous: true,
            dataPoints: detail.history.map { .init(x: $0.date.timeIntervalSince1970, y: $0.value) }
        )
        let expected = AXDataSeriesDescriptor(
            name: String(localized: "Expected"), isContinuous: true,
            dataPoints: path.map { .init(x: $0.date.timeIntervalSince1970, y: $0.median) }
        )
        // The shaded band, as its two edges.
        let low = AXDataSeriesDescriptor(
            name: String(localized: "Likely low"), isContinuous: true,
            dataPoints: path.map { .init(x: $0.date.timeIntervalSince1970, y: $0.low) }
        )
        let high = AXDataSeriesDescriptor(
            name: String(localized: "Likely high"), isContinuous: true,
            dataPoints: path.map { .init(x: $0.date.timeIntervalSince1970, y: $0.high) }
        )
        return AXChartDescriptor(
            title: String(localized: "Maximum Capacity, measured and expected"),
            summary: summary, xAxis: x, yAxis: y, additionalAxes: [],
            series: [measured, expected] + (path.isEmpty ? [] : [low, high])
        )
    }
}
