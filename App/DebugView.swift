import Charts
import ForewarnKit
import SwiftUI

/// Hidden window with the raw series and the event log, to check what the recorder stores.
/// Opens at launch with `-FWDebug YES` (`make debug`); not part of the product, not localized.
struct DebugView: View {
    static let windowID = "debug"

    @Environment(OverviewStore.self) private var overviewStore
    @State private var metric = Metric.batteryPercent
    @State private var days = 7
    @State private var summary: [Store.MetricSummary] = []
    @State private var series: [Reading] = []
    @State private var events: [Event] = []

    var body: some View {
        if let store = overviewStore.recorder?.store {
            HSplitView {
                Table(summary) {
                    TableColumn("Metric") { Text(verbatim: $0.metric.rawValue) }
                    TableColumn("Values") { Text(verbatim: "\($0.count)") }
                    TableColumn("Latest") { Text($0.latest, format: .dateTime.day().month().hour().minute()) }
                }
                .frame(minWidth: 320)

                VStack(alignment: .leading) {
                    HStack {
                        Picker(selection: $metric) {
                            ForEach(Metric.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                        } label: { Text(verbatim: "Metric") }
                        Picker(selection: $days) {
                            ForEach([1, 7, 30, 120], id: \.self) { Text(verbatim: "\($0) d").tag($0) }
                        } label: { Text(verbatim: "Range") }
                            .fixedSize()
                        Button { load(store) } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        Menu {
                            ForEach(Notifier.examples(), id: \.kind) { insight in
                                Button(insight.kind.rawValue) {
                                    Task { await overviewStore.notifier?.preview(insight) }
                                }
                            }
                        } label: {
                            Label("Send Test Notification", systemImage: "bell")
                        }
                        .fixedSize()
                        .accessibilityIdentifier("testNotification")
                    }
                    Chart(series, id: \.date) {
                        LineMark(x: .value("Time", $0.date), y: .value("Value", $0.value))
                    }
                    .frame(minHeight: 200)
                    Table(events.reversed()) {
                        TableColumn("Time") { Text($0.date, format: .dateTime.day().month().hour().minute()) }
                            .width(110)
                        TableColumn("Event") { Text(verbatim: $0.kind.rawValue) }
                            .width(90)
                        TableColumn("Details") { event in
                            Text(verbatim: event.details.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }
                                .joined(separator: "  "))
                        }
                    }
                }
                .padding()
                .frame(minWidth: 520)
            }
            .frame(minHeight: 520)
            // The overview changes after every recording: reload with it.
            .onChange(of: overviewStore.overview, initial: true) { load(store) }
            .onChange(of: metric) { load(store) }
            .onChange(of: days) { load(store) }
        } else {
            Text(verbatim: "No recorder: launched with sample data (-FWSample).")
                .padding(40)
        }
    }

    private func load(_ store: Store) {
        let start = Date.now.addingTimeInterval(-Double(days) * 86400)
        summary = (try? store.summary()) ?? []
        series = (try? store.series(metric, since: start)) ?? []
        events = (try? store.events(since: start)) ?? []
    }
}
