import Foundation

// F2 and F4 need no model: a straight line through the history answers well enough.

public enum DiskTrend {
    /// No disk forecast before a week of history.
    static let minimumHistory = 7 * 86400.0

    /// The last value of each of the last 30 days, oldest first.
    public static func daily(free: [Reading], now: Date = .now) -> [Reading] {
        var daily: [Int: Reading] = [:]
        for r in free where now.timeIntervalSince(r.date) <= 30 * 86400 {
            daily[Int(r.date.timeIntervalSince1970 / 86400)] = r
        }
        return daily.values.sorted { $0.date < $1.date }
    }

    /// When free space reaches zero, from the least-squares line through the last value of each of the last 30 days.
    /// `nil` while learning, when space is not shrinking, or when it would take more than a year.
    public static func fullDate(free: [Reading], now: Date = .now) -> Date? {
        let points = daily(free: free, now: now)
        guard let first = points.first, let last = points.last, points.count >= 3,
              last.date.timeIntervalSince(first.date) >= minimumHistory - 86400 else { return nil }
        let xs = points.map { $0.date.timeIntervalSince(first.date) }, ys = points.map(\.value)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / xs
            .reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard slope < 0 else { return nil }
        let seconds = last.value / -slope
        return seconds < 365 * 86400 ? last.date.addingTimeInterval(seconds) : nil
    }
}

public extension DiskTrend {
    /// Each scanned folder at its last weekly scan, with how much it grew since the one before; largest first.
    static func folders(store: Store, now: Date = .now) throws -> [Overview.DiskDetail.Folder] {
        let scans = try store.events(since: now.addingTimeInterval(-15 * 86400), kind: .folderSize)
        var sizes: [String: [Int64]] = [:]
        for scan in scans {
            if let path = scan.details["path"], let bytes = scan.details["bytes"].flatMap(Int64.init) {
                sizes[path, default: []].append(bytes)
            }
        }
        return sizes.map { path, sizes in
            Overview.DiskDetail.Folder(
                path: path, bytes: sizes[sizes.count - 1],
                growth: sizes.count >= 2 ? sizes[sizes.count - 1] - sizes[sizes.count - 2] : nil
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

public enum MeteredPace {
    /// The current allowance period for a plan that resets on `resetDay` (1…28) of each month.
    public static func period(resetDay: Int, now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        var parts = calendar.dateComponents([.year, .month], from: now)
        parts.day = resetDay
        var start = calendar.date(from: parts) ?? now
        if start > now {
            start = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        }
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return DateInterval(start: start, end: end)
    }

    /// When `used` reaches `limit` at this period's average pace so far; `nil` before a day of data, or when the
    /// pace stays under the limit until the reset.
    public static func runsOutAt(used: Double, limit: Double, period: DateInterval, now: Date = .now) -> Date? {
        let elapsed = now.timeIntervalSince(period.start)
        guard elapsed >= 86400, used > 0 else { return nil }
        if used >= limit {
            return now
        }
        let date = period.start.addingTimeInterval(limit / (used / elapsed))
        return date < period.end ? date : nil
    }
}
