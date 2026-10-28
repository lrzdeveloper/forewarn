import Foundation

/// Something worth telling the person, with the numbers the text is built from. The app writes the
/// words (localized); this layer decides only whether and why.
public enum Insight: Sendable, Equatable {
    /// F1: the battery reaches 10% around `at`, likely before the usual plug-in at `plugIn`.
    case batteryLow(at: Date, plugIn: Date?, chance: Double)
    /// F2: the disk fills around `at` (nil when it is already under 10% free). `folder` grew the most this week.
    case diskFilling(at: Date?, freeBytes: Double, folder: String?, folderGrowth: Double?)
    /// F3: the last sleep cost `lost` points over `hours`, against a usual `usualPerHour`.
    case sleepDrain(lost: Double, hours: Double, usualPerHour: Double, blockers: [String])
    /// F4: at this pace the data allowance runs out on `at`, before the reset.
    case dataRunsOut(at: Date, usedBytes: Double, limitBytes: Double)
    /// F5: battery health (full-charge over design capacity) is `percent`, `previous` at the last report.
    case batteryHealth(percent: Double, previous: Double?)

    public enum Kind: String, Sendable, CaseIterable {
        case battery, disk, sleep, data, health
    }

    public var kind: Kind {
        switch self {
        case .batteryLow: .battery
        case .diskFilling: .disk
        case .sleepDrain: .sleep
        case .dataRunsOut: .data
        case .batteryHealth: .health
        }
    }

    /// Flat strings for the notification log; `init?(kind:details:)` reads them back for the popover.
    public var details: [String: String] {
        func time(_ date: Date?) -> String? {
            date.map { String($0.timeIntervalSince1970) }
        }
        let d: [String: String?] = switch self {
        case let .batteryLow(at, plugIn, chance):
            ["at": time(at), "plugIn": time(plugIn), "chance": String(chance)]
        case let .diskFilling(at, free, folder, growth):
            ["at": time(at), "free": String(free), "folder": folder, "growth": growth.map { String($0) }]
        case let .sleepDrain(lost, hours, usual, blockers):
            ["lost": String(lost), "hours": String(hours), "usual": String(usual),
             "blockers": blockers.joined(separator: "\n")]
        case let .dataRunsOut(at, used, limit):
            ["at": time(at), "used": String(used), "limit": String(limit)]
        case let .batteryHealth(percent, previous):
            ["percent": String(percent), "previous": previous.map { String($0) }]
        }
        return d.compactMapValues(\.self)
    }

    public init?(kind: Kind, details d: [String: String]) {
        func time(_ key: String) -> Date? {
            d[key].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }
        func number(_ key: String) -> Double? {
            d[key].flatMap(Double.init)
        }
        switch kind {
        case .battery:
            guard let at = time("at") else { return nil }
            self = .batteryLow(at: at, plugIn: time("plugIn"), chance: number("chance") ?? 0)
        case .disk:
            self = .diskFilling(at: time("at"), freeBytes: number("free") ?? 0, folder: d["folder"],
                                folderGrowth: number("growth"))
        case .sleep:
            self = .sleepDrain(
                lost: number("lost") ?? 0,
                hours: number("hours") ?? 0,
                usualPerHour: number("usual") ?? 0,
                blockers: d["blockers"].map { $0.split(separator: "\n").map(String.init) } ?? []
            )
        case .data:
            guard let at = time("at") else { return nil }
            self = .dataRunsOut(at: at, usedBytes: number("used") ?? 0, limitBytes: number("limit") ?? 0)
        case .health:
            guard let percent = number("percent") else { return nil }
            self = .batteryHealth(percent: percent, previous: number("previous"))
        }
    }
}

/// A notification that was sent, and what the person did with it.
public struct SentNotification: Sendable, Equatable {
    public enum Action: String, Sendable {
        /// Acknowledged ("OK").
        case acknowledged
        /// F1 "I'll have power": mutes F1 until the next charge.
        case willHavePower
        /// "Show me", "Show details", "Adjust limit".
        case opened
        /// Closed without taking an action: three in a row raise the threshold one step.
        case dismissed
    }

    public var id: Int64
    public var kind: Insight.Kind
    public var date: Date
    public var action: Action?
    public var details: [String: String]

    public var insight: Insight? { Insight(kind: kind, details: details) }
}

/// Thresholds, one row per feedback step: three dismissals in a row move a kind one step later.
public enum Thresholds {
    /// F1: chance of reaching 10% before the expected plug-in.
    static let batteryChance = [0.6, 0.75, 0.9]
    /// F2: days until the disk fills.
    static let diskDays = [21.0, 14, 7]
    /// F3: drain per hour over the personal median.
    static let sleepMultiple = [3.0, 4, 5]
    /// F4: days until the allowance runs out (it must also run out before the reset).
    static let dataDays = [Double.infinity, 7, 3]

    /// Feedback step per kind (0, 1, 2), from the whole log: every three dismissals in a row add one; any action
    /// breaks the run. Health (monthly at most) has no steps.
    public static func steps(_ log: [SentNotification]) -> [Insight.Kind: Int] {
        var steps: [Insight.Kind: Int] = [:], run: [Insight.Kind: Int] = [:]
        for note in log where note.kind != .health {
            if note.action == .dismissed {
                run[note.kind, default: 0] += 1
                if run[note.kind] == 3 {
                    steps[note.kind] = min((steps[note.kind] ?? 0) + 1, 2)
                    run[note.kind] = 0
                }
            } else if note.action != nil {
                run[note.kind] = 0
            }
        }
        return steps
    }
}

/// What the insights read: the store plus the state the app has at hand.
public struct InsightContext: Sendable {
    public var now: Date
    public var battery: BatteryStatus?
    public var forecast: Overview.Forecast?
    public var disk: (free: Double, total: Double)?
    public var meteredLimit: (bytes: Double, resetDay: Int)?
    /// Kinds the person turned off in Settings › Notifications.
    public var disabled: Set<Insight.Kind>

    public init(
        now: Date, battery: BatteryStatus?, forecast: Overview.Forecast?, disk: (free: Double, total: Double)?,
        meteredLimit: (bytes: Double, resetDay: Int)? = nil, disabled: Set<Insight.Kind> = []
    ) {
        self.now = now
        self.battery = battery
        self.forecast = forecast
        self.disk = disk
        self.meteredLimit = meteredLimit
        self.disabled = disabled
    }
}

/// Deterministic rules: which insights hold now, then which of them may be sent.
public enum Insights {
    /// Insights that should be sent now: they hold, their kind is on, and the rate limiter lets them through.
    public static func due(_ context: InsightContext, store: Store) throws -> [Insight] {
        let log = try store.notifications(since: context.now.addingTimeInterval(-60 * 86400))
        let steps = try Thresholds.steps(store.notifications())
        return try holding(context, store: store, steps: steps)
            .filter { !context.disabled.contains($0.kind) }
            .filter { try allowed($0, log: log, store: store, now: context.now) }
    }

    /// The last recorded sleep against the usual one, for the popover; `nil` before any.
    public static func lastSleep(store: Store) throws -> Overview.SleepDrain? {
        let sessions = try SleepSession.all(store: store)
        guard let last = sessions.last else { return nil }
        return Overview.SleepDrain(
            lastSleepDropPercent: last.lost,
            usualDropPercent: median(sessions.dropLast().map(\.lost)) ?? last.lost,
            cause: last.blockers.first
        )
    }

    // MARK: Rate limiter

    /// One per kind per day; F1 once per discharge session; F5 once a month.
    static func allowed(_ insight: Insight, log: [SentNotification], store: Store, now: Date) throws -> Bool {
        let sameKind = log.filter { $0.kind == insight.kind }
        guard let last = sameKind.last else { return true }
        switch insight.kind {
        case .battery:
            let newSession = try !store.events(since: last.date.addingTimeInterval(1), kind: .unplug).isEmpty
            return newSession && now.timeIntervalSince(last.date) >= 86400
        case .health:
            return now.timeIntervalSince(last.date) >= 30 * 86400
        default:
            return now.timeIntervalSince(last.date) >= 86400
        }
    }

    // MARK: Rules

    static func holding(_ c: InsightContext, store: Store, steps: [Insight.Kind: Int]) throws -> [Insight] {
        try [
            battery(c, store: store, step: steps[.battery] ?? 0),
            disk(c, store: store, step: steps[.disk] ?? 0),
            sleep(c, store: store, step: steps[.sleep] ?? 0),
            data(c, store: store, step: steps[.data] ?? 0),
            health(c, store: store),
        ].compactMap(\.self)
    }

    /// F1. Not before: battery ≥ 25%, on battery for 10 minutes, 3 days of history (the forecast needs them).
    static func battery(_ c: InsightContext, store: Store, step: Int) throws -> Insight? {
        guard let battery = c.battery, !battery.isOnAC, battery.percent >= 25, let forecast = c.forecast,
              let unplug = try store.events(since: c.now.addingTimeInterval(-7 * 86400), kind: .unplug).last,
              c.now.timeIntervalSince(unplug.date) >= 600,
              let lowAt = forecast.firstDate(medianBelow: Overview.lowBatteryPercent)
              ?? forecast.points.last.map(\.date) else { return nil }
        let habit = try habit(store: store, now: c.now)
        let chance = runOutRisk(forecast: forecast, habit: habit)
        guard chance >= Thresholds.batteryChance[step] else { return nil }
        return .batteryLow(at: lowAt, plugIn: habit?.plugInTime(from: c.now), chance: chance)
    }

    /// The charging habit learned from all recorded plug-ins, `nil` with none yet.
    public static func habit(store: Store, now: Date) throws -> PlugInHabit? {
        let plugIns = try store.events(kind: .plugIn).map(\.date)
        guard !plugIns.isEmpty, let start = try store.series(.onAC).first?.date else { return nil }
        let unplugs = try store.events(kind: .unplug).map(\.date)
        return PlugInHabit(plugIns: plugIns, unplugs: unplugs, historyStart: start, now: now)
    }

    /// F2. Fires when the median "full" date is within 21 days or less than 10% is free; 7 days of history first.
    static func disk(_ c: InsightContext, store: Store, step: Int) throws -> Insight? {
        guard let disk = c.disk, disk.total > 0 else { return nil }
        let free = try store.series(.diskFree, since: c.now.addingTimeInterval(-30 * 86400))
        guard let first = free.first, c.now.timeIntervalSince(first.date) >= DiskTrend.minimumHistory - 3600 else {
            return nil
        }
        let fullAt = DiskTrend.fullDate(free: free, now: c.now)
        let soon = fullAt.map { $0.timeIntervalSince(c.now) <= Thresholds.diskDays[step] * 86400 } ?? false
        guard soon || disk.free / disk.total < 0.1 else { return nil }
        let growth = try folderGrowth(store: store, now: c.now)
        return .diskFilling(at: fullAt, freeBytes: disk.free, folder: growth?.path, folderGrowth: growth?.bytes)
    }

    /// The scanned folder that grew the most between its last two weekly scans.
    static func folderGrowth(store: Store, now: Date) throws -> (path: String, bytes: Double)? {
        try DiskTrend.folders(store: store, now: now)
            .compactMap { folder in folder.growth.map { (folder.path, Double($0)) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
    }

    /// F3. Right after a wake: the sleep that just ended drained more than three times the usual rate and more
    /// than 1% an hour. Five recorded sleeps first.
    static func sleep(_ c: InsightContext, store: Store, step: Int) throws -> Insight? {
        let sessions = try SleepSession.all(store: store)
        guard sessions.count >= 6, let last = sessions.last, c.now.timeIntervalSince(last.end) <= 3600 else {
            return nil
        }
        let usual = median(sessions.dropLast().map(\.perHour)) ?? 0
        guard last.perHour > Thresholds.sleepMultiple[step] * usual, last.perHour > 1 else { return nil }
        return .sleepDrain(lost: last.lost, hours: last.hours, usualPerHour: usual, blockers: last.blockers)
    }

    /// F4. Only with a limit set: the pace runs out before the reset (and within the step's lead time).
    static func data(_ c: InsightContext, store: Store, step: Int) throws -> Insight? {
        guard let limit = c.meteredLimit else { return nil }
        let period = MeteredPace.period(resetDay: limit.resetDay, now: c.now)
        let used = try store.sum(.meteredBytes, since: period.start)
        guard let at = MeteredPace.runsOutAt(used: used, limit: limit.bytes, period: period, now: c.now),
              at.timeIntervalSince(c.now) <= Thresholds.dataDays[step] * 86400 else { return nil }
        return .dataRunsOut(at: at, usedBytes: used, limitBytes: limit.bytes)
    }

    /// F5. Monthly at most: health dropped 2 points since the last report, or its trend reaches 80% within
    /// six months. Health is System Settings' "Maximum Capacity".
    static func health(_ c: InsightContext, store: Store) throws -> Insight? {
        guard let current = try store.latest(.maximumCapacity)?.value else { return nil }
        let previous = try store.notifications().last { $0.kind == .health }?.details["percent"].flatMap(Double.init)
        if let previous, previous - current >= 2 {
            return .batteryHealth(percent: current, previous: previous)
        }
        guard current > 80, let at = try HealthTrend.reaches80(store: store, now: c.now),
              at.timeIntervalSince(c.now) <= 182 * 86400 else { return nil }
        return .batteryHealth(percent: current, previous: previous)
    }
}

/// One sleep from the event log: from a `sleep` event to the next `wake`, both with a battery level.
struct SleepSession: Equatable {
    var start: Date, end: Date
    var lost: Double
    var blockers: [String]

    var hours: Double { end.timeIntervalSince(start) / 3600 }
    var perHour: Double { lost / max(hours, 1e-9) }

    /// Sleeps of at least half an hour on battery. A level that rose means the Mac charged meanwhile: skipped.
    static func all(store: Store) throws -> [SleepSession] {
        var sessions: [SleepSession] = []
        var pending: Event?
        for event in try store.events() where event.kind == .sleep || event.kind == .wake {
            if event.kind == .sleep {
                pending = event
                continue
            }
            defer { pending = nil }
            guard let sleep = pending, let before = sleep.details["percent"].flatMap(Double.init),
                  let after = event.details["percent"].flatMap(Double.init),
                  event.date.timeIntervalSince(sleep.date) >= 1800, after <= before else { continue }
            let blockers = sleep.details["blockers"]?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? []
            sessions.append(SleepSession(start: sleep.date, end: event.date, lost: before - after, blockers: blockers))
        }
        return sessions
    }
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted(), mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

func leastSquaresSlope(_ points: [(x: Double, y: Double)]) -> Double {
    guard points.count >= 2 else { return 0 }
    let mx = points.map(\.x).reduce(0, +) / Double(points.count)
    let my = points.map(\.y).reduce(0, +) / Double(points.count)
    let spread = points.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
    return spread > 0 ? points.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) } / spread : 0
}
