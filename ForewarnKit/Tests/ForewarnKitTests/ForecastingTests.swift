@testable import ForewarnKit
import Foundation
import Testing

struct BaselineEngineTests {
    let now = Date(timeIntervalSince1970: 1_760_000_400)

    /// Discharging 1% per step for a few days, with a top-up on power every 100 steps.
    func sawtooth(count: Int) -> (target: [Double], onAC: [Double]) {
        var target: [Double] = [], onAC: [Double] = []
        for i in 0 ..< count {
            let charging = i % 100 >= 90
            onAC.append(charging ? 1 : 0)
            target.append(charging ? .nan : 100 - Double(i % 100))
        }
        return (target, onAC)
    }

    @Test func followsTheDrainAndIgnoresTopUps() async throws {
        let (target, onAC) = sawtooth(count: 1000)
        let engine = BaselineEngine(step: 300, nextStepDate: now)
        let forecast = try await engine.forecast(ForecastRequest(target: target, pastCovariates: [onAC], horizon: 20))
        let last = try #require(target.last { !$0.isNaN })
        // Each step loses 1%: the top-ups behind the breaks never count as gains.
        for (k, median) in forecast.median.enumerated() {
            #expect(abs(median - (last - Double(k + 1))) < 0.01)
        }
    }

    @Test func quantilesAreOrderedAndWidenWithTheHorizon() async throws {
        var noisy = sawtooth(count: 1000)
        for i in noisy.target.indices where !noisy.target[i].isNaN {
            noisy.target[i] += sin(Double(i) * 1.7) * 2
        }
        let forecast = try await BaselineEngine(step: 300, nextStepDate: now)
            .forecast(ForecastRequest(target: noisy.target, pastCovariates: [noisy.onAC], horizon: 30))
        for k in 0 ..< 30 {
            let column = forecast.values.map { $0[k] }
            #expect(column == column.sorted())
        }
        let width = { (k: Int) in forecast.values[20][k] - forecast.values[0][k] }
        #expect(width(29) >= width(0))
    }

    @Test func shortHistoryStillAnswers() async throws {
        let forecast = try await BaselineEngine(step: 300, nextStepDate: now)
            .forecast(ForecastRequest(target: [80, 79.5, 79], horizon: 5))
        #expect(forecast.horizon == 5)
        #expect(forecast.median.allSatisfy { $0 < 79 })
        #expect(forecast.values[0][4] < forecast.values[20][4])
    }

    @Test func normalQuantileMatchesKnownValues() {
        #expect(abs(normalQuantile(0.5)) < 1e-9)
        #expect(abs(normalQuantile(0.975) - 1.959964) < 1e-5)
        #expect(abs(normalQuantile(0.01) + 2.326348) < 1e-5)
    }
}

/// Knows the future: what a backtest scores as perfect.
struct OracleEngine: ForecastEngine {
    let truth: [Double]
    func forecast(_ request: ForecastRequest) async throws -> QuantileForecast {
        let start = request.target.count
        let future = (start ..< start + request.horizon).map { truth[$0] }
        return QuantileForecast(values: Array(repeating: future, count: 21))
    }
}

struct BacktestTests {
    @Test func perfectForecastScoresZeroAndTheBaselineBeatsNaive() async throws {
        let truth = (0 ..< 600).map { 100 - Double($0) * 0.1 }
        let perfect = try #require(try await Backtest.run(
            target: truth, horizon: 24, minimumHistory: 100, spacing: 24
        ) { _ in OracleEngine(truth: truth) })
        #expect(perfect.wql == 0 && perfect.relativeMAE == 0)
        #expect(perfect.origins == (600 - 24 - 100 + 23) / 24)

        let baseline = try #require(try await Backtest.run(
            target: truth, horizon: 24, minimumHistory: 100, spacing: 24
        ) { _ in BaselineEngine(step: 300, nextStepDate: .now) })
        #expect(baseline.relativeMAE < 1) // a steady drain beats "no change"
    }

    @Test func timestralMustBeatTheBaselineOnBands() {
        let good = Backtest.Score(relativeMAE: 0.5, wql: 0.01, origins: 10)
        let worse = Backtest.Score(relativeMAE: 0.4, wql: 0.02, origins: 10)
        #expect(EngineChoice.decide(baseline: worse, timestral: good, at: .now).engine == .timestral)
        #expect(EngineChoice.decide(baseline: good, timestral: worse, at: .now).engine == .baseline)
        #expect(EngineChoice.decide(baseline: good, timestral: nil, at: .now).engine == .baseline)
    }
}

struct BatteryForecasterTests {
    let now = Date(timeIntervalSince1970: 1_760_000_400)

    @Test func gridBinsReadingsAndMasksPower() {
        let series = BatteryForecaster.grid(
            levels: [
                Reading(.batteryPercent, 90, at: now - 900), Reading(.batteryPercent, 88, at: now - 610),
                Reading(.batteryPercent, 85, at: now - 30), Reading(.batteryPercent, 50, at: now - 300),
            ].sorted { $0.date < $1.date },
            power: [Reading(.onAC, 0, at: now - 900), Reading(.onAC, 1, at: now - 300), Reading(.onAC, 0, at: now)],
            end: now
        )
        // Bins of 5 minutes ending now: (−20, −15], (−15, −10], (−10, −5], (−5, 0] minutes.
        #expect(series.target.count == 4)
        #expect(series.target[0] == 90)
        #expect(series.target[1] == 88)
        #expect(series.target[2].isNaN) // on power: masked
        #expect(series.target[3] == 85)
        #expect(series.onAC == [0, 0, 1, 0])
        #expect(series.span == 900)
    }

    /// A store with `days` of discharge at 2% an hour, recharged to 100% every evening.
    func store(days: Double) throws -> Store {
        let store = try Store(path: nil)
        var readings: [Reading] = []
        for i in 0 ..< Int(days * 288) {
            let date = now.addingTimeInterval(-Double(Int(days * 288) - i) * 300)
            let hour = i % 288 / 12
            let onAC = hour >= 20
            readings.append(Reading(.onAC, onAC ? 1 : 0, at: date))
            readings.append(Reading(.batteryPercent, onAC ? 100 : 100 - Double(i % 288) / 6, at: date))
        }
        try store.record(readings)
        return store
    }

    @Test func noForecastOnPowerOrBeforeThreeDays() async throws {
        let battery = BatteryStatus(percent: 70, isCharging: false, isOnAC: false)
        let young = try BatteryForecaster(store: store(days: 2))
        #expect(try await young.update(battery: battery, now: now) == nil)

        let forecaster = try BatteryForecaster(store: store(days: 5))
        #expect(try await forecaster.update(battery: battery, now: now) != nil)
        var plugged = battery
        plugged.isOnAC = true
        #expect(try await forecaster.update(battery: plugged, now: now) == nil)
    }

    @Test func rerunsOnlyWhenTheLevelLeavesTheBand() async throws {
        let forecaster = try BatteryForecaster(store: store(days: 5))
        let first = try #require(try await forecaster.update(
            battery: BatteryStatus(percent: 70, isCharging: false, isOnAC: false), now: now
        ))
        #expect(first.start == now && first.quantiles.median[0] == 70)
        #expect(first.quantiles.median[12] < 70) // draining

        // 20 minutes later, on track: same forecast.
        let expected = first.quantiles.median[4]
        let onTrack = try await forecaster.update(
            battery: BatteryStatus(percent: expected, isCharging: false, isOnAC: false), now: now + 1200
        )
        #expect(onTrack == first)

        // Way off the band: a new forecast from the new level.
        let off = try await forecaster.update(
            battery: BatteryStatus(percent: 30, isCharging: false, isOnAC: false), now: now + 1500
        )
        #expect(off?.start == now + 1500 && off?.quantiles.median[0] == 30)
    }

    @Test func weeklyChoiceKeepsTheBaselineWithoutTheModel() async throws {
        let store = try store(days: 5)
        let forecaster = BatteryForecaster(store: store)
        try await forecaster.evaluateIfDue(onAC: false, now: now)
        #expect(try store.events(kind: .engineChoice).isEmpty) // only on power
        try await forecaster.evaluateIfDue(onAC: true, now: now)
        try await forecaster.evaluateIfDue(onAC: true, now: now + 3600) // not due again for a week
        let events = try store.events(kind: .engineChoice)
        #expect(events.count == 1)
        #expect(events.first?.details["engine"] == "baseline")
        #expect(events.first?.details["baseline.wql"] != nil)

        // The model shows up: checked again at once, with both engines.
        let withModel = BatteryForecaster(store: store) { OracleEngine(truth: Array(repeating: 50, count: 5000)) }
        try await withModel.evaluateIfDue(onAC: true, now: now + 7200)
        let latest = try #require(try store.events(kind: .engineChoice).last)
        #expect(latest.details["timestral.wql"] != nil)
        try await withModel.evaluateIfDue(onAC: true, now: now + 9000) // and then not again for a week
        #expect(try store.events(kind: .engineChoice).count == 2)
    }

    @Test func concurrentChecksRunOnce() async throws {
        let store = try store(days: 5)
        let forecaster = BatteryForecaster(store: store)
        async let a: Void = forecaster.evaluateIfDue(onAC: true, now: now)
        async let b: Void = forecaster.evaluateIfDue(onAC: true, now: now)
        async let c: Void = forecaster.evaluateIfDue(onAC: true, now: now)
        _ = try await (a, b, c)
        #expect(try store.events(kind: .engineChoice).count == 1)
    }
}

struct TrendTests {
    let now = Date(timeIntervalSince1970: 1_760_000_400)

    @Test func diskFillsWhereTheLineCrossesZero() {
        // 100 GB free, losing 2 GB a day for 10 days: 80 GB left, 40 days to go.
        let free = (0 ... 10).map { Reading(.diskFree, 100e9 - Double($0) * 2e9, at: now - Double(10 - $0) * 86400) }
        let full = try? #require(DiskTrend.fullDate(free: free, now: now))
        #expect(abs((full ?? .distantPast).timeIntervalSince(now) - 40 * 86400) < 60)
        #expect(DiskTrend.fullDate(free: Array(free.suffix(3)), now: now) == nil) // under a week
        let growing = free.map { Reading(.diskFree, 200e9 - $0.value, at: $0.date) }
        #expect(DiskTrend.fullDate(free: growing, now: now) == nil)
    }

    @Test func meteredPaceAndPeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let mid = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let period = MeteredPace.period(resetDay: 5, now: mid, calendar: calendar)
        #expect(period.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        #expect(period.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        // 15.5 days in, 15.5 GB used: 1 GB a day reaches 20 GB on day 20, before the reset.
        let out = try #require(MeteredPace.runsOutAt(used: 15.5e9, limit: 20e9, period: period, now: mid))
        #expect(abs(out.timeIntervalSince(period.start) - 20 * 86400) < 1)
        #expect(MeteredPace.runsOutAt(used: 5e9, limit: 20e9, period: period, now: mid) == nil)
    }
}

/// Backtests on a week of battery history (`ReplayTests.week`).
struct HistoryBacktestTests {
    /// Prints the scores; fails only if the baseline stops beating "no change".
    @Test func baselineBacktestOnAWeek() async throws {
        let readings = ReplayTests.week()
        let end = try #require(readings.map(\.date).max())
        let series = BatteryForecaster.grid(
            levels: readings.filter { $0.metric == .batteryPercent },
            power: readings.filter { $0.metric == .onAC }, end: end
        )
        let count = series.target.count
        let score = try #require(try await Backtest.run(
            target: series.target, breaks: series.onAC, horizon: BatteryForecaster.horizon,
            minimumHistory: 288, spacing: 6
        ) { origin in
            BaselineEngine(step: 300, nextStepDate: end.addingTimeInterval(Double(origin + 2 - count) * 300))
        })
        print(
            "baseline on a week: steps \(count), origins \(score.origins),",
            "relative MAE \(score.relativeMAE), WQL \(score.wql)"
        )
        #expect(score.origins > 0 && score.relativeMAE < 1)
    }

    /// Same origins with the installed Timestral model (`make model`); skipped without it.
    @Test(.enabled(if: TimestralEngine.installed() != nil, "Timestral model not installed: make model"))
    func timestralBacktestOnAWeek() async throws {
        let readings = ReplayTests.week()
        let end = try #require(readings.map(\.date).max())
        let series = BatteryForecaster.grid(
            levels: readings.filter { $0.metric == .batteryPercent },
            power: readings.filter { $0.metric == .onAC }, end: end
        )
        let engine = try #require(TimestralEngine.installed())
        let score = try #require(try await Backtest.run(
            target: series.target, breaks: series.onAC, horizon: BatteryForecaster.horizon,
            minimumHistory: 288, spacing: 6
        ) { _ in engine })
        print("timestral on a week: origins \(score.origins),", "relative MAE \(score.relativeMAE), WQL \(score.wql)")
        #expect(score.origins > 0)
    }
}
