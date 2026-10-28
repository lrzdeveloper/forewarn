@testable import ForewarnKit
import Foundation
import Testing

struct HealthOutlookTests {
    let now = monday.addingTimeInterval(100 * 86400)

    /// Ten days on battery, 50 points drained each day: half a cycle a day.
    func store() throws -> Store {
        let store = try Store(path: nil)
        for day in 0 ..< 10 {
            let morning = now - Double(10 - day) * 86400
            try store.record([
                Reading(.onAC, 0, at: morning), Reading(.batteryPercent, 100, at: morning),
                Reading(.batteryPercent, 50, at: morning + 8 * 3600), Reading(.onAC, 1, at: morning + 8 * 3600),
            ])
        }
        return store
    }

    func estimate(_ store: Store, capacity: Double = 100, fullCharge: Double?, cycles: Double) throws -> HealthOutlook {
        try #require(try HealthOutlook.estimate(
            store: store, maximumCapacity: capacity, fullChargePercent: fullCharge, cycleCount: cycles,
            designCycleCount: 1000, now: now
        ))
    }

    @Test func curveAndYearValues() throws {
        // Apple's design wear on a new battery: 0.02 points a cycle, half a cycle a day, 0.01 points a day.
        let outlook = try estimate(store(), fullCharge: 100, cycles: 0)
        #expect(outlook.basis == .cycles)
        #expect(abs(outlook.lossPerDay - 0.01) < 0.0001 && abs((outlook.cyclesPerYear ?? 0) - 182.5) < 0.5)
        #expect(abs(outlook.inOneYear - 96.35) < 0.05 && abs(outlook.inThreeYears - 89.05) < 0.05)
        let end = now.addingTimeInterval(3 * 365 * 86400)
        let path = outlook.path(to: end)
        #expect(path.first?.date == now && path.last?.date == end)
        #expect(path.first?.median == 100) // starts at Maximum Capacity now
        #expect(zip(path, path.dropFirst()).allSatisfy { $0.median > $1.median && $1.low <= $1.median })
        #expect(path.allSatisfy { $0.high <= 100 })
    }

    @Test func bandSpansTheBatterysOwnWearAndTheDesignFigure() throws {
        // 6% lost in 150 cycles is 0.04 a cycle, twice Apple's 0.02; half trusted at 150 cycles: 0.03 expected.
        let outlook = try estimate(store(), capacity: 97, fullCharge: 94, cycles: 150)
        #expect(abs(outlook.lossPerDay - 0.015) < 0.0001)
        #expect(abs(outlook.lossRange.lowerBound - 0.01) < 0.0001 && abs(outlook.lossRange.upperBound - 0.02) < 0.0001)
        let inAYear = outlook.capacity(at: now.addingTimeInterval(365 * 86400))
        #expect(abs(inAYear.high - (97 - 3.65)) < 0.01 && abs(inAYear.low - (97 - 7.3)) < 0.01)

        // When the two agree the band keeps ±20%: one battery's wear so far is not proof.
        let agreeing = try estimate(store(), capacity: 97, fullCharge: 97, cycles: 150)
        #expect(abs(agreeing.lossRange.lowerBound - 0.008) < 0.0001)
        #expect(abs(agreeing.lossRange.upperBound - 0.012) < 0.0001)
    }

    @Test func switchesToTheMeasuredTrendAfterTwoMonths() throws {
        /// 95% falling 1 point a month, with a wobble of ±0.3 points.
        func record(days: Int, into store: Store) throws {
            try store.record((0 ... days).map {
                Reading(
                    .maximumCapacity, 95 - Double($0) / 30 + ($0.isMultiple(of: 2) ? 0.3 : -0.3),
                    at: now - Double(days - $0) * 86400
                )
            })
        }
        let young = try store()
        try record(days: 30, into: young)
        #expect(try estimate(young, capacity: 92, fullCharge: 92, cycles: 100).basis == .cycles)

        let old = try store()
        try record(days: 90, into: old)
        let outlook = try estimate(old, capacity: 92, fullCharge: 92, cycles: 100)
        #expect(outlook.basis == .measured(days: 90))
        #expect(abs(outlook.lossPerDay - 1.0 / 30) < 0.001)
        // A small wobble against a clear decline: the ±20% floor sets the band (noisier readings, next test).
        #expect(abs(outlook.lossRange.lowerBound - 0.8 * outlook.lossPerDay) < 0.0005)
        let at = try #require(outlook.reaches80At)
        #expect(abs(at.timeIntervalSince(now) / 86400 - 360) < 5)
    }

    @Test func noisyReadingsWidenTheBand() throws {
        func outlook(wobble: Double) throws -> HealthOutlook {
            let store = try store()
            try store.record((0 ... 90).map {
                Reading(
                    .maximumCapacity, 95 - Double($0) / 90 + ($0.isMultiple(of: 2) ? wobble : -wobble),
                    at: now - Double(90 - $0) * 86400
                )
            })
            return try estimate(store, capacity: 94, fullCharge: 94, cycles: 100)
        }
        let calm = try outlook(wobble: 0.05), noisy = try outlook(wobble: 1.5)
        let width = { (o: HealthOutlook) in o.lossRange.upperBound - o.lossRange.lowerBound }
        #expect(width(noisy) > 2 * width(calm))
    }

    @Test func noDateBeyondTenYears() {
        // A battery losing nothing so far and agreeing with the design figure at a tenth of a cycle a day.
        let outlook = HealthOutlook(
            basis: .cycles, start: now, maximumCapacity: 100, lossPerDay: 0.002, lossRange: 0.001 ... 0.003,
            cyclesPerDay: 0.1
        )
        #expect(outlook.reaches80At == nil)
    }
}

struct DiskDetailTests {
    let now = monday.addingTimeInterval(20 * 86400)

    @Test func foldersCarryTheirGrowthSinceTheScanBefore() throws {
        let store = try Store(path: nil)
        for (days, derived, caches) in [(14.0, "30", "9"), (7.0, "34", "12")] {
            try store.record(Event(.folderSize, at: now - days * 86400, ["path": "/DerivedData", "bytes": derived]))
            try store.record(Event(.folderSize, at: now - days * 86400 + 1, ["path": "/Caches", "bytes": caches]))
        }
        try store.record(Event(.folderSize, at: now - 86400, ["path": "/Downloads", "bytes": "20"]))
        let folders = try DiskTrend.folders(store: store, now: now)
        #expect(folders == [
            .init(path: "/DerivedData", bytes: 34, growth: 4),
            .init(path: "/Downloads", bytes: 20, growth: nil),
            .init(path: "/Caches", bytes: 12, growth: 3),
        ])
        #expect(try Insights.folderGrowth(store: store, now: now)?.path == "/DerivedData")
    }

    @Test func dailyKeepsTheLastValueOfEachDay() {
        let free = (0 ..< 40 * 24).map { Reading(.diskFree, Double($0), at: now - Double(40 * 24 - $0) * 3600) }
        let daily = DiskTrend.daily(free: free, now: now)
        #expect(daily.count == 30 && daily.last?.value == Double(40 * 24 - 1))
        #expect(zip(daily, daily.dropFirst()).allSatisfy { $0.date < $1.date })
    }
}

struct HealthEdgesTests {
    let now = monday.addingTimeInterval(200 * 86400)

    @Test func capacityNeverGoesBelowZero() {
        let outlook = HealthOutlook(
            basis: .cycles, start: now, maximumCapacity: 50, lossPerDay: 1, lossRange: 0.5 ... 2, cyclesPerDay: 1
        )
        let point = outlook.capacity(at: now + 365 * 86400)
        #expect(point.low == 0 && point.median == 0 && point.high == 0)
    }

    @Test func aMeasuredDeclineNeedsNoRecentCycling() throws {
        // Three months of Maximum Capacity falling a point a month, and no battery use at all: kept plugged in.
        let store = try Store(path: nil)
        try store.record((0 ... 90).map { Reading(
            .maximumCapacity,
            95 - Double($0) / 30,
            at: now - Double(90 - $0) * 86400
        ) })
        let outlook = try #require(try HealthOutlook.estimate(
            store: store, maximumCapacity: 92, fullChargePercent: 92, cycleCount: 100, designCycleCount: 1000, now: now
        ))
        #expect(outlook.basis == .measured(days: 90))
        #expect(outlook.cyclesPerDay == nil)
    }

    @Test func theMeasurementsThemselvesMustSpanTwoMonths() throws {
        let store = try Store(path: nil)
        // Three readings 60, 59 and 58 days ago: two days of trend, two months old.
        try store
            .record([95, 94, 93].enumerated().map { Reading(.maximumCapacity, $1, at: now - Double(60 - $0) * 86400) })
        #expect(try HealthTrend.fit(store: store, now: now) == nil)
        // Two months of readings, but the last one 30 days ago: stale.
        let stale = try Store(path: nil)
        try stale.record((0 ... 60).map { Reading(
            .maximumCapacity,
            95 - Double($0) / 30,
            at: now - Double(90 - $0) * 86400
        ) })
        #expect(try HealthTrend.fit(store: stale, now: now) == nil)
        #expect(try HealthTrend.fit(store: stale, now: now - 20 * 86400)?.days == 60)
    }
}
