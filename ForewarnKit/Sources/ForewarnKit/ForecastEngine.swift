/// Produces quantile forecasts for one metric. Implementations: BaselineEngine, TimestralEngine.
public protocol ForecastEngine: Sendable {
    func forecast(_ request: ForecastRequest) async throws -> QuantileForecast
}

public enum ForecastError: Error, Equatable {
    /// A horizon below zero steps.
    case negativeHorizon
}

public struct ForecastRequest: Sendable, Equatable {
    /// Target series on a regular grid; `.nan` marks a missing sample.
    public var target: [Double]
    /// One series per covariate, aligned with `target`.
    public var pastCovariates: [[Double]]
    /// One series per covariate (hour-of-day, day-of-week, on-AC), `horizon` steps long.
    public var futureCovariates: [[Double]]
    /// Steps to forecast. Engines throw `ForecastError.negativeHorizon` below zero and answer 21 empty rows at zero.
    public var horizon: Int

    public init(target: [Double], pastCovariates: [[Double]] = [], futureCovariates: [[Double]] = [], horizon: Int) {
        self.target = target
        self.pastCovariates = pastCovariates
        self.futureCovariates = futureCovariates
        self.horizon = horizon
    }
}

public struct QuantileForecast: Sendable, Equatable {
    /// 0.01, 0.05, 0.10 … 0.95, 0.99: 21 levels.
    public static let levels: [Double] = [0.01] + (1 ... 19).map { Double($0) / 20 } + [0.99]

    /// `values[level][step]`, one row per entry in `levels`.
    public let values: [[Double]]

    public init(values: [[Double]]) {
        precondition(values.count == Self.levels.count, "expected \(Self.levels.count) quantile rows")
        precondition(Set(values.map(\.count)).count <= 1, "all quantile rows must have the same horizon")
        self.values = values
    }

    public var horizon: Int { values.first?.count ?? 0 }

    /// The answer to a horizon of zero.
    static let empty = QuantileForecast(values: Array(repeating: [], count: levels.count))

    public var median: [Double] { values[10] }

    /// Row for an exact level from `levels`, or nil.
    public func quantile(_ level: Double) -> [Double]? {
        Self.levels.firstIndex { abs($0 - level) < 1e-9 }.map { values[$0] }
    }
}
