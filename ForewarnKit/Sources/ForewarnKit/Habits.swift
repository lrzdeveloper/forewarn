import Foundation

/// When this person usually plugs in, read straight from past days: starting from the same clock
/// time on each earlier day when they were unplugged, how soon did they plug in? Older days count less (half-life
/// three weeks); with four weeks of history only the same weekday counts, before that every day does.
///
/// From that comes the chance of still being unplugged at a given time (`stillUnplugged`), and from that the
/// expected next plug-in time with its own quantiles. A regular habit reads as near certain, as it should.
public struct PlugInHabit: Sendable {
    static let halfLife = 21 * 86400.0
    static let lookBackDays = 60

    private let plugIns: [Date], unplugs: [Date]
    private let historyStart: Date, now: Date
    /// How much other weekdays count, from 1 (short history) down to 0 (four weeks or more).
    private let otherWeekdayWeight: Double

    /// - Parameters:
    ///   - plugIns: plug-in times, any order. `unplugs` tell when the Mac was already on power (those days are
    ///     skipped: they say nothing about when someone on battery plugs in).
    ///   - historyStart: when recording began; days before it are not read as "never plugged in".
    public init(plugIns: [Date], unplugs: [Date] = [], historyStart: Date, now: Date) {
        self.plugIns = plugIns.sorted()
        self.unplugs = unplugs.sorted()
        self.historyStart = historyStart
        self.now = now
        otherWeekdayWeight = max(0, 1 - now.timeIntervalSince(historyStart) / (28 * 86400))
    }

    /// Chance of still being unplugged at each of `count` steps of `step` seconds from `start` (index 0 is `start`).
    /// Each past day counts only as far as it has been observed; the curve never rises.
    public func stillUnplugged(from start: Date, step: TimeInterval, count: Int) -> [Double] {
        var unplugged = [Double](repeating: 0, count: count), observed = [Double](repeating: 0, count: count)
        let decay = log(2) / Self.halfLife
        for day in 1 ... Self.lookBackDays {
            let origin = start.addingTimeInterval(-Double(day) * 86400)
            guard origin >= historyStart else { break }
            let weight = exp(-decay * Double(day) * 86400) * (day % 7 == 0 ? 1 : otherWeekdayWeight)
            guard weight > 0, !onPower(at: origin) else { continue }
            let next = plugIns.first { $0 > origin }
            for k in 0 ..< count {
                let time = origin.addingTimeInterval(Double(k) * step)
                guard time <= now else { break }
                observed[k] += weight
                if next.map({ $0 > time }) ?? true {
                    unplugged[k] += weight
                }
            }
        }
        var curve: [Double] = [], last = 1.0
        for k in 0 ..< count {
            if observed[k] > 0 {
                last = min(last, unplugged[k] / observed[k])
            }
            curve.append(last)
        }
        return curve
    }

    /// The time by which the person has plugged in with chance `q`, within a day of `start`; `nil` if not.
    public func plugInTime(_ q: Double = 0.5, from start: Date) -> Date? {
        let step = 300.0
        let curve = stillUnplugged(from: start, step: step, count: 288)
        return curve.firstIndex { $0 <= 1 - q }.map { start.addingTimeInterval(Double($0) * step) }
    }

    /// On power at `time`: the last plug-in or unplug before it was a plug-in. Without unplugs, unknown: no.
    private func onPower(at time: Date) -> Bool {
        guard !unplugs.isEmpty, let plugIn = plugIns.last(where: { $0 <= time }) else { return false }
        return unplugs.last { $0 <= time }.map { $0 < plugIn } ?? true
    }
}

/// F1 risk: chance the battery reaches `threshold` before the person plugs in.
/// The forecast gives, at each step, the chance the level is below the threshold by then (read between its
/// quantiles); the habit gives the chance of still being unplugged. The forecast's horizon bounds the answer.
public func runOutRisk(forecast: Overview.Forecast, habit: PlugInHabit?,
                       threshold: Double = Overview.lowBatteryPercent) -> Double
{
    let steps = forecast.quantiles.horizon
    let unplugged = habit?.stillUnplugged(from: forecast.start, step: forecast.step, count: steps)
        ?? Array(repeating: 1, count: steps)
    var reached = 0.0, risk = 0.0
    for k in 0 ..< steps {
        let column = forecast.quantiles.values.map { $0[k] }
        let below = max(reached, chanceBelow(threshold, quantiles: column))
        risk += (below - reached) * unplugged[k]
        reached = below
    }
    return risk
}

/// P(value < threshold) from one step's 21 quantiles, linear between levels.
func chanceBelow(_ threshold: Double, quantiles column: [Double]) -> Double {
    let levels = QuantileForecast.levels
    guard let first = column.first, let last = column.last else { return 0 }
    if threshold <= first {
        return 0
    }
    if threshold > last {
        return 1
    }
    for i in 1 ..< column.count where threshold <= column[i] {
        let span = column[i] - column[i - 1]
        let fraction = span > 0 ? (threshold - column[i - 1]) / span : 1
        return levels[i - 1] + fraction * (levels[i] - levels[i - 1])
    }
    return 1
}

/// Hour of week (Sunday 0:00 is 0) and hour of day. 1 January 1970 was a Thursday.
func hourBuckets(_ time: TimeInterval, utcOffset: Double) -> (week: Int, day: Int) {
    let hours = Int(((time + utcOffset) / 3600).rounded(.down))
    let hour = ((hours % 24) + 24) % 24
    let weekday = ((hours / 24 + 4) % 7 + 7) % 7
    return (weekday * 24 + hour, hour)
}
