import Foundation

/// F1's forecast: battery level for the next 12 hours, assuming the Mac stays on battery.
///
/// When it runs: once when a discharge session starts, then only when the measured level leaves the
/// p10–p90 band or half the horizon has passed, and never twice within 15 minutes. On power there is no forecast
/// and the Timestral model, if it was loaded, is let go.
public actor BatteryForecaster {
    public static let step = 300.0
    public static let horizon = 144
    /// The Timestral context: 114 days of 5-minute steps.
    public static let context = 32768
    /// No battery forecast before three days of history.
    static let minimumHistory = 3 * 86400.0
    static let minimumInterval = 900.0

    private let store: Store
    private let timeZone: TimeZone
    private let loadTimestral: @Sendable () -> (any ForecastEngine)?
    private var timestral: (any ForecastEngine)?
    private var current: Overview.Forecast?
    /// When the last run started, whatever came of it: no forecast, a failure or a forecast all wait out
    /// `minimumInterval` before the next one.
    private var lastAttempt = Date.distantPast
    /// The actor takes other calls while one awaits an engine: these keep a second run from starting meanwhile.
    private var forecasting = false, evaluating = false
    /// Changes when a discharge session ends (on power, no battery, data deleted): a run that started before then
    /// must not bring its forecast back.
    private var session = 0

    /// `loadTimestral` returns the engine when the model is installed, `nil` otherwise: the baseline then answers.
    public init(
        store: Store, timeZone: TimeZone = .current,
        loadTimestral: @escaping @Sendable () -> (any ForecastEngine)? = { nil }
    ) {
        self.store = store
        self.timeZone = timeZone
        self.loadTimestral = loadTimestral
    }

    /// Called after each battery reading; returns the forecast to show, if any.
    public func update(battery: BatteryStatus?, now: Date = .now) async throws -> Overview.Forecast? {
        guard let battery, !battery.isOnAC else {
            endSession()
            return nil
        }
        guard !forecasting, now.timeIntervalSince(lastAttempt) >= Self.minimumInterval,
              current.map({ needsRerun($0, level: battery.percent, now: now) }) ?? true else { return current }
        forecasting = true
        defer { forecasting = false }
        lastAttempt = now
        let started = session
        let forecast = try await run(level: battery.percent, now: now)
        guard session == started else { return nil } // plugged in (or reset) while it ran
        current = forecast
        return current
    }

    /// Everything was deleted (Settings › Privacy): no forecast from the old history, and the next one runs at once.
    public func reset() {
        endSession()
        lastAttempt = .distantPast
    }

    private func endSession() {
        current = nil
        timestral = nil
        session += 1
    }

    private func needsRerun(_ forecast: Overview.Forecast, level: Double, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(forecast.start)
        let index = Int((elapsed / forecast.step).rounded())
        guard index < forecast.quantiles.horizon / 2,
              let low = forecast.quantiles.quantile(0.1)?[index],
              let high = forecast.quantiles.quantile(0.9)?[index] else { return true }
        return !(low ... high).contains(level)
    }

    private func run(level: Double, now: Date) async throws -> Overview.Forecast? {
        var series = try Self.grid(store: store, end: now)
        guard series.hasHistory(Self.minimumHistory) else { return nil }
        series.target[series.target.count - 1] = level
        let request = ForecastRequest(target: series.target, pastCovariates: [series.onAC], horizon: Self.horizon)
        let engine: any ForecastEngine
        if try EngineChoice.latest(for: .batteryPercent, in: store)?.engine == .timestral,
           let model = timestral ?? loadTimestral()
        {
            timestral = model
            engine = model
        } else {
            engine = BaselineEngine(
                step: Self.step,
                nextStepDate: now.addingTimeInterval(Self.step),
                timeZone: timeZone
            )
        }
        let forecast = try await engine.forecast(request)
        // Start at the measured level (step 0, now) so the chart continues from it; a battery stays in 0…100.
        let rows = forecast.values.map { [level] + $0.map { min(max($0, 0), 100) } }
        return Overview.Forecast(start: now, step: Self.step, quantiles: QuantileForecast(values: rows))
    }

    // MARK: Engine choice

    /// Weekly, on power: backtest both engines on this Mac's history and store the winner.
    /// Without the Timestral model the baseline is recorded alone, which keeps it the choice; once the model is
    /// installed the next check runs at once instead of waiting out the week.
    public func evaluateIfDue(onAC: Bool, now: Date = .now) async throws {
        guard onAC, !evaluating else { return }
        let model = loadTimestral()
        if let last = try EngineChoice.latest(for: .batteryPercent, in: store),
           now.timeIntervalSince(last.date) < 7 * 86400, last.comparedTimestral || model == nil
        {
            return
        }
        evaluating = true
        defer { evaluating = false }
        let series = try Self.grid(store: store, end: now)
        guard series.hasHistory(Self.minimumHistory) else { return }
        func score(_ make: @escaping @Sendable (Int) -> any ForecastEngine) async throws -> Backtest.Score? {
            try await Backtest.run(
                target: series.target, breaks: series.onAC, horizon: Self.horizon,
                minimumHistory: Int(Self.minimumHistory / Self.step), spacing: 24, makeEngine: make
            )
        }
        let count = series.target.count, timeZone = timeZone
        let baseline = try await score { origin in
            BaselineEngine(
                step: Self.step,
                nextStepDate: now.addingTimeInterval(Double(origin + 2 - count) * Self.step),
                timeZone: timeZone
            )
        }
        var timestralScore: Backtest.Score?
        if let model {
            timestralScore = try await score { _ in model }
        }
        let choice = EngineChoice.decide(baseline: baseline, timestral: timestralScore, at: now)
        try store.record(choice.event(metric: .batteryPercent))
    }

    // MARK: Grid

    struct Series {
        /// Battery level on the 5-minute grid ending now; `.nan` where unknown or on power.
        var target: [Double]
        /// 1 where on power (carried forward from the last reading), else 0.
        var onAC: [Double]
        /// Time from the first known level to now.
        var span: TimeInterval

        func hasHistory(_ seconds: TimeInterval) -> Bool {
            span >= seconds && target.contains { !$0.isNaN }
        }
    }

    static func grid(store: Store, end: Date) throws -> Series {
        let start = end.addingTimeInterval(-Double(context) * step)
        return try grid(
            levels: store.series(.batteryPercent, since: start),
            power: store.series(.onAC, since: start),
            end: end
        )
    }

    /// Bin `i` of `count` covers `(end − (count − i)·step, end − (count − 1 − i)·step]`; the last reading in a bin
    /// wins. The grid starts at the first reading, so a short history makes a short series.
    static func grid(levels: [Reading], power: [Reading], end: Date) -> Series {
        guard let first = (levels + power).map(\.date).min() else { return Series(target: [], onAC: [], span: 0) }
        let count = min(context, Int((end.timeIntervalSince(first) / step).rounded(.down)) + 1)
        func bin(_ date: Date) -> Int? {
            let i = count - 1 - Int((end.timeIntervalSince(date) / step).rounded(.down))
            return (0 ..< count).contains(i) ? i : nil
        }
        var target = [Double](repeating: .nan, count: count)
        var onAC = [Double](repeating: .nan, count: count)
        for r in levels {
            if let i = bin(r.date) {
                target[i] = r.value
            }
        }
        for r in power {
            if let i = bin(r.date) {
                onAC[i] = r.value
            }
        }
        var state = 0.0
        for i in onAC.indices {
            if onAC[i].isNaN {
                onAC[i] = state
            } else {
                state = onAC[i]
            }
            if onAC[i] > 0.5 {
                target[i] = .nan
            }
        }
        return Series(target: target, onAC: onAC, span: end.timeIntervalSince(first))
    }
}
