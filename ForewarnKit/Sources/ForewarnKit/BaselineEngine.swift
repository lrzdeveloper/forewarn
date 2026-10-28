import Foundation

/// The forecast that always works, and the fallback whenever history is short.
///
/// It forecasts the step-to-step change, not the level: the change expected at that hour of the week (the
/// seasonal part, falling back to hour of day and then to the overall mean while history is short), blended with
/// the recent change (the trend part), accumulated from the last observed level. The trend's weight fades with a
/// one-hour time constant: a burst of use says little about the evening.
/// Quantiles come from the errors this same method made at past origins in the series, step by step;
/// where too few exist, from a random walk widened with the square root of the horizon.
///
/// `pastCovariates[0]`, when given, marks steps (value 1) that break the series: no change is learned across them.
/// The battery forecast passes "on power" there, so a short top-up between two discharges is not read as a gain.
public struct BaselineEngine: ForecastEngine {
    /// Seconds per step, and the time of the step after the last one in `target`.
    public var step: TimeInterval
    public var nextStepDate: Date
    /// Where "hour of the day" is read.
    public var timeZone: TimeZone
    /// Weight of the recent change at the first step; it fades from there.
    var trendWeight = 0.5
    /// Steps averaged for the recent change: one hour on a 5-minute grid.
    var recentSteps = 12

    public init(step: TimeInterval, nextStepDate: Date, timeZone: TimeZone = .current) {
        self.step = step
        self.nextStepDate = nextStepDate
        self.timeZone = timeZone
    }

    public func forecast(_ request: ForecastRequest) async throws -> QuantileForecast {
        forecastNow(request)
    }

    func forecastNow(_ request: ForecastRequest) -> QuantileForecast {
        let y = request.target
        let changes = Self.changes(y, breaks: request.pastCovariates.first)
        let profile = SeasonalProfile(
            changes: changes, firstDate: date(ofIndex: 0, count: y.count), step: step,
            utcOffset: Double(timeZone.secondsFromGMT(for: nextStepDate))
        )
        let fit = Fit(changes: changes, profile: profile)
        guard let last = y.lastIndex(where: { !$0.isNaN }) else {
            return QuantileForecast(values: Array(repeating: Array(repeating: .nan, count: request.horizon), count: 21))
        }
        let point = path(from: last, level: y[last], count: y.count, horizon: request.horizon, fit)
        let spread = Spread(
            errors: pastErrors(y, fit, horizon: request.horizon),
            changeDeviation: Self.deviation(changes)
        )
        return QuantileForecast(values: QuantileForecast.levels.map { level in
            point.indices.map { point[$0] + spread.offset(level: level, step: $0) }
        })
    }

    // MARK: Point forecast

    /// What the series taught: its changes per step and their typical value by hour.
    private struct Fit {
        let changes: [Double]
        let profile: SeasonalProfile
    }

    /// Levels for steps 1…horizon after index `origin` of a series `count` long.
    private func path(
        from origin: Int, level: Double, count: Int, horizon: Int, _ fit: Fit
    ) -> [Double] {
        let recent = fit.changes[max(0, origin - recentSteps + 1) ... origin].filter { !$0.isNaN }
        let trend = recent.isEmpty ? fit.profile.overall : recent.reduce(0, +) / Double(recent.count)
        var value = level
        // Steps between the origin and the end of the series (backtests from the past) still count.
        return (1 ... horizon).map { k in
            let date = date(ofIndex: origin + k, count: count)
            let weight = trendWeight * exp(-Double(k - 1) / Double(recentSteps))
            value += (1 - weight) * fit.profile.change(at: date.timeIntervalSince1970) + weight * trend
            return value
        }
    }

    /// Date of index `i` in a series of `count` steps whose next step is `nextStepDate`.
    private func date(ofIndex i: Int, count: Int) -> Date {
        nextStepDate.addingTimeInterval(Double(i - count) * step)
    }

    // MARK: Spread

    /// In-sample profile; a rolling profile if the bands prove too narrow in backtests.
    /// Errors of the point forecast at past origins, per step ahead: `errors[k]` for step k + 1.
    /// The profile is learned from the whole series, so these errors are a little optimistic.
    private func pastErrors(
        _ y: [Double], _ fit: Fit, horizon: Int
    ) -> [[Double]] {
        var errors = Array(repeating: [Double](), count: horizon)
        // Every half hour of history, at most 400 origins: enough for stable quantiles, cheap to compute.
        let stride = max(6, (y.count - horizon) / 400)
        for origin in Swift.stride(from: recentSteps, to: y.count - 1, by: stride) where !y[origin].isNaN {
            let steps = min(horizon, y.count - 1 - origin)
            let forecast = path(from: origin, level: y[origin], count: y.count, horizon: steps, fit)
            for k in 0 ..< steps where !y[origin + k + 1].isNaN {
                errors[k].append(y[origin + k + 1] - forecast[k])
            }
        }
        return errors
    }

    private struct Spread {
        /// Sorted errors per step ahead.
        let errors: [[Double]]
        let changeDeviation: Double
        static let minimumErrors = 30

        init(errors: [[Double]], changeDeviation: Double) {
            self.errors = errors.map { $0.sorted() }
            self.changeDeviation = changeDeviation
        }

        func offset(level: Double, step k: Int) -> Double {
            let sorted = errors[k]
            guard sorted.count >= Self.minimumErrors else {
                // Random walk on the observed changes: the spread grows with √steps.
                return normalQuantile(level) * changeDeviation * Double(k + 1).squareRoot()
            }
            let position = level * Double(sorted.count - 1)
            let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
            return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
        }
    }

    // MARK: Series helpers

    /// Change per step. Across a gap of up to 12 hours (the Mac asleep, sampled rarely) the change is spread evenly
    /// over the missing steps, so slow overnight drain is learned too; longer gaps and breaks carry no change.
    static func changes(_ y: [Double], breaks: [Double]? = nil) -> [Double] {
        var changes = Array(repeating: Double.nan, count: y.count)
        var previous: Int?
        for i in y.indices {
            if let breaks, i < breaks.count, breaks[i] > 0.5 {
                previous = nil
                continue
            }
            guard !y[i].isNaN else { continue }
            if let p = previous, i - p <= 144 {
                let perStep = (y[i] - y[p]) / Double(i - p)
                for j in p + 1 ... i {
                    changes[j] = perStep
                }
            }
            previous = i
        }
        return changes
    }

    static func deviation(_ values: [Double]) -> Double {
        let known = values.filter { !$0.isNaN }
        guard known.count > 1 else { return 1 }
        let mean = known.reduce(0, +) / Double(known.count)
        let variance = known.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(known.count - 1)
        return max(variance.squareRoot(), 1e-6)
    }
}

/// Typical change by hour of week, by hour of day and overall: the median, so a burst of heavy use on one day does
/// not stand for every day at that hour.
private struct SeasonalProfile {
    let weekly: [Double?], daily: [Double?]
    let overall: Double
    /// A daylight-saving change shifts older buckets by an hour; per-date offsets if that shows.
    /// Seconds east of UTC, one value for the whole series: arithmetic instead of a calendar call per step.
    let utcOffset: Double
    /// Fewer samples than this in a bucket and the coarser one answers: two hours of 5-minute steps, so one past
    /// occurrence of an hour is not enough to stand for it.
    static let minimumSamples = 24

    init(changes: [Double], firstDate: Date, step: TimeInterval, utcOffset: Double) {
        self.utcOffset = utcOffset
        var weekly = [[Double]](repeating: [], count: 168), daily = [[Double]](repeating: [], count: 24)
        let start = firstDate.timeIntervalSince1970
        for (i, change) in changes.enumerated() where !change.isNaN {
            let (week, day) = hourBuckets(start + Double(i) * step, utcOffset: utcOffset)
            weekly[week].append(change)
            daily[day].append(change)
        }
        func typical(_ values: [Double]) -> Double? {
            values.count >= Self.minimumSamples ? median(values) : nil
        }
        self.weekly = weekly.map(typical)
        self.daily = daily.map(typical)
        overall = median(changes.filter { !$0.isNaN }) ?? 0
    }

    func change(at time: TimeInterval) -> Double {
        let (week, day) = hourBuckets(time, utcOffset: utcOffset)
        return weekly[week] ?? daily[day] ?? overall
    }
}

/// Inverse of the standard normal CDF (Acklam's rational approximation, error below 1.2e-9).
func normalQuantile(_ p: Double) -> Double {
    let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
             1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
    let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
             6.680131188771972e+01, -1.328068155288572e+01]
    let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
             -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
    let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
    let low = 0.02425
    if p < low {
        let q = (-2 * log(p)).squareRoot()
        return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
            ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    }
    if p > 1 - low {
        return -normalQuantile(1 - p)
    }
    let q = p - 0.5, r = q * q
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
        (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
}
