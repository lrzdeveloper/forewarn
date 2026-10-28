import AppKit
import ForewarnKit
import Foundation
import IOKit.ps
import Network
import Observation
import os

/// Holds what the popover and the menu bar icon show, and feeds the recorder from the system.
/// Periodic work runs every 5 minutes through the system scheduler, never more often; everything else
/// reacts to system notifications: power source, network path, sleep, thermal state, Low Power Mode.
@Observable
@MainActor
final class OverviewStore {
    private(set) var overview: Overview
    /// `nil` with `-FWSample`: sample data on screen, nothing recorded.
    let recorder: Recorder?
    private let forecaster: BatteryForecaster?
    private var batteryForecast: Overview.Forecast?
    let notifier: Notifier?

    /// `-FWSample risky|fine|…` shows sample data instead of this Mac's, for screenshots and UI tests.
    private let sample = UserDefaults.standard.string(forKey: "FWSample").flatMap(Overview.SampleState.init)
    private let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.lrzdeveloper.forewarn.refresh")
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "io.github.lrzdeveloper.forewarn", category: "collection")

    init() {
        overview = Overview()
        if sample == nil {
            let store = (try? Store.standard()) ?? (try? Store(path: nil))
            recorder = store.map { Recorder(store: $0) }
            forecaster = store.map { BatteryForecaster(store: $0, loadTimestral: TimestralEngine.installed) }
            notifier = store.map { Notifier(store: $0) }
        } else {
            recorder = nil
            forecaster = nil
            notifier = nil
        }
        refresh()
        guard recorder != nil else { return }
        record { recorder in
            try await recorder.bootstrapIfNeeded()
            try await recorder.tick()
        }
        startScheduler()
        observeSystem()
    }

    /// Reads the battery and disk now and redraws. Cheap: no recording, no forecast.
    func refresh() {
        if let sample {
            overview = .sample(state: sample)
            return
        }
        let status = BatteryStatus.current()
        let store = recorder?.store
        let history = (try? store?.series(.batteryPercent, since: .now.addingTimeInterval(-12 * 3600))) ?? []
        let energyToday = try? store?.sum(.selfEnergy, since: Calendar.current.startOfDay(for: .now))
        let diskFree = (try? store?.series(.diskFree, since: .now.addingTimeInterval(-30 * 86400))) ?? []
        let plugIn = status.flatMap { $0.isOnAC ? nil : store.flatMap { try? Insights.habit(store: $0, now: .now) } }?
            .plugInTime(from: .now)
        overview = Overview(
            battery: status.map { status in
                Overview.Battery(
                    percent: status.percent, isCharging: status.isCharging, isOnAC: status.isOnAC,
                    history: history.map { Overview.Sample(date: $0.date, value: $0.value) },
                    forecast: status.isOnAC ? nil : batteryForecast,
                    usualPlugIn: plugIn,
                    systemEstimateMinutes: status.isCharging ? status.minutesUntilCharged : status
                        .systemEstimateMinutes,
                    chargeLimit: status.chargeLimit,
                    shortfall: Self.shortfall(status, store: store)
                )
            },
            disk: DiskSpace.current().map {
                Overview.Disk(
                    freeBytes: Int64($0.free), totalBytes: Int64($0.total), fullDate: DiskTrend.fullDate(free: diskFree)
                )
            },
            meteredData: store.flatMap(Self.meteredData),
            sleepDrain: store.flatMap { try? Insights.lastSleep(store: $0) },
            health: status.flatMap { status in Self.health(status, store: store)?.health },
            ownEnergyTodayPercent: energyToday.flatMap { joules in status?.capacityJoules.map { joules / $0 * 100 } }
        )
    }

    /// F6 from the readings the recorder already takes on power (every 10 minutes): nothing new runs.
    private static func shortfall(_ status: BatteryStatus, store: Store?) -> Overview.ChargerShortfall? {
        guard status.isOnAC, !status.isCharging, let store else { return nil }
        let since = Date.now.addingTimeInterval(-30 * 60)
        return Overview.ChargerShortfall.detect(
            amperage: (try? store.series(.amperage, since: since)) ?? [],
            onAC: (try? store.series(.onAC, since: since)) ?? [],
            status: status, adapterWatts: BatteryStatus.adapterWatts(), now: .now
        )
    }

    /// F4 from the user's limit in Settings › Data and the bytes counted this period.
    private static func meteredData(_ store: Store) -> Overview.MeteredData? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.meteredLimitEnabled) else { return nil }
        let limit = Double(defaults.object(forKey: SettingsKey.meteredLimitGB) as? Int ?? 20) * 1e9
        let period = MeteredPace.period(resetDay: defaults.object(forKey: SettingsKey.meteredResetDay) as? Int ?? 1)
        let used = (try? store.sum(.meteredBytes, since: period.start)) ?? 0
        return Overview.MeteredData(
            usedBytes: Int64(used), limitBytes: Int64(limit), resetDate: period.end,
            runsOutAt: MeteredPace.runsOutAt(used: used, limit: limit, period: period)
        )
    }

    /// The disk page: free space now, the last 30 days and the scanned folders.
    func diskDetail() -> Overview.DiskDetail? {
        if let sample {
            return Overview.sampleDisk(state: sample)
        }
        guard let disk = overview.disk else { return nil }
        let store = recorder?.store
        let free = (try? store?.series(.diskFree, since: .now.addingTimeInterval(-30 * 86400))) ?? []
        return Overview.DiskDetail(
            disk: disk, history: DiskTrend.daily(free: free).map { Overview.Sample(date: $0.date, value: $0.value) },
            folders: (try? store.map { try DiskTrend.folders(store: $0) }) ?? []
        )
    }

    /// The Battery Health page: read when it opens, nothing about it runs periodically.
    func healthDetail() -> Overview.HealthDetail? {
        if let sample {
            return Overview.sampleHealth(state: sample)
        }
        guard let status = BatteryStatus.current(), let health = Self.health(status, store: recorder?.store) else {
            return nil
        }
        let history = (try? recorder.map { try HealthTrend.daily(store: $0.store) }) ?? []
        return Overview.HealthDetail(
            health: health.health, outlook: health.outlook,
            history: history.map { Overview.Sample(date: $0.date, value: $0.value) }, chargeLimit: status.chargeLimit
        )
    }

    /// Battery health now and where it is heading (`HealthOutlook`).
    private static func health(_ status: BatteryStatus, store: Store?)
        -> (health: Overview.BatteryHealth, outlook: HealthOutlook?)?
    {
        guard let capacity = status.maximumCapacity else { return nil }
        let fullCharge = zip(status.fullChargeCapacity, status.designCapacity).map { $0 / $1 * 100 }
        let outlook = store.flatMap {
            try? HealthOutlook.estimate(
                store: $0, maximumCapacity: capacity, fullChargePercent: fullCharge,
                cycleCount: status.cycleCount ?? 0, designCycleCount: status.designCycleCount
            )
        }
        let health = Overview.BatteryHealth(
            maximumCapacity: capacity, cycleCount: Int(status.cycleCount ?? 0),
            designCycleCount: status.designCycleCount.map(Int.init), serviceRecommended: status.serviceRecommended,
            reaches80At: outlook?.reaches80At, inOneYear: outlook?.inOneYear
        )
        return (health, outlook)
    }

    /// What the insights need beyond the store: the live readings and the person's settings.
    private func insightContext(battery: BatteryStatus?) -> InsightContext {
        let defaults = UserDefaults.standard
        let limit: (bytes: Double, resetDay: Int)? = defaults.bool(forKey: SettingsKey.meteredLimitEnabled)
            ? (Double(defaults.object(forKey: SettingsKey.meteredLimitGB) as? Int ?? 20) * 1e9,
               defaults.object(forKey: SettingsKey.meteredResetDay) as? Int ?? 1)
            : nil
        let disabled = Set(Insight.Kind.allCases.filter {
            defaults.object(forKey: SettingsKey.notify($0.rawValue)) as? Bool == false
        })
        return InsightContext(
            now: .now, battery: battery, forecast: batteryForecast, disk: DiskSpace.current(),
            meteredLimit: limit, disabled: disabled
        )
    }

    // MARK: Collection

    /// Runs recorder work off the main actor, then redraws. Failures are logged: a missed sample is not worth
    /// interrupting anyone for.
    private func record(_ work: @escaping @Sendable (Recorder) async throws -> Void) {
        guard let recorder else { return }
        Task {
            do {
                try await work(recorder)
                if let forecaster {
                    let battery = BatteryStatus.current()
                    batteryForecast = try await forecaster.update(battery: battery)
                    try await forecaster.evaluateIfDue(onAC: battery?.isOnAC ?? false)
                    let due = try Insights.due(insightContext(battery: battery), store: recorder.store)
                    await notifier?.send(due)
                }
            } catch {
                log.error("recording failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    private func startScheduler() {
        scheduler.interval = 300
        scheduler.tolerance = 60
        scheduler.qualityOfService = .utility
        scheduler.repeats = true
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.record { try await $0.tick() }
                completion(.finished)
            }
        }
    }

    private func observeSystem() {
        // Power source: IOKit calls back on the main run loop when anything about the battery changes.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let store = Unmanaged<OverviewStore>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { store.record { try await $0.powerSourceChanged() } }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // Network: count bytes only while macOS marks the path expensive (hotspot, some cellular).
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let interface = path.isExpensive ? path.availableInterfaces.first?.name : nil
            Task { @MainActor in self?.record { try await $0.meteredPathChanged(to: interface) } }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        // The time is taken when the notification arrives, before the hop to the recorder.
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, on: workspace) { try await $0.willSleep(now: $1) }
        observe(NSWorkspace.didWakeNotification, on: workspace) { try await $0.didWake(now: $1) }
        observe(ProcessInfo.thermalStateDidChangeNotification, on: .default) { recorder, now in
            let state = String(ProcessInfo.processInfo.thermalState.rawValue)
            try await recorder.record(Event(.thermalState, at: now, ["state": state]))
        }
        observe(.NSProcessInfoPowerStateDidChange, on: .default) { recorder, now in
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled ? "1" : "0"
            try await recorder.record(Event(.lowPowerMode, at: now, ["on": on]))
        }
    }

    private func observe(
        _ name: Notification.Name, on center: NotificationCenter,
        _ work: @escaping @Sendable (Recorder, Date) async throws -> Void
    ) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            let now = Date.now
            MainActor.assumeIsolated { self?.record { try await work($0, now) } }
        })
    }
}

private func zip(_ a: Double?, _ b: Double?) -> (Double, Double)? {
    guard let a, let b, b > 0 else { return nil }
    return (a, b)
}
