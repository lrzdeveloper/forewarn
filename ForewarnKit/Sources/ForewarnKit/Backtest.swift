import Foundation

/// Rolling-origin evaluation on recorded data: forecast from many past moments using only what was
/// known then, and score against what happened.
public enum Backtest {
    public struct Score: Sendable, Equatable {
        /// Mean absolute error of the median over that of "no change" (the last level held) on the same points.
        /// Below 1 beats "no change". MASE, which scales by the one-step naive error; on a 5-minute
        /// grid that error is tiny and the ratio meaningless for a 12-hour forecast, so the scale is the horizon's.
        public var relativeMAE: Double
        /// Weighted quantile loss over the 21 levels: 0 is perfect, lower is better.
        public var wql: Double
        public var origins: Int
    }

    /// - Parameters:
    ///   - target: the series on its grid, `.nan` where missing.
    ///   - breaks: passed on as the engine's first past covariate (see `BaselineEngine`). Scoring stops at the first
    ///     break after an origin: the battery forecast assumes the Mac stays on battery, so what follows a
    ///     plug-in is a different question.
    ///   - makeEngine: the engine for an origin, given the date of the step after it.
    ///   - minimumHistory: steps an origin needs behind it.
    ///   - spacing: steps between origins.
    public static func run(
        target: [Double], breaks: [Double]? = nil, horizon: Int, minimumHistory: Int, spacing: Int,
        minimumScored: Int = 12,
        makeEngine: @Sendable (_ originIndex: Int) -> any ForecastEngine
    ) async throws -> Score? {
        var absoluteError = 0.0, naiveError = 0.0, quantileLoss = 0.0, scale = 0.0
        var points = 0, origins = 0
        for origin in stride(from: minimumHistory, to: target.count - horizon, by: spacing) {
            let firstBreak = breaks.flatMap { b in (origin + 1 ... origin + horizon).first { b[$0] > 0.5 } }
            let future = target[(origin + 1) ..< (firstBreak ?? origin + horizon + 1)]
            // Score only origins with a known starting level and at least an hour of what followed.
            guard !target[origin].isNaN, future.count(where: { !$0.isNaN }) >= minimumScored else { continue }
            let request = ForecastRequest(
                target: Array(target[...origin]),
                pastCovariates: breaks.map { [Array($0[...origin])] } ?? [],
                horizon: horizon
            )
            let forecast = try await makeEngine(origin).forecast(request)
            origins += 1
            for (k, actual) in future.enumerated() where !actual.isNaN {
                absoluteError += abs(actual - forecast.median[k])
                naiveError += abs(actual - target[origin])
                for (row, level) in QuantileForecast.levels.enumerated() {
                    let error = actual - forecast.values[row][k]
                    quantileLoss += max(level * error, (level - 1) * error)
                }
                scale += abs(actual)
                points += 1
            }
        }
        guard points > 0, scale > 0 else { return nil }
        return Score(
            relativeMAE: absoluteError / max(naiveError, 1e-9),
            wql: 2 * quantileLoss / (Double(QuantileForecast.levels.count) * scale),
            origins: origins
        )
    }
}

/// Which engine forecasts a metric on this Mac: Timestral only if it beats the baseline on this
/// Mac's own history. Stored as an event so the debug window shows it and the next check knows when it ran.
public struct EngineChoice: Sendable, Equatable {
    public enum Engine: String, Sendable {
        case baseline, timestral
    }

    public var engine: Engine
    public var date: Date
    /// Whether Timestral took part, or the model was missing.
    public var comparedTimestral = false
    public var baseline: Backtest.Score?
    public var timestral: Backtest.Score?

    /// Timestral wins only with a lower weighted quantile loss: the bands are what the warnings use.
    public static func decide(baseline: Backtest.Score?, timestral: Backtest.Score?, at date: Date) -> EngineChoice {
        let winner: Engine = if let t = timestral, let b = baseline, t.wql < b.wql {
            .timestral
        } else {
            .baseline
        }
        return EngineChoice(
            engine: winner, date: date, comparedTimestral: timestral != nil, baseline: baseline, timestral: timestral
        )
    }

    func event(metric: Metric) -> Event {
        var details = ["metric": metric.rawValue, "engine": engine.rawValue]
        for (name, score) in [("baseline", baseline), ("timestral", timestral)] {
            guard let score else { continue }
            details["\(name).wql"] = String(format: "%.4f", score.wql)
            details["\(name).relativeMAE"] = String(format: "%.3f", score.relativeMAE)
            details["\(name).origins"] = String(score.origins)
        }
        return Event(.engineChoice, at: date, details)
    }

    static func latest(for metric: Metric, in store: Store) throws -> EngineChoice? {
        guard let event = try store.events(kind: .engineChoice)
            .last(where: { $0.details["metric"] == metric.rawValue }),
            let engine = event.details["engine"].flatMap(Engine.init) else { return nil }
        return EngineChoice(engine: engine, date: event.date, comparedTimestral: event.details["timestral.wql"] != nil)
    }
}
