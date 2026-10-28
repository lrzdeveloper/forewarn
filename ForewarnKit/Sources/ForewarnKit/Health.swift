import Foundation

/// Where battery health is heading: from wear per cycle and cycles per day until two months of
/// measured health exist, then from the measured trend. A straight line from Maximum Capacity now, with a band
/// whose width says how sure the estimate is.
public struct HealthOutlook: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// Cycles a day and wear per cycle: the battery's own so far, blended with Apple's design figure.
        case cycles
        /// The straight line through this many days of measured Maximum Capacity.
        case measured(days: Int)
    }

    public var basis: Basis
    public var start: Date
    /// Maximum Capacity now, percent.
    public var maximumCapacity: Double
    /// Points of Maximum Capacity lost a day: the expected line.
    public var lossPerDay: Double
    /// The slowest and fastest loss the data allows: the band's edges.
    public var lossRange: ClosedRange<Double>
    /// Full cycles a day over the last 30 days; nil without three days of battery history. A measured trend needs
    /// none: a Mac kept plugged in still wears.
    public var cyclesPerDay: Double?

    public var cyclesPerYear: Double? { cyclesPerDay.map { $0 * 365 } }

    /// Expected Maximum Capacity at `date` (median) between the band's edges, percent: never below 0 or above 100.
    public func capacity(at date: Date) -> Overview.Forecast.Point {
        let days = max(date.timeIntervalSince(start) / 86400, 0)
        func after(_ loss: Double) -> Double {
            min(max(maximumCapacity - loss * days, 0), 100)
        }
        return .init(
            date: date, low: after(lossRange.upperBound), median: after(lossPerDay), high: after(lossRange.lowerBound)
        )
    }

    public var inOneYear: Double { capacity(at: start.addingTimeInterval(365 * 86400)).median }
    public var inThreeYears: Double { capacity(at: start.addingTimeInterval(3 * 365 * 86400)).median }

    /// When the expected line reaches 80%, the usual service threshold; nil beyond ten years.
    public var reaches80At: Date? {
        guard lossPerDay > 0 else { return maximumCapacity <= 80 ? start : nil }
        let days = max(maximumCapacity - 80, 0) / lossPerDay
        return days < 3650 ? start.addingTimeInterval(days * 86400) : nil
    }

    /// A point a month from now to `end`, and `end` itself: the chart's expected line and band.
    public func path(to end: Date) -> [Overview.Forecast.Point] {
        stride(from: start, to: end, by: 30 * 86400).map(capacity(at:)) + [capacity(at: end)]
    }

    /// Apple designs these batteries to keep 80% after their design cycle count (1,000 on Apple silicon laptops).
    static let designWear = 20.0
    /// A single battery's wear says little at first: the band is never narrower than ±20% of the expected loss.
    static let minimumSpread = 0.2

    /// - Parameters:
    ///   - fullChargePercent: full-charge over design capacity: finer than System Settings' figure, which stops at
    /// 100%.
    public static func estimate(
        store: Store, maximumCapacity: Double, fullChargePercent: Double?, cycleCount: Double,
        designCycleCount: Double?, now: Date = .now
    ) throws -> HealthOutlook? {
        let cyclesPerDay = try cyclesPerDay(store: store, now: now)
        if let trend = try HealthTrend.fit(store: store, now: now), trend.slope < 0 {
            // About 95% of lines that fit the readings as well: two standard errors of the slope either side.
            let loss = -trend.slope, spread = max(2 * trend.standardError, minimumSpread * loss)
            return HealthOutlook(
                basis: .measured(days: trend.days), start: now, maximumCapacity: maximumCapacity,
                lossPerDay: loss, lossRange: max(loss - spread, 0) ... loss + spread, cyclesPerDay: cyclesPerDay
            )
        }
        // Wear per cycle: the battery's own so far, trusted more as cycles add up; Apple's design figure before that.
        // The band runs between the two, so it is as wide as they disagree. Needs the battery to be cycling.
        guard let cyclesPerDay, cyclesPerDay > 0 else { return nil }
        let design = designWear / (designCycleCount ?? 1000)
        let observed = fullChargePercent.map { max(100 - $0, 0) / max(cycleCount, 1) } ?? design
        let trust = min(cycleCount / 300, 1)
        let perCycle = trust * observed + (1 - trust) * design
        let slow = min(observed, design, (1 - minimumSpread) * perCycle)
        let fast = max(observed, design, (1 + minimumSpread) * perCycle)
        return HealthOutlook(
            basis: .cycles, start: now, maximumCapacity: maximumCapacity, lossPerDay: perCycle * cyclesPerDay,
            lossRange: slow * cyclesPerDay ... fast * cyclesPerDay, cyclesPerDay: cyclesPerDay
        )
    }

    /// Full cycles a day, from the battery drained over the last 30 days (100 points is one cycle). Needs three days.
    static func cyclesPerDay(store: Store, now: Date) throws -> Double? {
        let start = now.addingTimeInterval(-30 * 86400)
        let levels = try store.series(.batteryPercent, since: start)
        let power = try store.series(.onAC, since: start)
        guard let first = levels.first, now.timeIntervalSince(first.date) >= 3 * 86400 else { return nil }
        var drained = 0.0, previous: Double?, onAC = false, p = 0
        for level in levels {
            while p < power.count, power[p].date <= level.date {
                onAC = power[p].value > 0.5
                p += 1
            }
            // `previous` is set only for readings taken on battery: the drop since then was a discharge.
            if let previous {
                drained += max(previous - level.value, 0)
            }
            previous = onAC ? nil : level.value
        }
        return drained / 100 / (now.timeIntervalSince(first.date) / 86400)
    }
}

public enum HealthTrend {
    /// Maximum Capacity averaged per day, oldest first: the samples at full resolution would outweigh older days.
    public static func daily(store: Store) throws -> [Reading] {
        let days = try Dictionary(grouping: store.series(.maximumCapacity)) {
            ($0.date.timeIntervalSince1970 / 86400).rounded(.down)
        }
        return days.keys.sorted().map { day in
            let values = days[day]!.map(\.value)
            return Reading(.maximumCapacity, values.reduce(0, +) / Double(values.count), at: days[day]![0].date)
        }
    }

    /// The straight line through the daily values: points a day, its standard error from the scatter around it,
    /// the days it covers and the last value.
    struct Fit {
        var slope: Double, standardError: Double, days: Int, last: Reading
    }

    /// Needs measurements that themselves span two months, the last of them from the last two weeks.
    static func fit(store: Store, now: Date) throws -> Fit? {
        let series = try daily(store: store).filter { $0.date <= now }
        guard let first = series.first, let last = series.last, series.count >= 3,
              last.date.timeIntervalSince(first.date) >= 60 * 86400,
              now.timeIntervalSince(last.date) <= 14 * 86400 else { return nil }
        let points = series.map { (x: $0.date.timeIntervalSince(first.date) / 86400, y: $0.value) }
        let slope = leastSquaresSlope(points)
        let mx = points.map(\.x).reduce(0, +) / Double(points.count)
        let my = points.map(\.y).reduce(0, +) / Double(points.count)
        let residuals = points.reduce(0) { $0 + pow($1.y - (my + slope * ($1.x - mx)), 2) }
        let spread = points.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        let standardError = (residuals / Double(points.count - 2) / spread).squareRoot()
        return Fit(
            slope: slope, standardError: standardError,
            days: Int((last.date.timeIntervalSince(first.date) / 86400).rounded()), last: last
        )
    }

    /// When the straight line through daily health values reaches 80%; needs two months of history, and `nil`
    /// when health is not declining or it would take more than five years.
    public static func reaches80(store: Store, now: Date = .now) throws -> Date? {
        guard let trend = try fit(store: store, now: now), trend.last.value > 80, trend.slope < 0 else { return nil }
        let days = (trend.last.value - 80) / -trend.slope
        return days < 5 * 365 ? trend.last.date.addingTimeInterval(days * 86400) : nil
    }
}
