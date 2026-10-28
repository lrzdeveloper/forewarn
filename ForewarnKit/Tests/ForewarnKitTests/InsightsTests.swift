@testable import ForewarnKit
import Foundation
import Testing

/// Times in UTC so hour-of-day buckets are predictable: 2026-10-05 was a Monday.
let monday = Date(timeIntervalSince1970: 1_791_158_400)

struct PlugInHabitTests {
    @Test func learnsTheEveningPlugIn() throws {
        // Plugged in at 18:00 every day for two weeks.
        let plugIns = (0 ..< 14).map { monday.addingTimeInterval(Double($0) * 86400 + 18 * 3600) }
        let now = monday.addingTimeInterval(14 * 86400 + 12 * 3600) // Monday noon, two weeks later
        let habit = PlugInHabit(plugIns: plugIns, historyStart: monday, now: now)
        let median = try #require(habit.plugInTime(from: now))
        #expect(median.timeIntervalSince(now) == 6 * 3600) // 18:00
        let curve = habit.stillUnplugged(from: now, step: 300, count: 144)
        #expect(curve[0] == 1 && curve == curve.sorted(by: >))
        #expect(curve[60] == 1) // 17:00: never plugged in by then
        #expect(curve[73] == 0) // 18:05: always plugged in by then
    }

    @Test func noPlugInsNeverExpectsOne() {
        let habit = PlugInHabit(plugIns: [], historyStart: monday, now: monday + 86400)
        #expect(habit.plugInTime(from: monday + 86400) == nil)
    }
}

struct RiskTests {
    /// A forecast whose quantiles at every step are `level − drop·k` spread ±`spread`.
    func forecast(level: Double, drop: Double, spread: Double, steps: Int = 145) -> Overview.Forecast {
        let rows = QuantileForecast.levels.map { q in
            (0 ..< steps).map { k in level - drop * Double(k) + (q - 0.5) * 2 * spread * Double(k) / Double(steps) }
        }
        return Overview.Forecast(start: monday, step: 300, quantiles: QuantileForecast(values: rows))
    }

    @Test func chanceBelowReadsBetweenQuantiles() {
        let column = QuantileForecast.levels.map { $0 * 100 } // value = level × 100
        #expect(abs(chanceBelow(50, quantiles: column) - 0.5) < 1e-9)
        #expect(chanceBelow(0.5, quantiles: column) == 0)
        #expect(chanceBelow(100, quantiles: column) == 1)
    }

    @Test func riskNeedsTheDrainToComeBeforeThePlugIn() {
        let draining = forecast(level: 50, drop: 0.5, spread: 10) // median at 10% after 80 steps (6 h 40 min)
        #expect(runOutRisk(forecast: draining, habit: nil) > 0.9)
        #expect(runOutRisk(forecast: forecast(level: 80, drop: 0.1, spread: 5), habit: nil) < 0.01)

        // Plugs in every day at 03:00 (in 3 hours): mostly safe.
        let plugIns = (0 ..< 14).map { monday.addingTimeInterval(-Double($0 + 1) * 86400 + 3 * 3600) }
        let habit = PlugInHabit(plugIns: plugIns, historyStart: monday - 15 * 86400, now: monday)
        #expect(runOutRisk(forecast: draining, habit: habit) < 0.05)
    }
}

struct ThresholdTests {
    func note(_ kind: Insight.Kind, _ action: SentNotification.Action?) -> SentNotification {
        SentNotification(id: 0, kind: kind, date: monday, action: action, details: [:])
    }

    @Test func threeDismissalsInARowRaiseOneStep() {
        let d = note(.battery, .dismissed), ok = note(.battery, .acknowledged)
        #expect(Thresholds.steps([d, d]) == [:])
        #expect(Thresholds.steps([d, d, d])[.battery] == 1)
        #expect(Thresholds.steps([d, d, ok, d])[.battery] == nil) // an action breaks the run
        #expect(Thresholds.steps(Array(repeating: d, count: 12))[.battery] == 2) // two steps at most
        #expect(Thresholds.steps(Array(repeating: note(.health, .dismissed), count: 3)) == [:])
    }

    @Test func detailsRoundTrip() {
        let all: [Insight] = [
            .batteryLow(at: monday, plugIn: monday + 3600, chance: 0.7),
            .diskFilling(at: nil, freeBytes: 9e9, folder: "/Users/x/Library/Caches", folderGrowth: 3e9),
            .sleepDrain(lost: 14, hours: 8, usualPerHour: 0.3, blockers: ["Docker", "sharingd"]),
            .dataRunsOut(at: monday, usedBytes: 15e9, limitBytes: 20e9),
            .batteryHealth(percent: 88, previous: 91),
        ]
        for insight in all {
            #expect(Insight(kind: insight.kind, details: insight.details) == insight)
        }
    }
}

struct InsightRuleTests {
    let now = monday.addingTimeInterval(10 * 86400 + 12 * 3600) // a Thursday noon

    func store() throws -> Store {
        let store = try Store(path: nil)
        try store.record([Reading(.onAC, 1, at: monday)]) // history starts here
        return store
    }

    @Test func batteryFiresOncePerSession() throws {
        let store = try store()
        try store.record(Event(.unplug, at: now - 3600))
        let draining = RiskTests().forecast(level: 50, drop: 0.5, spread: 10)
        var context = InsightContext(
            now: now, battery: BatteryStatus(percent: 50, isCharging: false, isOnAC: false),
            forecast: Overview.Forecast(start: now, step: 300, quantiles: draining.quantiles), disk: nil
        )
        let due = try Insights.due(context, store: store)
        #expect(due.map(\.kind) == [.battery])
        try store.logNotification(due[0], at: now)

        context.now = now + 2 * 86400 // still the same discharge session
        #expect(try Insights.due(context, store: store).isEmpty)
        try store.record(Event(.unplug, at: now + 2 * 86400 - 1800)) // a new session
        #expect(try Insights.due(context, store: store).map(\.kind) == [.battery])

        context.battery?.percent = 20 // under 25%: macOS's own warning is close, nothing from Forewarn
        #expect(try Insights.due(context, store: store).isEmpty)
        context.battery?.percent = 50
        context.disabled = [.battery]
        #expect(try Insights.due(context, store: store).isEmpty)
    }

    @Test func diskFiresUnderTenPercentAfterAWeek() throws {
        let store = try store()
        let context = InsightContext(now: now, battery: nil, forecast: nil, disk: (free: 50e9, total: 1000e9))
        try store.record([Reading(.diskFree, 52e9, at: now - 3 * 86400)])
        #expect(try Insights.due(context, store: store).isEmpty) // three days of history
        try store.record([Reading(.diskFree, 60e9, at: now - 8 * 86400)])
        try store.record(Event(.folderSize, at: now - 8 * 86400, ["path": "/Caches", "bytes": "10000000000"]))
        try store.record(Event(.folderSize, at: now - 86400, ["path": "/Caches", "bytes": "16000000000"]))
        let due = try Insights.due(context, store: store)
        guard case let .diskFilling(_, free, folder, growth) = due.first else {
            Issue.record("no disk insight: \(due)")
            return
        }
        #expect(free == 50e9 && folder == "/Caches" && growth == 6e9)
    }

    @Test func sleepFiresOnAnUnusualNightRightAfterWaking() throws {
        let store = try store()
        // Five ordinary nights: 2 points over 8 hours.
        for night in 0 ..< 5 {
            let start = monday.addingTimeInterval(Double(night) * 86400 + 23 * 3600)
            try store.record(Event(.sleep, at: start, ["percent": "90", "blockers": ""]))
            try store.record(Event(.wake, at: start + 8 * 3600, ["percent": "88"]))
        }
        let start = now - 9 * 3600
        try store.record(Event(.sleep, at: start, ["percent": "90", "blockers": "Docker, sharingd"]))
        try store.record(Event(.wake, at: now - 600, ["percent": "70"]))
        let due = try Insights.due(InsightContext(now: now, battery: nil, forecast: nil, disk: nil), store: store)
        #expect(due == [.sleepDrain(
            lost: 20,
            hours: 8 + 50 / 60,
            usualPerHour: 0.25,
            blockers: ["Docker", "sharingd"]
        )])
        // Hours later the moment has passed.
        let later = InsightContext(now: now + 3 * 3600, battery: nil, forecast: nil, disk: nil)
        #expect(try Insights.due(later, store: store).isEmpty)
    }

    @Test func dataFiresOnlyWithALimit() throws {
        let store = try store()
        try store.record([Reading(.meteredBytes, 15e9, at: now - 3600)])
        var context = InsightContext(now: now, battery: nil, forecast: nil, disk: nil)
        #expect(try Insights.due(context, store: store).isEmpty)
        let resetDay = Calendar.current.component(.day, from: now - 5 * 86400)
        context.meteredLimit = (bytes: 20e9, resetDay: resetDay) // 15 GB in 5 days: 20 GB in under 7
        #expect(try Insights.due(context, store: store).map(\.kind) == [.data])
    }

    @Test func healthReportsATwoPointDropMonthlyAtMost() throws {
        let store = try store()
        try store.record([Reading(.maximumCapacity, 90, at: now)])
        try store.logNotification(.batteryHealth(percent: 93, previous: nil), at: now - 40 * 86400)
        let context = InsightContext(now: now, battery: nil, forecast: nil, disk: nil)
        #expect(try Insights.due(context, store: store) == [.batteryHealth(percent: 90, previous: 93)])
        try store.logNotification(.batteryHealth(percent: 90, previous: 93), at: now - 86400)
        try store.record([Reading(.maximumCapacity, 85, at: now)])
        #expect(try Insights.due(context, store: store).isEmpty) // a month has not passed
    }

    @Test func healthOutlookFromCycles() throws {
        let store = try store()
        // Ten days on battery, 50 points drained each day: half a cycle a day.
        var readings: [Reading] = []
        for day in 0 ..< 10 {
            let morning = now - Double(10 - day) * 86400
            readings += [Reading(.onAC, 0, at: morning), Reading(.batteryPercent, 100, at: morning),
                         Reading(.batteryPercent, 50, at: morning + 8 * 3600), Reading(
                             .onAC,
                             1,
                             at: morning + 8 * 3600
                         )]
        }
        try store.record(readings)
        let outlook = try #require(try HealthOutlook.estimate(
            store: store, maximumCapacity: 100, fullChargePercent: 100, cycleCount: 0, designCycleCount: 1000, now: now
        ))
        #expect(abs(outlook.cyclesPerDay - 0.5) < 0.01)
        // Apple's design wear: 0.02 points per cycle, 0.01 a day: 96.35% in a year, 80% in 2,000 days.
        #expect(abs(outlook.inOneYear - 96.35) < 0.1)
        #expect(abs((outlook.reaches80At ?? now).timeIntervalSince(now) / 86400 - 2000) < 30)
    }

    @Test func healthTrendNeedsTwoMonthsAndADecline() throws {
        let store = try store()
        // 95% falling 1 point a month for three months: 80% about 12 months after the last value.
        let readings = (0 ... 90).map { Reading(
            .maximumCapacity,
            95 - Double($0) / 30,
            at: now - Double(90 - $0) * 86400
        ) }
        try store.record(readings)
        let at = try #require(try HealthTrend.reaches80(store: store, now: now))
        #expect(abs(at.timeIntervalSince(now) / 86400 - 360) < 2)
        let young = try self.store()
        try young.record(Array(readings.suffix(30)))
        #expect(try HealthTrend.reaches80(store: young, now: now) == nil)
    }
}
