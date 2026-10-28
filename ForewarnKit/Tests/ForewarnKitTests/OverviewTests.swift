@testable import ForewarnKit
import Foundation
import Testing

struct OverviewTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every quantile row equal to `median`, so tests read the median directly.
    func forecast(_ median: [Double]) -> Overview.Forecast {
        Overview.Forecast(
            start: now,
            step: 300,
            quantiles: QuantileForecast(values: Array(repeating: median, count: 21))
        )
    }

    @Test func runsLowAtIsFirstStepBelowTenPercent() {
        let battery = Overview.Battery(
            percent: 20,
            isCharging: false,
            isOnAC: false,
            forecast: forecast([20, 15, 10, 9, 5])
        )
        #expect(battery.runsLowAt == now + 900)
    }

    @Test func attentionOnlyWhenLowComesBeforeUsualPlugIn() {
        var battery = Overview.Battery(percent: 20, isCharging: false, isOnAC: false, forecast: forecast([20, 9]))
        battery.usualPlugIn = now + 3600
        #expect(battery.runsLowBeforePlugIn)
        battery.usualPlugIn = now + 60
        #expect(!battery.runsLowBeforePlugIn)
        battery.usualPlugIn = now + 3600
        battery.isOnAC = true
        #expect(!battery.runsLowBeforePlugIn)
    }

    /// F6: two readings on power, both discharging past the noise floor, the latest recent; not above the limit.
    @Test func chargerShortfallNeedsTwoRecentDischargingReadingsOnPower() {
        let earlier = now - 600, latest = now - 60
        let onAC = [Reading(.onAC, 1, at: earlier), Reading(.onAC, 1, at: latest)]
        func status(_ percent: Double, limit: Int?) -> BatteryStatus {
            BatteryStatus(
                percent: percent, isCharging: false, isOnAC: true, fullChargeCapacity: 5000, chargeLimit: limit
            )
        }
        func detect(_ amps: [Double], onAC: [Reading] = onAC, percent: Double = 60, limit: Int? = nil,
                    at time: Date? = nil) -> Overview.ChargerShortfall?
        {
            let amperage = zip([earlier, latest], amps).map { Reading(.amperage, $1, at: $0) }
            return Overview.ChargerShortfall.detect(
                amperage: amperage, onAC: onAC, status: status(percent, limit: limit), adapterWatts: 30,
                now: time ?? now
            )
        }
        // 400 mA out of a 5000 mAh battery: 8% an hour.
        #expect(detect([-400, -400]) == .init(adapterWatts: 30, percentPerHour: 8))
        #expect(detect([-400, 120]) == nil) // charging again
        #expect(detect([-400, -20]) == nil) // noise
        #expect(detect([-400, -400], onAC: [Reading(.onAC, 0, at: earlier), Reading(.onAC, 1, at: latest)]) == nil)
        #expect(detect([-400, -400], percent: 90, limit: 80) == nil) // above the limit: macOS's own doing
        #expect(detect([-400, -400], at: now + 3600) == nil) // stale
        let one = [Reading(.amperage, -400, at: latest)]
        #expect(Overview.ChargerShortfall.detect(
            amperage: one, onAC: onAC, status: status(60, limit: nil), adapterWatts: nil, now: now
        ) == nil)
        var overview = Overview(battery: .init(percent: 60, isCharging: false, isOnAC: true))
        #expect(!overview.needsAttention)
        overview.battery?.shortfall = detect([-400, -400])
        #expect(overview.needsAttention)
    }

    @Test func pointsCarryBandAndMedianOnTheGrid() {
        let rows = (0 ..< 21).map { q in [Double(q), Double(q) + 1] }
        let f = Overview.Forecast(start: now, step: 300, quantiles: QuantileForecast(values: rows))
        #expect(f.points.map(\.date) == [now, now + 300])
        #expect(f.points[1].low == 3) // q0.10 is row 2
        #expect(f.points[1].median == 11)
        #expect(f.points[1].high == 19) // q0.90 is row 18
    }

    @Test func sampleStatesMatchTheirName() {
        #expect(Overview.sample(now: now, state: .risky).needsAttention)
        #expect(!Overview.sample(now: now, state: .fine).needsAttention)
        let charging = Overview.sample(now: now, state: .charging)
        #expect(charging.battery?.isCharging == true && !charging.needsAttention)
        #expect(charging.battery?.history.last?.date == now)
        #expect(Overview.sample(now: now, state: .learning).battery?.forecast == nil)
        #expect(Overview.sample(now: now, state: .plugged).battery?.isOnAC == true)
        #expect(Overview.sample(now: now, state: .plugged).battery?.isHeldAtLimit == true)
    }
}
