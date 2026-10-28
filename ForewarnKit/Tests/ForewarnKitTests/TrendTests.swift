@testable import ForewarnKit
import Foundation
import Testing

struct TrendTests {
    let now = Date(timeIntervalSince1970: 1_760_000_400)

    @Test func aWeekMeansSevenFullDays() {
        let free = (0 ... 6).map { Reading(.diskFree, 100e9 - Double($0) * 2e9, at: now - Double(6 - $0) * 86400) }
        #expect(DiskTrend.isLearning(dates: free.map(\.date))) // six days between first and last
        #expect(DiskTrend.fullDate(free: free, now: now) == nil)
        let week = [Reading(.diskFree, 102e9, at: now - 7 * 86400)] + free
        #expect(!DiskTrend.isLearning(dates: week.map(\.date)))
        #expect(DiskTrend.fullDate(free: week, now: now) != nil)
        // Four readings over two weeks are enough, however sparse.
        #expect(!DiskTrend.isLearning(dates: [0, 5, 9, 14].map { now - Double($0) * 86400 }))
    }

    @Test func theFullDateFollowsTheLineNotTheLastReading() throws {
        // 2 GB a day down a line through 80 GB today: full in 40 days. The noise leaves the least-squares line where it
        // is (same mean, same slope) but puts the last reading 3 GB above it, which alone would say 41.5 days.
        var free = (0 ... 10).map { Reading(.diskFree, 100e9 - Double($0) * 2e9, at: now - Double(10 - $0) * 86400) }
        free[0].value += 3e9
        free[5].value -= 6e9
        free[10].value += 3e9
        let full = try #require(DiskTrend.fullDate(free: free, now: now))
        #expect(abs(full.timeIntervalSince(now) - 40 * 86400) < 60)
    }

    @Test func readingsFromTheFutureAreIgnored() {
        let free = (0 ... 10).map { Reading(.diskFree, 100e9 - Double($0) * 2e9, at: now - Double(10 - $0) * 86400) }
        let future = free + [Reading(.diskFree, 1e9, at: now + 86400)]
        #expect(DiskTrend.daily(free: future, now: now) == DiskTrend.daily(free: free, now: now))
    }

    @Test func diskFillsWhereTheLineCrossesZero() {
        // 100 GB free, losing 2 GB a day for 10 days: 80 GB left, 40 days to go.
        let free = (0 ... 10).map { Reading(.diskFree, 100e9 - Double($0) * 2e9, at: now - Double(10 - $0) * 86400) }
        let full = try? #require(DiskTrend.fullDate(free: free, now: now))
        #expect(abs((full ?? .distantPast).timeIntervalSince(now) - 40 * 86400) < 60)
        #expect(DiskTrend.fullDate(free: Array(free.suffix(3)), now: now) == nil) // under a week
        let growing = free.map { Reading(.diskFree, 200e9 - $0.value, at: $0.date) }
        #expect(DiskTrend.fullDate(free: growing, now: now) == nil)
    }

    @Test func meteredPaceAndPeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let mid = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let period = MeteredPace.period(resetDay: 5, now: mid, calendar: calendar)
        #expect(period.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        #expect(period.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        // 15.5 days in, 15.5 GB used: 1 GB a day reaches 20 GB on day 20, before the reset.
        let out = try #require(MeteredPace.runsOutAt(used: 15.5e9, limit: 20e9, period: period, now: mid))
        #expect(abs(out.timeIntervalSince(period.start) - 20 * 86400) < 1)
        #expect(MeteredPace.runsOutAt(used: 5e9, limit: 20e9, period: period, now: mid) == nil)
    }
}
