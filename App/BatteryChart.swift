import Charts
import ForewarnKit
import SwiftUI

/// Measured battery level, then the forecast: likely range (p10–p90) and expected level (median),
/// up to an hour past the moment that matters. A fixed readout line above the plot shows "now",
/// or the value under the pointer, so nothing floats over the marks.
struct BatteryChart: View {
    let battery: Overview.Battery
    let tint: Color
    @State private var selection: Date?

    private var points: [Overview.Forecast.Point] {
        let all = battery.forecast?.points ?? []
        let moments = [battery.runsLowAt, battery.usualPlugIn].compactMap(\.self)
        guard let last = moments.max() else { return all }
        return all.filter { $0.date <= last.addingTimeInterval(3600) }
    }

    /// Every three hours, every hour when the chart spans less than six: a short history still gets its times.
    private var hourStep: Int {
        let dates = battery.history.map(\.date) + points.map(\.date)
        guard let first = dates.min(), let last = dates.max() else { return 3 }
        return last.timeIntervalSince(first) < 6 * 3600 ? 1 : 3
    }

    private var now: Date { battery.forecast?.start ?? battery.history.last?.date ?? .now }

    /// The times the forecast covers, when there is one.
    private var forecastSpan: ClosedRange<Date>? {
        guard let first = points.first?.date, let last = points.last?.date else { return nil }
        return first ... last
    }

    /// The usual plug-in when the forecast reaches it: only then is there a level to mark it at. Later than that,
    /// the legend still gives its time.
    private var plugInWithinForecast: Date? {
        battery.usualPlugIn.flatMap { forecastSpan?.contains($0) == true ? $0 : nil }
    }

    /// What the chart spans: when it changes (a forecast gone on plugging in, a new one), a time picked before may
    /// lie outside it.
    private var coverage: [Date?] {
        [battery.history.first?.date, battery.history.last?.date, points.first?.date, points.last?.date]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            chart
                .frame(height: 140)
                .onChange(of: coverage) { selection = nil }
            if !points.isEmpty {
                legend
            }
        }
    }

    // MARK: Readout

    private var readout: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(selection.map { $0.formatted(date: .omitted, time: .shortened) } ?? String(localized: "Now"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(readoutValue(at: selection ?? now))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.subdued)
        }
        .accessibilityElement(children: .combine)
    }

    /// Only what the chart has for that time: never the current level under a time it does not cover.
    private func readoutValue(at date: Date) -> String {
        if date > now {
            guard forecastSpan?.contains(date) == true, let p = nearest(points, to: date, \.date) else { return "–" }
            return String(localized: "\(pct(p.median)) expected · likely \(pct(p.low))–\(pct(p.high))")
        }
        if date < now {
            guard let first = battery.history.first, date >= first.date,
                  let s = nearest(battery.history, to: date, \.date) else { return "–" }
            return String(localized: "\(pct(s.value)) measured")
        }
        return pct(battery.percent)
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(battery.history, id: \.date) { sample in
                LineMark(
                    x: .value("Time", sample.date), y: .value("Battery level", sample.value),
                    series: .value("Series", "Measured")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Likely low", point.low),
                    yEnd: .value("Likely high", point.high)
                )
                .foregroundStyle(tint.opacity(0.18))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", point.date), y: .value("Expected level", point.median),
                    series: .value("Series", "Expected")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                .interpolationMethod(.monotone)
            }

            RuleMark(y: .value("Low battery", Overview.lowBatteryPercent))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            if let plugIn = plugInWithinForecast, let p = nearest(points, to: plugIn, \.date) {
                RuleMark(x: .value("Usual plug-in", plugIn))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                PointMark(x: .value("Usual plug-in", plugIn), y: .value("Expected level", p.median))
                    .symbol { MarkerSymbol(systemImage: "powerplug.portrait.fill", fill: Color.primary) }
            }
            if let low = battery.runsLowAt, low <= points.last?.date ?? .distantPast {
                PointMark(x: .value("Reaches 10%", low), y: .value("Battery level", Overview.lowBatteryPercent))
                    .symbol { MarkerSymbol(systemImage: nil, fill: tint) }
            }
            PointMark(x: .value("Now", now), y: .value("Battery level", battery.percent))
                .symbol { MarkerSymbol(systemImage: nil, fill: tint) }

            if let selection {
                RuleMark(x: .value("Selected time", selection))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
        }
        .chartYScale(domain: 0 ... 100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel { Text(pct(Double(value.as(Int.self) ?? 0))) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hourStep)) {
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartXSelection(value: $selection)
        // One element: Swift Charts' per-hour children have no role; the descriptor carries the data (Audio Graphs).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery level, measured and expected"))
        .accessibilityAddTraits(.isImage)
        .accessibilityChartDescriptor(self)
    }

    // MARK: Legend

    /// One row when it fits; longer languages (Italian) wrap to two rows instead of truncating.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    expectedItem
                    rangeItem
                }
                plugInItem
            }
        }
        .font(.caption)
        .foregroundStyle(.subdued)
        .accessibilityHidden(true) // the chart descriptor carries the same information
    }

    @ViewBuilder private var legendItems: some View {
        expectedItem
        rangeItem
        plugInItem
    }

    private var expectedItem: some View {
        LegendItem(label: "Expected") {
            Capsule().fill(tint).frame(width: 6, height: 2)
            Capsule().fill(tint).frame(width: 6, height: 2)
        }
    }

    private var rangeItem: some View {
        LegendItem(label: "Likely range") {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.25)).frame(width: 14, height: 9)
        }
    }

    @ViewBuilder private var plugInItem: some View {
        if let plugIn = battery.usualPlugIn {
            LegendItem(label: "Usual plug-in \(plugIn.formatted(date: .omitted, time: .shortened))") {
                Image(systemName: "powerplug.portrait.fill").font(.caption2)
            }
        }
    }

    // MARK: Helpers

    private func pct(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private func nearest<T>(_ items: [T], to date: Date, _ key: KeyPath<T, Date>) -> T? {
        items.min { abs($0[keyPath: key].timeIntervalSince(date)) < abs($1[keyPath: key].timeIntervalSince(date)) }
    }
}

/// A filled dot with a ring in the background colour, optionally holding a symbol.
private struct MarkerSymbol: View {
    let systemImage: String?
    let fill: Color

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.background)
            }
        }
        .frame(width: systemImage == nil ? 9 : 16, height: systemImage == nil ? 9 : 16)
        .overlay(Circle().stroke(.background, lineWidth: 2))
    }
}

struct LegendItem<Swatch: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let swatch: Swatch

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) { swatch }
            Text(label).lineLimit(1)
        }
    }
}

extension BatteryChart: @MainActor AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = battery.history.map(\.date) + points.map(\.date)
        let start = (dates.min() ?? .now).timeIntervalSince1970, end = (dates.max() ?? .now).timeIntervalSince1970
        let x = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"),
            range: start ... max(end, start + 1),
            gridlinePositions: []
        ) {
            Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(
            title: String(localized: "Battery level"),
            range: 0 ... 100,
            gridlinePositions: [10]
        ) {
            "\(Int($0))%"
        }
        let measured = AXDataSeriesDescriptor(
            name: String(localized: "Measured"), isContinuous: true,
            dataPoints: battery.history.map { .init(x: $0.date.timeIntervalSince1970, y: $0.value) }
        )
        let expected = AXDataSeriesDescriptor(
            name: String(localized: "Expected"), isContinuous: true,
            dataPoints: points.map { .init(x: $0.date.timeIntervalSince1970, y: $0.median) }
        )
        // The band the chart shades, as its two edges: the likely range is half of what the forecast says.
        let low = AXDataSeriesDescriptor(
            name: String(localized: "Likely low"), isContinuous: true,
            dataPoints: points.map { .init(x: $0.date.timeIntervalSince1970, y: $0.low) }
        )
        let high = AXDataSeriesDescriptor(
            name: String(localized: "Likely high"), isContinuous: true,
            dataPoints: points.map { .init(x: $0.date.timeIntervalSince1970, y: $0.high) }
        )
        // The reading now and the usual plug-in, which the chart marks and the last sample need not equal.
        let now = pct(battery.percent)
        let summary = battery.usualPlugIn.map { $0.formatted(date: .omitted, time: .shortened) }.map {
            String(localized: "Now \(now). Usual plug-in \($0).")
        } ?? String(localized: "Now \(now).")
        return AXChartDescriptor(
            title: String(localized: "Battery level, measured and expected"),
            summary: summary, xAxis: x, yAxis: y, additionalAxes: [],
            series: [measured, expected] + (points.isEmpty ? [] : [low, high])
        )
    }
}
