@testable import ForewarnKit
import Foundation
import Testing

struct ChargeLimitTests {
    /// powerd's archived policy list from a Mac with the limit set to 80% in System Settings › Battery.
    static let eightyPercent = Data(base64Encoded:
        "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEI"
            + "CVRyb290gAGoCwwSJCUpLzNVJG51bGzSDQ4PEVpOUy5vYmplY3RzViRjbGFzc6EQgAKAB9kTFBUOFhcYGRobHB0eHyAgHyNWcmVh"
            + "c29uVW93bmVyWHNvY2xpbWl0VWRyYWluWnRlcm1pbmF0ZWRebm9DaGFyZ2VUb0Z1bGxdaXNFbmRPZkNoYXJnZVV0b2tlboADEbUK"
            + "EFCABgkICAmABF8QEW1hbnVhbENoYXJnZUxpbWl00iYOJyhcTlMudXVpZGJ5dGVzTxAQ1O8QPcojSsyo1/ptc/LxsIAF0iorLC1a"
            + "JGNsYXNzbmFtZVgkY2xhc3Nlc1ZOU1VVSUSiLC5YTlNPYmplY3TSKiswMV8QEENoYXJnZUN0cmxQb2xpY3miMi5fEBBDaGFyZ2VD"
            + "dHJsUG9saWN50iorNDVeTlNNdXRhYmxlQXJyYXmjNDYuV05TQXJyYXkACAARABoAJAApADIANwBJAEwAUQBTAFwAYgBnAHIAeQB7"
            + "AH0AfwCSAJkAnwCoAK4AuQDIANYA3ADeAOEA4wDlAOYA5wDoAOkA6wD/AQQBEQEkASYBKwE2AT8BRgFJAVIBVwFqAW0BgAGFAZQB"
            + "mAAAAAAAAAIBAAAAAAAAADcAAAAAAAAAAAAAAAAAAAGg")!

    @Test func readsTheManualLimit() {
        #expect(ChargeLimit.parse(Self.eightyPercent) == 80)
    }

    @Test func anythingElseReadsAsNoLimit() {
        #expect(ChargeLimit.parse(Data("not an archive".utf8)) == nil)
        #expect(ChargeLimit.parse(Data()) == nil)
    }
}

struct BatteryStatusTests {
    @Test func minutesUntilChargedStopsAtTheLimit() {
        // 8400 mAh battery at 70%, 80% limit, charging at 4200 mA: 10% is 840 mAh, 12 minutes.
        let limited = BatteryStatus(
            percent: 70, isCharging: true, isOnAC: true, systemEstimateMinutes: 95,
            amperage: 4200, fullChargeCapacity: 8400, chargeLimit: 80
        )
        #expect(limited.minutesUntilCharged == 12)
        var unlimited = limited
        unlimited.chargeLimit = nil
        #expect(unlimited.minutesUntilCharged == 95) // macOS's time to full
        var unplugged = limited
        unplugged.isCharging = false
        #expect(unplugged.minutesUntilCharged == nil)
    }

    @Test func parsesAppleSiliconRegistry() throws {
        let status = try #require(BatteryStatus(
            powerSource: ["Current Capacity": 79, "Max Capacity": 100, "Is Charging": true,
                          "Power Source State": "AC Power", "Time to Full Charge": 30],
            registry: ["InstantAmperage": 3431, "Voltage": 12504, "CycleCount": 62,
                       "DesignCycleCount9C": 1000,
                       "BatteryData": [
                           "FullChargeCapacity": 8410,
                           "NominalChargeCapacity": 8692,
                           "DesignCapacity": 8579,
                       ]],
            chargeLimit: 80
        ))
        #expect(status.percent == 79 && status.isCharging && status.isOnAC)
        #expect(status.systemEstimateMinutes == 30)
        #expect(status.amperage == 3431 && status.voltage == 12504 && status.cycleCount == 62)
        #expect(status.fullChargeCapacity == 8410 && status.designCapacity == 8579)
        #expect(status.chargeLimit == 80)
        // Nominal over design is 101%: System Settings shows 100%.
        #expect(status.maximumCapacity == 100 && status.designCycleCount == 1000 && !status.serviceRecommended)
    }
}

struct PmsetLogTests {
    // swiftlint:disable line_length
    static let log = """
    2026-10-20 11:15:44 +0200 Assertions          \tSummary- [System: PrevIdle DeclUser] Using AC(Charge: 79)
    2026-10-20 11:16:10 +0200 Assertions          \tSummary- [System: PrevIdle] Using AC(Charge: 80)
    2026-10-20 11:40:00 +0200 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:68%) 37 secs
    2026-10-20 12:05:00 +0200 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to rtc/Maintenance Using BATT (Charge:67%) 2 secs
    2026-10-20 12:06:00 +0200 Kernel Idle sleep preventers: -None-
    """
    // swiftlint:enable line_length

    @Test func keepsTheLastValuePerFiveMinutes() {
        let readings = PmsetLog.parse(Self.log)
        let percents = readings.filter { $0.metric == .batteryPercent }
        #expect(percents.map(\.value) == [80, 68, 67]) // 11:15:44 and 11:16:10 share a bin
        #expect(readings.filter { $0.metric == .onAC }.map(\.value) == [1, 0, 0])
        #expect(percents.first?.date == Date(timeIntervalSince1970: 1_792_487_770)) // 09:16:10 UTC
    }
}

struct NetworkCountersTests {
    @Test func deltaSurvivesACounterReset() {
        #expect(NetworkCounters.delta(from: 1000, to: 1500) == 500)
        #expect(NetworkCounters.delta(from: 1000, to: 200) == 200) // interface came back from zero
    }

    @Test func readsThisMac() {
        #expect(!NetworkCounters.current().isEmpty) // at least lo0
    }
}
