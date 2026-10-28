import Foundation
import GRDB

/// What a sample measures. The raw value is the name stored in the database.
public enum Metric: String, Sendable, CaseIterable, Identifiable {
    case batteryPercent, onAC, charging, amperage, voltage, fullChargeCapacity, designCapacity, cycleCount, chargeLimit
    /// Battery health as System Settings shows it: nominal over design capacity, at most 100%.
    case maximumCapacity
    case diskFree, diskTotal
    /// Bytes moved on expensive networks since the previous sample.
    case meteredBytes
    /// Joules Forewarn itself used since the previous sample.
    case selfEnergy

    public var id: Self { self }

    /// Kept at full resolution for 114 days, the forecast model's whole context.
    var keepsFullResolutionLonger: Bool { self == .batteryPercent || self == .onAC }

    /// Amounts per interval add up when aggregated; levels average.
    var isAmount: Bool { self == .meteredBytes || self == .selfEnergy }
}

public struct Reading: Sendable, Equatable {
    public var metric: Metric
    public var date: Date
    public var value: Double

    public init(_ metric: Metric, _ value: Double, at date: Date) {
        self.metric = metric
        self.value = value
        self.date = date
    }
}

public struct Event: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case plugIn, unplug, sleep, wake, thermalState, lowPowerMode, folderSize, engineChoice
    }

    public var kind: Kind
    public var date: Date
    public var details: [String: String]
    /// Events of one kind can share a moment (one folder-size event per folder), so details are part of it.
    public var id: String {
        "\(kind.rawValue)@\(date.timeIntervalSince1970)" + details.sorted { $0.key < $1.key }.map { "|\($0)=\($1)" }
            .joined()
    }

    public init(_ kind: Kind, at date: Date, _ details: [String: String] = [:]) {
        self.kind = kind
        self.date = date
        self.details = details
    }
}

/// SQLite through GRDB: `samples` at full resolution, then hourly averages for a year, then daily ones
/// forever; `events` for things that happen at a moment (plug-in, sleep, …).
public final class Store: Sendable {
    private let db: DatabaseQueue

    static let day = 86400.0
    static let fullResolution = 30 * day
    static let fullResolutionLonger = 114 * day
    static let hourly = 365 * day

    /// `nil` keeps the database in memory, for tests.
    public init(path: String?) throws {
        db = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // resolution: 0 raw, 3600 hourly, 86400 daily (seconds per bucket).
            try db.create(table: "samples") { t in
                t.column("metric", .text).notNull()
                t.column("ts", .double).notNull()
                t.column("value", .double).notNull()
                t.column("resolution", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "samples_metric_ts", on: "samples", columns: ["metric", "ts"])
            try db.create(table: "events") { t in
                t.column("kind", .text).notNull()
                t.column("ts", .double).notNull()
                t.column("details", .text).notNull()
            }
            try db.create(index: "events_ts", on: "events", columns: ["ts"])
        }
        migrator.registerMigration("v2 notifications") { db in
            // What was sent and what the person did with it; the rate limiter and feedback read this.
            try db.create(table: "notifications") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("ts", .double).notNull()
                t.column("action_taken", .text)
                t.column("details", .text).notNull()
            }
        }
        try migrator.migrate(db)
    }

    /// `~/Library/Application Support/Forewarn/forewarn.sqlite`.
    public static func standard() throws -> Store {
        let folder = URL.applicationSupportDirectory.appending(path: "Forewarn")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try Store(path: folder.appending(path: "forewarn.sqlite").path)
    }

    // MARK: Writing

    public func record(_ readings: [Reading]) throws {
        guard !readings.isEmpty else { return }
        try db.write { db in
            for r in readings {
                try db.execute(
                    sql: "INSERT INTO samples (metric, ts, value) VALUES (?, ?, ?)",
                    arguments: [r.metric.rawValue, r.date.timeIntervalSince1970, r.value]
                )
            }
        }
    }

    public func record(_ event: Event) throws {
        let details = try String(bytes: JSONEncoder().encode(event.details), encoding: .utf8) ?? "{}"
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO events (kind, ts, details) VALUES (?, ?, ?)",
                arguments: [event.kind.rawValue, event.date.timeIntervalSince1970, details]
            )
        }
    }

    // MARK: Reading

    /// Every stored value of `metric` from `start` on, oldest first, whatever its resolution.
    public func series(_ metric: Metric, since start: Date = .distantPast) throws -> [Reading] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ts, value FROM samples WHERE metric = ? AND ts >= ? ORDER BY ts",
                arguments: [metric.rawValue, start.timeIntervalSince1970]
            ).map { Reading(metric, $0["value"], at: Date(timeIntervalSince1970: $0["ts"])) }
        }
    }

    public func latest(_ metric: Metric) throws -> Reading? {
        try db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT ts, value FROM samples WHERE metric = ? ORDER BY ts DESC LIMIT 1",
                arguments: [metric.rawValue]
            ).map { Reading(metric, $0["value"], at: Date(timeIntervalSince1970: $0["ts"])) }
        }
    }

    public func sum(_ metric: Metric, since start: Date) throws -> Double {
        try db.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(value), 0) FROM samples WHERE metric = ? AND ts >= ?",
                arguments: [metric.rawValue, start.timeIntervalSince1970]
            ) ?? 0
        }
    }

    public func events(since start: Date = .distantPast, kind: Event.Kind? = nil) throws -> [Event] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT kind, ts, details FROM events WHERE ts >= ? AND (? IS NULL OR kind = ?) ORDER BY ts",
                arguments: [start.timeIntervalSince1970, kind?.rawValue, kind?.rawValue]
            ).compactMap { row in
                guard let kind = Event.Kind(rawValue: row["kind"]) else { return nil }
                let details = (try? JSONDecoder().decode(
                    [String: String].self,
                    from: Data((row["details"] as String).utf8)
                ))
                return Event(kind, at: Date(timeIntervalSince1970: row["ts"]), details ?? [:])
            }
        }
    }

    public struct MetricSummary: Sendable, Identifiable {
        public var metric: Metric
        public var count: Int
        public var latest: Date
        public var id: Metric { metric }
    }

    /// Number of stored values and the newest date, per metric (debug window).
    public func summary() throws -> [MetricSummary] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT metric, COUNT(*) AS n, MAX(ts) AS ts FROM samples GROUP BY metric")
                .compactMap { row in
                    Metric(rawValue: row["metric"]).map {
                        MetricSummary(metric: $0, count: row["n"], latest: Date(timeIntervalSince1970: row["ts"]))
                    }
                }
        }
    }

    // MARK: Retention

    /// Rolls raw samples past their full-resolution window into hourly buckets, and hourly ones older than a year
    /// into daily buckets. Buckets align to whole hours and days, so a bucket is never split.
    public func compact(now: Date = .now) throws {
        let t = now.timeIntervalSince1970
        try db.write { db in
            for metric in Metric.allCases {
                let window = metric.keepsFullResolutionLonger ? Self.fullResolutionLonger : Self.fullResolution
                try Self.rollUp(db, metric, from: 0, to: 3600, before: t - window)
                try Self.rollUp(db, metric, from: 3600, to: 86400, before: t - Self.hourly)
            }
        }
    }

    private static func rollUp(_ db: Database, _ metric: Metric, from: Int, to: Int, before cutoff: Double) throws {
        let edge = (cutoff / Double(to)).rounded(.down) * Double(to)
        let combine = metric.isAmount ? "SUM" : "AVG"
        try db.execute(
            sql: """
            INSERT INTO samples (metric, ts, value, resolution)
            SELECT metric, CAST(ts / ? AS INTEGER) * ?, \(combine)(value), ?
            FROM samples WHERE metric = ? AND resolution = ? AND ts < ?
            GROUP BY CAST(ts / ? AS INTEGER)
            """,
            arguments: [to, to, to, metric.rawValue, from, edge, to]
        )
        try db.execute(
            sql: "DELETE FROM samples WHERE metric = ? AND resolution = ? AND ts < ?",
            arguments: [metric.rawValue, from, edge]
        )
    }

    // MARK: Notifications

    /// Logs a notification about to be sent; the id goes into the notification so its action can come back here.
    @discardableResult
    public func logNotification(_ insight: Insight, at date: Date) throws -> Int64 {
        let details = try String(bytes: JSONEncoder().encode(insight.details), encoding: .utf8) ?? "{}"
        return try db.write { db in
            try db.execute(
                sql: "INSERT INTO notifications (kind, ts, details) VALUES (?, ?, ?)",
                arguments: [insight.kind.rawValue, date.timeIntervalSince1970, details]
            )
            return db.lastInsertedRowID
        }
    }

    public func setAction(_ action: SentNotification.Action, forNotification id: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE notifications SET action_taken = ? WHERE id = ?", arguments: [action.rawValue, id]
            )
        }
    }

    public func notifications(since start: Date = .distantPast) throws -> [SentNotification] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, kind, ts, action_taken, details FROM notifications WHERE ts >= ? ORDER BY ts, id",
                arguments: [start.timeIntervalSince1970]
            ).compactMap { row in
                guard let kind = Insight.Kind(rawValue: row["kind"]) else { return nil }
                let details = try? JSONDecoder().decode(
                    [String: String].self,
                    from: Data((row["details"] as String).utf8)
                )
                return SentNotification(
                    id: row["id"], kind: kind, date: Date(timeIntervalSince1970: row["ts"]),
                    action: (row["action_taken"] as String?).flatMap(SentNotification.Action.init),
                    details: details ?? [:]
                )
            }
        }
    }

    // MARK: Privacy (Settings › Privacy)

    public func deleteAll() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM samples")
            try db.execute(sql: "DELETE FROM events")
            try db.execute(sql: "DELETE FROM notifications")
        }
    }

    /// Every sample and event as CSV: `kind,metric_or_event,timestamp,value_or_details`.
    public func exportCSV() throws -> String {
        let iso = ISO8601DateFormatter()
        return try db.read { db in
            var lines = ["kind,name,time,value"]
            for row in try Row.fetchAll(db, sql: "SELECT metric, ts, value FROM samples ORDER BY ts") {
                let date = iso.string(from: Date(timeIntervalSince1970: row["ts"]))
                lines.append("sample,\(row["metric"] as String),\(date),\(row["value"] as Double)")
            }
            for row in try Row.fetchAll(db, sql: "SELECT kind, ts, details FROM events ORDER BY ts") {
                let date = iso.string(from: Date(timeIntervalSince1970: row["ts"]))
                let details = (row["details"] as String).replacingOccurrences(of: "\"", with: "\"\"")
                lines.append("event,\(row["kind"] as String),\(date),\"\(details)\"")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
}
