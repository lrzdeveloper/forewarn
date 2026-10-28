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

    /// Kept at full resolution for 114 days: battery and power source are the forecast model's whole context;
    /// mobile data, so a billing period (up to 31 days) always adds up exactly.
    var keepsFullResolutionLonger: Bool { self == .batteryPercent || self == .onAC || self == .meteredBytes }

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
    /// Events of one kind can share a moment (one folder-size event per folder), so details are part of it: as
    /// JSON with sorted keys, which escapes them, so two different events never share an id.
    public var id: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(details)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        return "\(kind.rawValue)@\(date.timeIntervalSince1970)\(json)"
    }

    public init(_ kind: Kind, at date: Date, _ details: [String: String] = [:]) {
        self.kind = kind
        self.date = date
        self.details = details
    }
}

/// SQLite through GRDB: `samples` at full resolution, then hourly averages for a year, then daily ones
/// forever; `events` for things that happen at a moment (plug-in, sleep, …).
///
/// An hourly or daily value carries `n`, the readings behind it, and there is one per metric, time and resolution:
/// levels roll up weighted by `n`, and a reading that arrives after its hour was compacted merges into it.
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
        migrator.registerMigration("v3 aggregates") { db in
            try db.alter(table: "samples") { t in
                t.add(column: "n", .integer).notNull().defaults(to: 1)
            }
            // Before 1.1 a late reading could make a second bucket for the same hour: merge those first. Their
            // counts are unknown, so they weigh the same.
            let amounts = Metric.allCases.filter(\.isAmount).map { "'\($0.rawValue)'" }.joined(separator: ", ")
            try db.execute(sql: """
            CREATE TEMP TABLE merged AS
            SELECT metric, ts, resolution,
                   CASE WHEN metric IN (\(amounts)) THEN SUM(value) ELSE AVG(value) END AS value, COUNT(*) AS n
            FROM samples WHERE resolution > 0 GROUP BY metric, ts, resolution HAVING COUNT(*) > 1;
            DELETE FROM samples WHERE resolution > 0 AND EXISTS (
                SELECT 1 FROM merged m WHERE m.metric = samples.metric AND m.ts = samples.ts
                AND m.resolution = samples.resolution
            );
            INSERT INTO samples (metric, ts, value, resolution, n) SELECT metric, ts, value, resolution, n FROM merged;
            DROP TABLE merged;
            CREATE UNIQUE INDEX samples_bucket ON samples (metric, ts, resolution) WHERE resolution > 0;
            """)
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

    /// Readings and events in one transaction: all of them are stored, or none.
    public func record(_ readings: [Reading], events: [Event] = []) throws {
        guard !readings.isEmpty || !events.isEmpty else { return }
        let encoded = try events
            .map { try ($0, String(bytes: JSONEncoder().encode($0.details), encoding: .utf8) ?? "{}") }
        try db.write { db in
            for r in readings {
                try db.execute(
                    sql: "INSERT INTO samples (metric, ts, value) VALUES (?, ?, ?)",
                    arguments: [r.metric.rawValue, r.date.timeIntervalSince1970, r.value]
                )
            }
            for (event, details) in encoded {
                try db.execute(
                    sql: "INSERT INTO events (kind, ts, details) VALUES (?, ?, ?)",
                    arguments: [event.kind.rawValue, event.date.timeIntervalSince1970, details]
                )
            }
        }
    }

    public func record(_ event: Event) throws {
        try record([], events: [event])
    }

    // MARK: Reading

    /// Readings and buckets from `start` on. An hourly or daily bucket dated at its start that runs past `start`
    /// counts whole: it holds readings from after `start` too, and compacting must not make them disappear
    /// Only the bucket that straddles `start` reaches back before it.
    private static let since = "metric = ? AND (ts >= ? OR ts + resolution > ?)"

    /// Every stored value of `metric` from `start` on, oldest first, whatever its resolution.
    public func series(_ metric: Metric, since start: Date = .distantPast) throws -> [Reading] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ts, value FROM samples WHERE \(Self.since) ORDER BY ts",
                arguments: [metric.rawValue, start.timeIntervalSince1970, start.timeIntervalSince1970]
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
                sql: "SELECT COALESCE(SUM(value), 0) FROM samples WHERE \(Self.since)",
                arguments: [metric.rawValue, start.timeIntervalSince1970, start.timeIntervalSince1970]
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

    /// Amounts add up; levels average, weighted by the readings behind each value. A bucket that already exists
    /// (a reading arrived after its hour was compacted) takes the new values in the same way.
    private static func rollUp(_ db: Database, _ metric: Metric, from: Int, to: Int, before cutoff: Double) throws {
        let edge = (cutoff / Double(to)).rounded(.down) * Double(to)
        let (combine, merge) = metric.isAmount
            ? ("SUM(value)", "value + excluded.value")
            : ("SUM(value * n) / SUM(n)", "(value * n + excluded.value * excluded.n) / (n + excluded.n)")
        try db.execute(
            sql: """
            INSERT INTO samples (metric, ts, value, resolution, n)
            SELECT metric, CAST(ts / ? AS INTEGER) * ?, \(combine), ?, SUM(n)
            FROM samples WHERE metric = ? AND resolution = ? AND ts < ?
            GROUP BY CAST(ts / ? AS INTEGER)
            ON CONFLICT (metric, ts, resolution) WHERE resolution > 0 DO UPDATE SET value = \(merge), n = n + excluded.n
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
