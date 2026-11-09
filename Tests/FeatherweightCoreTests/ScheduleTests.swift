import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct ScheduleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private let daily = Schedule(frequency: .daily, weekday: 1, hour: 3, minute: 0)
    private let weekly = Schedule(frequency: .weekly, weekday: 1, hour: 3, minute: 0)  // Sunday

    @Test func nextRunDaily() {
        #expect(daily.nextRun(after: date(2026, 11, 8, 10), calendar: calendar) == date(2026, 11, 9, 3))
        #expect(daily.nextRun(after: date(2026, 11, 8, 2), calendar: calendar) == date(2026, 11, 8, 3))
        // Strictly after: exactly at the scheduled time rolls to the next day.
        #expect(daily.nextRun(after: date(2026, 11, 8, 3), calendar: calendar) == date(2026, 11, 9, 3))
    }

    @Test func nextRunWeekly() {
        #expect(weekly.nextRun(after: date(2026, 11, 8, 2), calendar: calendar) == date(2026, 11, 8, 3))
        #expect(weekly.nextRun(after: date(2026, 11, 8, 4), calendar: calendar) == date(2026, 11, 15, 3))
    }

    @Test func overdueWhenMissedWhileAsleep() {
        let overdue = weekly.isOverdue(
            lastRun: date(2026, 11, 1, 3), now: date(2026, 11, 9, 9), calendar: calendar)
        #expect(overdue)
    }

    @Test func overdueWhenNeverRun() {
        #expect(weekly.isOverdue(lastRun: nil, now: date(2026, 11, 9, 9), calendar: calendar))
    }

    @Test func notOverdueRightAfterRun() {
        let now = date(2026, 11, 9, 9)
        #expect(!weekly.isOverdue(lastRun: now, now: now, calendar: calendar))
        // A run a little after the scheduled time satisfies that occurrence.
        #expect(!weekly.isOverdue(
            lastRun: date(2026, 11, 8, 3, 5), now: date(2026, 11, 9, 9), calendar: calendar))
    }

    @Test func notOverdueBeforeTheNextScheduledTime() {
        #expect(!daily.isOverdue(
            lastRun: date(2026, 11, 8, 3, 1), now: date(2026, 11, 9, 2, 59), calendar: calendar))
        #expect(daily.isOverdue(
            lastRun: date(2026, 11, 8, 3, 1), now: date(2026, 11, 9, 3, 0), calendar: calendar))
    }
}
