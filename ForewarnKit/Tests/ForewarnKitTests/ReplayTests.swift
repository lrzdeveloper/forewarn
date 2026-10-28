@testable import ForewarnKit
import Foundation
import Testing

/// Replaying a week, 5 minutes at a time as the app would, sends exactly
/// these notifications and nothing else.
struct ReplayTests {
    struct Sent: Equatable, CustomStringConvertible {
        var date: Date
        var kind: Insight.Kind
        var description: String { "\(kind) \(date.formatted(.iso8601))" }
    }

    static let rome = TimeZone(identifier: "Europe/Rome")!

    /// Feeds `readings` to a fresh store as time passes and runs the forecast and the insights every 5 minutes.
    static func replay(_ readings: [Reading]) async throws -> [Sent] {
        let readings = readings.sorted { $0.date < $1.date }
        let store = try Store(path: nil)
        let forecaster = BatteryForecaster(store: store, timeZone: rome)
        guard let first = readings.first?.date, let end = readings.last?.date else { return [] }
        var next = 0, percent: Double?, onAC: Bool?, sent: [Sent] = []
        for now in stride(from: first.timeIntervalSince1970, through: end.timeIntervalSince1970, by: 300)
            .map(Date.init(timeIntervalSince1970:))
        {
            // What the recorder would have stored by now, with the plug-ins and unplugs in it.
            while next < readings.count, readings[next].date <= now {
                let r = readings[next]
                try store.record([r])
                if r.metric == .batteryPercent {
                    percent = r.value
                }
                if r.metric == .onAC {
                    let plugged = r.value > 0.5
                    if let onAC, onAC != plugged {
                        try store.record(Event(plugged ? .plugIn : .unplug, at: r.date))
                    }
                    onAC = plugged
                }
                next += 1
            }
            guard let percent, let onAC else { continue }
            let battery = BatteryStatus(percent: percent, isCharging: false, isOnAC: onAC)
            let forecast = try await forecaster.update(battery: battery, now: now)
            let context = InsightContext(now: now, battery: battery, forecast: forecast, disk: nil)
            for insight in try Insights.due(context, store: store) {
                try store.logNotification(insight, at: now)
                sent.append(Sent(date: now, kind: insight.kind))
            }
        }
        return sent
    }

    static let start = Date(timeIntervalSince1970: 1_791_151_200) // Monday 5 October 2026, 00:00 in Rome

    /// Six ordinary days (unplug at 8:00, 7% an hour, plug in at 18:00 with 30% left), then a heavy one at 11% an
    /// hour that would reach 10% before 18:00.
    static func week() -> [Reading] {
        var readings: [Reading] = []
        for day in 0 ..< 7 {
            let drain = day == 6 ? 11.0 : 7.0
            for step in 0 ..< 288 {
                let date = Self.start.addingTimeInterval(Double(day) * 86400 + Double(step) * 300)
                let hour = Double(step) / 12
                let onBattery = hour >= 8 && hour < 18
                let level = onBattery ? max(100 - drain * (hour - 8), 0) : 100
                readings += [Reading(.batteryPercent, level, at: date), Reading(.onAC, onBattery ? 0 : 1, at: date)]
            }
        }
        return readings
    }

    /// One battery warning on the heavy day's morning, nothing else all week.
    @Test func aHeavyDayWarnsOnce() async throws {
        let sent = try await Self.replay(Self.week())
        #expect(sent.map(\.kind) == [.battery])
        let warnedAt = try #require(sent.first?.date)
        let heavyMorning = Self.start.addingTimeInterval(6 * 86400 + 8 * 3600)
        // Before the battery falls under 25% (14:49) and so before it reaches 10% (16:11).
        #expect(warnedAt > heavyMorning && warnedAt < heavyMorning.addingTimeInterval(6.8 * 3600))
        print(
            "heavy day warned at",
            warnedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: Self.rome))
        )
    }
}
