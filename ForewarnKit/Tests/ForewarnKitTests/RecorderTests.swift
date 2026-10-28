@testable import ForewarnKit
import Foundation
import SQLite3
import Testing

/// A store in a temporary file whose inserts into `table` can be made to fail, as on a full disk: another connection
/// adds a trigger, which SQLite applies to every connection.
struct FailingStore {
    let path = FileManager.default.temporaryDirectory.appending(path: "forewarn-\(UUID().uuidString).sqlite").path
    let store: Store

    init() throws {
        store = try Store(path: path)
    }

    func failInserts(into table: String, _ fail: Bool = true) {
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        let sql = fail
            ? "CREATE TRIGGER fail_\(table) BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT, 'disk full'); END"
            : "DROP TRIGGER fail_\(table)"
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }
}

struct StoreTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_400) // on the hour

    @Test func compactionRollsOldSamplesIntoHoursAndKeepsBatteryLonger() throws {
        let store = try Store(path: nil)
        let old = t0.addingTimeInterval(-40 * Store.day)
        try store.record([
            Reading(.diskFree, 10, at: old), Reading(.diskFree, 20, at: old + 600),
            Reading(.selfEnergy, 5, at: old), Reading(.selfEnergy, 7, at: old + 600),
            Reading(.batteryPercent, 50, at: old), Reading(.diskFree, 99, at: t0),
        ])
        try store.compact(now: t0)

        // Levels average, amounts add up, both into one hourly value.
        #expect(try store.series(.diskFree).map(\.value) == [15, 99])
        #expect(try store.series(.selfEnergy).map(\.value) == [12])
        // 40 days is inside the battery's 114-day full-resolution window.
        #expect(try store.series(.batteryPercent).map(\.date) == [old])
        // Compacting again changes nothing.
        try store.compact(now: t0)
        #expect(try store.series(.diskFree).map(\.value) == [15, 99])
    }

    @Test func levelsRollUpWeightedByTheirReadings() throws {
        let store = try Store(path: nil)
        let old = t0.addingTimeInterval(-400 * Store.day)
        // One hour with a single 0, the next with nine 100s: the day averages the ten readings, 90, not 50.
        try store.record([Reading(.diskFree, 0, at: old)] + (0 ..< 9).map {
            Reading(.diskFree, 100, at: old + 3600 + Double($0) * 300)
        })
        try store.compact(now: old + 40 * Store.day) // raw into hours
        try store.compact(now: t0) // hours into a day
        #expect(try store.series(.diskFree).map(\.value) == [90])
    }

    @Test func aLateReadingMergesIntoItsCompactedHour() throws {
        let store = try Store(path: nil)
        let old = t0.addingTimeInterval(-40 * Store.day)
        try store.record([Reading(.diskFree, 10, at: old), Reading(.selfEnergy, 5, at: old)])
        try store.compact(now: t0)
        try store.record([Reading(.diskFree, 40, at: old + 60), Reading(.selfEnergy, 7, at: old + 60)])
        try store.compact(now: t0)
        #expect(try store.series(.diskFree).map(\.value) == [25])
        #expect(try store.series(.selfEnergy).map(\.value) == [12])
    }

    @Test func aSumDoesNotShrinkWhenItsHourIsCompacted() throws {
        let store = try Store(path: nil)
        let old = t0.addingTimeInterval(-40 * Store.day)
        try store.record([Reading(.selfEnergy, 5, at: old + 600), Reading(.selfEnergy, 7, at: old + 1200)])
        let before = try store.sum(.selfEnergy, since: old + 300)
        try store.compact(now: t0) // the hour starts before `since`: it still counts
        #expect(before == 12)
        #expect(try store.sum(.selfEnergy, since: old + 300) == 12)
        #expect(try store.series(.selfEnergy, since: old + 300).count == 1)
        #expect(try store.sum(.selfEnergy, since: old + 3600) == 0)
    }

    @Test func meteredBytesStayExactForABillingPeriod() throws {
        let store = try Store(path: nil)
        let old = t0.addingTimeInterval(-40 * Store.day)
        try store.record([Reading(.meteredBytes, 5, at: old + 600), Reading(.meteredBytes, 7, at: old + 1200)])
        try store.compact(now: t0)
        #expect(try store.series(.meteredBytes).map(\.value) == [5, 7])
    }

    @Test func upgradeMergesTheDuplicateBucketsOf1_0() throws {
        // A 1.0 database: schema v1 and v2, and an hour compacted twice after a late reading.
        let path = FileManager.default.temporaryDirectory.appending(path: "forewarn-\(UUID().uuidString).sqlite").path
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        INSERT INTO grdb_migrations VALUES ('v1'), ('v2 notifications');
        CREATE TABLE samples (metric TEXT NOT NULL, ts DOUBLE NOT NULL, value DOUBLE NOT NULL,
                              resolution INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX samples_metric_ts ON samples (metric, ts);
        CREATE TABLE events (kind TEXT NOT NULL, ts DOUBLE NOT NULL, details TEXT NOT NULL);
        CREATE TABLE notifications (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, ts DOUBLE NOT NULL,
                                    action_taken TEXT, details TEXT NOT NULL);
        INSERT INTO samples VALUES ('diskFree', 3600, 10, 3600), ('diskFree', 3600, 30, 3600),
                                   ('selfEnergy', 3600, 5, 3600), ('selfEnergy', 3600, 7, 3600),
                                   ('diskFree', 7200, 50, 3600), ('diskFree', 7200, 1, 0);
        """, nil, nil, nil)
        sqlite3_close(db)
        let store = try Store(path: path)
        #expect(try store.series(.diskFree).map(\.value) == [20, 50, 1])
        #expect(try store.series(.selfEnergy).map(\.value) == [12])
    }

    @Test func eventIdsNeverCollide() {
        let a = Event(.folderSize, at: t0, ["a": "b|c=d"]), b = Event(.folderSize, at: t0, ["a": "b", "c": "d"])
        #expect(a.id != b.id)
        #expect(a.id == Event(.folderSize, at: t0, ["a": "b|c=d"]).id)
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
        try await recorder.meteredPathChanged(to: ["en8"], now: t0) // hotspot: start counting from here
        mac.counters = ["en0": 9000, "en8": 1600]
        try await recorder.tick(now: t0 + 300)
        mac.counters = ["en0": 9000, "en8": 200] // hotspot reconnected, counter restarted
        try await recorder.tick(now: t0 + 600)
        try await recorder.meteredPathChanged(to: [], now: t0 + 700)
        mac.counters = ["en0": 20000, "en8": 900]
        try await recorder.tick(now: t0 + 900)
        #expect(try recorder.store.series(.meteredBytes).map(\.value) == [600, 200])
    }

    @Test func meteredBytesNotStoredAreCountedNextTime() async throws {
        let mac = FakeMac(), failing = try FailingStore()
        let recorder = Recorder(store: failing.store, system: mac.system)
        mac.counters = ["en8": 1000]
        try await recorder.meteredPathChanged(to: ["en8"], now: t0)
        mac.counters = ["en8": 1600]
        failing.failInserts(into: "samples")
        await #expect(throws: (any Error).self) { try await recorder.tick(now: t0 + 300) }
        failing.failInserts(into: "samples", false)
        mac.counters = ["en8": 1700]
        try await recorder.tick(now: t0 + 600)
        #expect(try failing.store.series(.meteredBytes).map(\.value) == [700])
    }

    @Test func ownEnergyNotStoredIsCountedNextTime() async throws {
        let mac = FakeMac(), failing = try FailingStore()
        let recorder = Recorder(store: failing.store, system: mac.system)
        mac.joules = 3
        failing.failInserts(into: "samples")
        await #expect(throws: (any Error).self) { try await recorder.tick(now: t0) }
        failing.failInserts(into: "samples", false)
        mac.joules = 5
        try await recorder.tick(now: t0 + 300)
        #expect(try failing.store.series(.selfEnergy).map(\.value) == [5])
    }

    @Test func aPlugInNotStoredIsRecordedOnTheNextCall() async throws {
        let mac = FakeMac(), failing = try FailingStore()
        let recorder = Recorder(store: failing.store, system: mac.system)
        try await recorder.tick(now: t0)
        mac.battery?.isOnAC = true
        failing.failInserts(into: "events")
        await #expect(throws: (any Error).self) { try await recorder.powerSourceChanged(now: t0 + 60) }
        #expect(try failing.store.series(.batteryPercent).count == 1) // the readings went back with the event
        failing.failInserts(into: "events", false)
        try await recorder.powerSourceChanged(now: t0 + 120)
        try await recorder.powerSourceChanged(now: t0 + 180)
        #expect(try failing.store.events(kind: .plugIn).map(\.date) == [t0 + 120])
    }

    @Test func eachFolderIsScannedWeeklyFromItsOwnLastScan() async throws {
        let mac = FakeMac()
        mac.battery?.isOnAC = true
        let scans = Scans()
        var system = mac.system
        system.folderUsage = { folder in
            scans.add(folder)
            // Caches can't be read the first time; DerivedData always can.
            return folder == URL.cachesDirectory && scans.count(folder) == 1
                ? nil : FolderUsage(bytes: 100, lastOpened: nil, unreadable: 2)
        }
        let recorder = try Recorder(store: Store(path: nil), system: system)
        try await recorder.tick(now: t0)
        try await recorder.tick(now: t0 + 600) // Caches again, DerivedData not
        try await recorder.tick(now: t0 + 1200) // nothing due
        let events = try recorder.store.events(kind: .folderSize)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.details["unreadable"] == "2" })
        #expect(scans.count(URL.cachesDirectory) == 2)
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

    @Test func aFailedBootstrapLeavesNothingAndRunsAgain() async throws {
        let mac = FakeMac(), failing = try FailingStore()
        mac.log = PmsetLogTests.log
        let recorder = Recorder(store: failing.store, system: mac.system)
        failing.failInserts(into: "events")
        await #expect(throws: (any Error).self) { try await recorder.bootstrapIfNeeded() }
        #expect(try failing.store.series(.batteryPercent).isEmpty)
        failing.failInserts(into: "events", false)
        try await recorder.bootstrapIfNeeded()
        #expect(try failing.store.events(kind: .unplug).count == 1)
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

/// Which folders the fake scanned, and how often.
final class Scans: @unchecked Sendable {
    private var counts: [URL: Int] = [:]
    func add(_ folder: URL) {
        counts[folder, default: 0] += 1
    }

    func count(_ folder: URL) -> Int {
        counts[folder] ?? 0
    }
}
