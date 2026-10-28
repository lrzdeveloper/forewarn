import Foundation

/// The system reads `Recorder` uses. `.live` reads this Mac; tests pass fakes.
public struct System: Sendable {
    public var battery: @Sendable () -> BatteryStatus?
    public var disk: @Sendable () -> (free: Double, total: Double)?
    public var network: @Sendable () -> [String: UInt64]
    public var selfEnergy: @Sendable () -> Double?
    public var sleepBlockers: @Sendable () -> [String]
    public var pmsetLog: @Sendable () -> String?
    public var folderUsage: @Sendable (URL) -> FolderUsage?

    public static let live = System(
        battery: BatteryStatus.current, disk: DiskSpace.current, network: NetworkCounters.current,
        selfEnergy: SelfEnergy.current, sleepBlockers: SleepBlockers.current, pmsetLog: PmsetLog.current,
        folderUsage: DiskSpace.usage(of:)
    )
}

/// Turns system reads into stored samples and events.
/// The app calls `tick` from its 5-minute background activity and the event methods from system notifications;
/// nothing here schedules work of its own.
public actor Recorder {
    public nonisolated let store: Store
    private let system: System

    private var lastBattery: Date?
    private var lastHourly: Date?
    private var lastCompaction: Date?
    private var wasOnAC: Bool?
    /// Joules already counted, so each sample stores only what is new. Zero at launch: all of it is new.
    /// Moves only once a sample is stored: a failed write is counted again by the next one.
    private var countedEnergy = 0.0
    /// The interfaces of the expensive path and their counters at the last stored sample.
    private var metered: [String: UInt64]?

    /// Late background activities still count as on time (the scheduler's tolerance is 60 s).
    static let slack = 60.0
    /// UserDefaults key: the person allowed Downloads in Settings › Notifications (macOS asks too, the first time).
    public static let scanDownloadsKey = "scanDownloads"

    /// Folders scanned weekly for the disk suggestions of F2: those that need no privacy prompt, and Downloads once
    /// the person allows it.
    static var scannedFolders: [URL] {
        [URL.libraryDirectory.appending(path: "Developer/Xcode/DerivedData"), URL.cachesDirectory]
            + (UserDefaults.standard.bool(forKey: scanDownloadsKey) ? [URL.downloadsDirectory] : [])
    }

    public init(store: Store, system: System = .live) {
        self.store = store
        self.system = system
    }

    /// Every 5 minutes. Battery: every 5 min on battery, every 10 on power or below 20%.
    /// Disk and own energy: hourly. Retention: daily. Folder sizes: weekly, on power only.
    @discardableResult
    public func tick(now: Date = .now) throws -> BatteryStatus? {
        let battery = system.battery()
        if let battery {
            try noticePowerSource(battery, now: now)
            let interval = battery.isOnAC || battery.percent < 20 ? 600.0 : 300.0
            if now.timeIntervalSince(lastBattery ?? .distantPast) >= interval - Self.slack {
                try store.record(battery.readings(at: now))
                lastBattery = now
            }
        }
        try recordMetered(now: now)
        if now.timeIntervalSince(lastHourly ?? .distantPast) >= 3600 - Self.slack {
            try recordHourly(now: now)
            lastHourly = now
        }
        if now.timeIntervalSince(lastCompaction ?? .distantPast) >= Store.day {
            try store.compact(now: now)
            lastCompaction = now
        }
        if battery?.isOnAC ?? true {
            try scanFolders(now: now)
        }
        return battery
    }

    /// IOKit says the power source changed: record plug-in and unplug right away, they bound discharge sessions.
    @discardableResult
    public func powerSourceChanged(now: Date = .now) throws -> BatteryStatus? {
        guard let battery = system.battery() else { return nil }
        try noticePowerSource(battery, now: now)
        return battery
    }

    /// The network path changed. `interfaces` are the ones the path uses when macOS marks it expensive, else empty.
    /// Bytes are counted only on those; the switch itself closes the previous count.
    public func meteredPathChanged(to interfaces: Set<String>, now: Date = .now) throws {
        guard interfaces != metered.map({ Set($0.keys) }) ?? [] else { return }
        try recordMetered(now: now)
        let totals = system.network()
        metered = interfaces.isEmpty ? nil : Dictionary(uniqueKeysWithValues: interfaces.map { ($0, totals[$0] ?? 0) })
    }

    /// Everything was deleted (Settings › Privacy): what is counted from now on starts from now.
    public func reset() {
        lastBattery = nil
        lastHourly = nil
        lastCompaction = nil
        wasOnAC = nil
        countedEnergy = system.selfEnergy() ?? 0
        let totals = system.network()
        metered = metered.map { Dictionary(uniqueKeysWithValues: $0.keys.map { ($0, totals[$0] ?? 0) }) }
    }

    public func willSleep(now: Date = .now) throws {
        var details = ["blockers": system.sleepBlockers().joined(separator: ", ")]
        details["percent"] = system.battery().map { String($0.percent) }
        try store.record(Event(.sleep, at: now, details))
    }

    public func didWake(now: Date = .now) throws {
        let battery = system.battery()
        try store.record(Event(.wake, at: now, battery.map { ["percent": String($0.percent)] } ?? [:]))
        if let battery {
            try store.record(battery.readings(at: now))
            lastBattery = now
        }
    }

    public func record(_ event: Event) throws {
        try store.record(event)
    }

    /// First launch only: import the week of history `pmset` keeps, with the plug-ins and unplugs inside it.
    /// One transaction, so an import cut short leaves nothing behind and the next launch tries again.
    public func bootstrapIfNeeded() throws {
        guard try store.latest(.batteryPercent) == nil, let log = system.pmsetLog() else { return }
        let readings = PmsetLog.parse(log)
        var events: [Event] = [], previous: Bool?
        for reading in readings where reading.metric == .onAC {
            let onAC = reading.value == 1
            if let previous, previous != onAC {
                events.append(Event(onAC ? .plugIn : .unplug, at: reading.date, ["source": "pmset"]))
            }
            previous = onAC
        }
        try store.record(readings, events: events)
    }

    // MARK: Parts

    private func noticePowerSource(_ battery: BatteryStatus, now: Date) throws {
        // After a restart, compare with the last stored state: a plug-in or unplug while the app was not running
        // still bounds a session. Its time is then when the app noticed, so it is marked.
        let restarted = wasOnAC == nil
        let stored = try restarted ? store.latest(.onAC).map { $0.value > 0.5 } : wasOnAC
        guard let stored, stored != battery.isOnAC else {
            wasOnAC = battery.isOnAC
            return
        }
        var details = ["percent": String(battery.percent)]
        if restarted {
            details["noticedAtLaunch"] = "1"
        }
        // The event and its readings together, and the change taken as known only once they are stored: a failed
        // write is tried again on the next call, never half-done or skipped.
        try store.record(
            battery.readings(at: now),
            events: [Event(battery.isOnAC ? .plugIn : .unplug, at: now, details)]
        )
        wasOnAC = battery.isOnAC
        lastBattery = now
    }

    private func recordMetered(now: Date) throws {
        guard let metered else { return }
        let totals = system.network()
        var moved: UInt64 = 0, counted = metered
        for (interface, previous) in metered {
            guard let total = totals[interface] else { continue }
            moved += NetworkCounters.delta(from: previous, to: total)
            counted[interface] = total
        }
        if moved > 0 {
            try store.record([Reading(.meteredBytes, Double(moved), at: now)])
        }
        // Only once stored: after a failed write the next sample counts these bytes again.
        self.metered = counted
    }

    private func recordHourly(now: Date) throws {
        var readings: [Reading] = []
        if let disk = system.disk() {
            readings += [Reading(.diskFree, disk.free, at: now), Reading(.diskTotal, disk.total, at: now)]
        }
        let joules = system.selfEnergy()
        if let joules {
            readings.append(Reading(.selfEnergy, max(joules - countedEnergy, 0), at: now))
        }
        try store.record(readings)
        if let joules {
            countedEnergy = joules
        }
    }

    /// Each folder weekly, from its own last scan: one that failed is tried again on the next tick on power.
    private func scanFolders(now: Date) throws {
        let recent = try store.events(since: now.addingTimeInterval(-7 * Store.day), kind: .folderSize)
        let scanned = Set(recent.compactMap { $0.details["path"] })
        for folder in Self.scannedFolders where !scanned.contains(folder.path) {
            guard let usage = system.folderUsage(folder) else { continue }
            var details = ["path": folder.path, "bytes": String(Int64(usage.bytes))]
            details["lastOpened"] = usage.lastOpened.map { ISO8601DateFormatter().string(from: $0) }
            if usage.unreadable > 0 {
                details["unreadable"] = String(usage.unreadable) // a partial total: at least this much
            }
            try store.record(Event(.folderSize, at: now, details))
        }
    }
}
