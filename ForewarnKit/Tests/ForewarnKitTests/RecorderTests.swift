@testable import ForewarnKit
import Foundation
import Testing

struct StoreTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_400) // on the hour

    @Test func compactionRollsOldSamplesIntoHoursAndKeepsBatteryLonger() throws {
        let store = try Store(path: nil)
        let old = t0.addingTimeInterval(-40 * Store.day)
        try store.record([
            Reading(.diskFree, 10, at: old), Reading(.diskFree, 20, at: old + 600),
            Reading(.meteredBytes, 5, at: old), Reading(.meteredBytes, 7, at: old + 600),
            Reading(.batteryPercent, 50, at: old), Reading(.diskFree, 99, at: t0),
        ])
        try store.compact(now: t0)

        // Levels average, amounts add up, both into one hourly value.
        #expect(try store.series(.diskFree).map(\.value) == [15, 99])
        #expect(try store.series(.meteredBytes).map(\.value) == [12])
        // 40 days is inside the battery's 114-day full-resolution window.
        #expect(try store.series(.batteryPercent).map(\.date) == [old])
        // Compacting again changes nothing.
        try store.compact(now: t0)
        #expect(try store.series(.diskFree).map(\.value) == [15, 99])
    }

    @Test func eventsKeepTheirDetails() throws {
        let store = try Store(path: nil)
        try store.record(Event(.sleep, at: t0, ["blockers": "Docker"]))
        try store.record(Event(.wake, at: t0 + 60))
        #expect(try store.events(kind: .sleep) == [Event(.sleep, at: t0, ["blockers": "Docker"])])
        #expect(try store.events().count == 2)
        try store.deleteAll()
        #expect(try store.events().isEmpty)
    }

    @Test func exportsCSV() throws {
        let store = try Store(path: nil)
        try store.record([Reading(.batteryPercent, 64, at: t0)])
        try store.record(Event(.plugIn, at: t0, ["percent": "64"]))
        let lines = try store.exportCSV().split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("sample,batteryPercent,"))
        #expect(lines[2].hasSuffix(#""{""percent"":""64""}""#))
    }
}

/// A fake Mac whose readings the test changes between calls.
final class FakeMac: @unchecked Sendable {
    var battery: BatteryStatus? = BatteryStatus(percent: 80, isCharging: false, isOnAC: false)
    var counters: [String: UInt64] = [:]
    var joules = 0.0
    var log: String?

    var system: System {
        System(
            battery: { self.battery }, disk: { (100, 1000) }, network: { self.counters },
            selfEnergy: { self.joules }, sleepBlockers: { ["Docker"] }, pmsetLog: { self.log },
            folderUsage: { _ in nil }
        )
    }
}

struct RecorderTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func batteryEveryFiveMinutesOnBatteryAndTenOnPower() async throws {
        let mac = FakeMac()
        let recorder = try Recorder(store: Store(path: nil), system: mac.system)
        for minute in stride(from: 0, to: 30, by: 5) {
            try await recorder.tick(now: t0 + Double(minute * 60))
        }
        #expect(try recorder.store.series(.batteryPercent).count == 6)

        mac.battery?.isOnAC = true // plug-in: recorded at once, then every 10 minutes
        for minute in stride(from: 30, to: 60, by: 5) {
            try await recorder.tick(now: t0 + Double(minute * 60))
        }
        #expect(try recorder.store.series(.batteryPercent).count == 6 + 3)
        #expect(try recorder.store.events(kind: .plugIn).map(\.date) == [t0 + 1800])
    }

    @Test func unplugWhileTheAppWasClosedIsStillRecorded() async throws {
        let mac = FakeMac()
        mac.battery?.isOnAC = true
        let store = try Store(path: nil)
        try await Recorder(store: store, system: mac.system).tick(now: t0)
        mac.battery?.isOnAC = false // unplugged while the app was not running
        try await Recorder(store: store, system: mac.system).tick(now: t0 + 600)
        #expect(try store.events(kind: .unplug).map(\.details["noticedAtLaunch"]) == ["1"])
    }

    @Test func hourlyDiskAndOwnEnergyAsDeltas() async throws {
        let mac = FakeMac()
        let recorder = try Recorder(store: Store(path: nil), system: mac.system)
        mac.joules = 3
        try await recorder.tick(now: t0)
        mac.joules = 5
        try await recorder.tick(now: t0 + 300) // not an hour yet
        try await recorder.tick(now: t0 + 3600)
        #expect(try recorder.store.series(.selfEnergy).map(\.value) == [3, 2])
        #expect(try recorder.store.series(.diskFree).count == 2)
    }

    @Test func countsMeteredBytesOnlyOnTheExpensiveInterface() async throws {
        let mac = FakeMac()
        let recorder = try Recorder(store: Store(path: nil), system: mac.system)
        mac.counters = ["en0": 5000, "en8": 1000]
        try await recorder.meteredPathChanged(to: "en8", now: t0) // hotspot: start counting from here
        mac.counters = ["en0": 9000, "en8": 1600]
        try await recorder.tick(now: t0 + 300)
        mac.counters = ["en0": 9000, "en8": 200] // hotspot reconnected, counter restarted
        try await recorder.tick(now: t0 + 600)
        try await recorder.meteredPathChanged(to: nil, now: t0 + 700)
        mac.counters = ["en0": 20000, "en8": 900]
        try await recorder.tick(now: t0 + 900)
        #expect(try recorder.store.series(.meteredBytes).map(\.value) == [600, 200])
    }

    @Test func bootstrapsFromPmsetOnceWithPlugEvents() async throws {
        let mac = FakeMac()
        mac.log = PmsetLogTests.log
        let recorder = try Recorder(store: Store(path: nil), system: mac.system)
        try await recorder.bootstrapIfNeeded()
        try await recorder.bootstrapIfNeeded()
        #expect(try recorder.store.series(.batteryPercent).count == 3)
        #expect(try recorder.store.events(kind: .unplug).count == 1)
    }

    @Test func sleepRecordsWhoKeptTheMacAwake() async throws {
        let mac = FakeMac()
        let recorder = try Recorder(store: Store(path: nil), system: mac.system)
        try await recorder.willSleep(now: t0)
        mac.battery?.percent = 70
        try await recorder.didWake(now: t0 + 8 * 3600)
        let events = try recorder.store.events()
        #expect(events.map(\.kind) == [.sleep, .wake])
        #expect(events[0].details == ["blockers": "Docker", "percent": "80.0"])
        #expect(events[1].details["percent"] == "70.0")
    }
}
