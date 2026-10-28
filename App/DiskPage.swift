import AppKit
import Charts
import ForewarnKit
import SwiftUI

/// The disk in detail, opened from the popover's disk row: free space, how it went over the last 30 days and where
/// the line is heading, and the folders Forewarn adds up each week. Cleaning up is System Settings' job: a link.
struct DiskPage: View {
    let detail: Overview.DiskDetail
    private var disk: Overview.Disk { detail.disk }
    private var tint: Color { disk.fillsSoon ? .orange : .green }

    var body: some View {
        Module(title: "Free space", symbol: "internaldrive.fill") {
            VStack(alignment: .leading, spacing: 2) {
                ModuleValue(text: String(localized: "\(bytes(disk.freeBytes)) free"))
                Text("\(bytes(disk.totalBytes - disk.freeBytes)) used of \(bytes(disk.totalBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.subdued)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("diskHeadline")
            Gauge(value: disk.usedFraction) {}
                .gaugeStyle(.linearCapacity)
                .tint(disk.fillsSoon ? Color.orange : Color.primary.opacity(0.75)) // 3:1 against the card
                .accessibilityHidden(true) // the text above says it
            if detail.history.count >= 2 {
                DiskChart(detail: detail, tint: tint, summary: summary)
                    .frame(height: 110)
                    .accessibilityIdentifier("diskChart")
            }
            Text(summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        Module(title: "Folders Forewarn checks", symbol: "folder.fill") {
            if detail.folders.isEmpty {
                Text("Their sizes appear after the first weekly check, made while the Mac is on power.")
                    .font(.subheadline)
                    .foregroundStyle(.subdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(detail.folders) { folder in
                FolderRow(folder: folder)
            }
        }
        Button {
            // System Settings › General › Storage: recommendations and the real cleanup tools.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
        } label: {
            Label("Manage Storage…", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .help("Open System Settings › General › Storage")
    }

    /// What the line says, in words.
    private var summary: String {
        if let full = disk.fullDate {
            return String(localized: "Full \(full.formatted(.relative(presentation: .named))).")
        }
        if detail.history.count < 7 {
            return String(localized: "Learning how fast it fills.")
        }
        return String(localized: "Not filling up at the pace of the last 30 days.")
    }
}

private func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .file))
}

/// A plain 0 at the bottom of the axis: the formatter spells it out ("Zero kB") or picks bytes ("0 Byte").
private func axisBytes(_ value: Double) -> String {
    value < 1 ? 0.formatted() : bytes(Int64(value))
}

/// A scanned folder with Finder's own icon, its size and last week's change; the button shows it in Finder.
private struct FolderRow: View {
    let folder: Overview.DiskDetail.Folder

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(FileManager.default.displayName(atPath: folder.path))
                    .lineLimit(1)
                if let growth = folder.growth, growth != 0 {
                    Text("\((growth > 0 ? "+" : "−") + bytes(abs(growth))) this week")
                        .font(.caption)
                        .foregroundStyle(.subdued)
                }
            }
            Spacer(minLength: 8)
            Text(bytes(folder.bytes))
                .monospacedDigit()
                .foregroundStyle(.subdued)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: folder.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
    }
}

/// Free space at the end of each of the last 30 days, then the straight line to full (dashed) for up to 30 days.
/// Zero is the bottom: a full disk is the point of the chart (HIG, Charts: a meaningful fixed lower bound).
private struct DiskChart: View {
    let detail: Overview.DiskDetail
    let tint: Color
    let summary: String
    private let projection: [Overview.Sample]

    init(detail: Overview.DiskDetail, tint: Color, summary: String) {
        self.detail = detail
        self.tint = tint
        self.summary = summary
        if let last = detail.history.last, let full = detail.disk.fullDate, full > last.date {
            let end = min(full, last.date.addingTimeInterval(30 * 86400))
            let left = last.value * (1 - end.timeIntervalSince(last.date) / full.timeIntervalSince(last.date))
            projection = [last, Overview.Sample(date: end, value: left)]
        } else {
            projection = []
        }
    }

    private var top: Double { ((detail.history + projection).map(\.value).max() ?? 1) * 1.15 }

    var body: some View {
        Chart {
            ForEach(detail.history, id: \.date) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Free", sample.value))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [tint.opacity(0.3), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", sample.date), y: .value("Free", sample.value),
                    series: .value("Series", "Measured")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            ForEach(projection, id: \.date) { sample in
                LineMark(
                    x: .value("Time", sample.date), y: .value("Free", sample.value),
                    series: .value("Series", "Expected")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            }
        }
        .chartYScale(domain: 0 ... top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel { Text(axisBytes(value.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Free space, measured and expected"))
        .accessibilityValue(Text(summary))
        .accessibilityAddTraits(.isImage)
        .accessibilityChartDescriptor(self)
    }
}

extension DiskChart: @MainActor AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let all = detail.history + projection
        let start = all.first?.date.timeIntervalSince1970 ?? 0, end = all.last?.date.timeIntervalSince1970 ?? 1
        let x = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"), range: start ... max(end, start + 1), gridlinePositions: []
        ) {
            Date(timeIntervalSince1970: $0).formatted(.dateTime.day().month(.abbreviated))
        }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Free"), range: 0 ... top, gridlinePositions: []) {
            bytes(Int64($0))
        }
        let series = [("Measured", detail.history), ("Expected", projection)].map { name, samples in
            AXDataSeriesDescriptor(
                name: String(localized: String.LocalizationValue(name)), isContinuous: true,
                dataPoints: samples.map { .init(x: $0.date.timeIntervalSince1970, y: $0.value) }
            )
        }
        return AXChartDescriptor(
            title: String(localized: "Free space, measured and expected"),
            summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: series
        )
    }
}
