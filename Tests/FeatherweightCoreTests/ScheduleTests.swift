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

    @Test func notOverdueOneSecondBeforeTheScheduledTime() {
        let before = date(2026, 11, 9, 3).addingTimeInterval(-0.5)
        #expect(!daily.isOverdue(lastRun: date(2026, 11, 8, 3, 1), now: before, calendar: calendar))
        #expect(daily.isOverdue(
            lastRun: date(2026, 11, 8, 3, 1), now: date(2026, 11, 9, 3), calendar: calendar))
    }

    @Test func overdueFallsBackToThePreviousOccurrenceJustBeforeTheNext() {
        // 02:59:59.5 on Nov 9: the Nov 9 03:00 slot has not arrived, but Nov 8 03:00 was missed.
        let now = date(2026, 11, 9, 3).addingTimeInterval(-0.5)
        #expect(daily.isOverdue(lastRun: date(2026, 11, 7, 3), now: now, calendar: calendar))
    }

    // MARK: DST (America/New_York)

    private let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func nyDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func springForwardRunsAtThreeEDTWhenTwoThirtyDoesNotExist() {
        let schedule = Schedule(frequency: .daily, weekday: 1, hour: 2, minute: 30)
        let next = schedule.nextRun(after: nyDate(2026, 3, 7, 12), calendar: newYork)  // 2026-03-08 skips 02:00-03:00
        #expect(next == nyDate(2026, 3, 8, 3))
        #expect(newYork.dateComponents([.hour, .minute], from: next) == DateComponents(hour: 3, minute: 0))
        // The day after is a normal 02:30.
        #expect(schedule.nextRun(after: next, calendar: newYork) == nyDate(2026, 3, 9, 2, 30))
    }

    @Test func fallBackRunsOnceWhenOneThirtyHappensTwice() {
        let schedule = Schedule(frequency: .daily, weekday: 1, hour: 1, minute: 30)
        // 2026-11-01 01:30 occurs as EDT and then again as EST.
        let first = schedule.nextRun(after: nyDate(2026, 11, 1, 0), calendar: newYork)
        let second = schedule.nextRun(after: first, calendar: newYork)

        #expect(first == nyDate(2026, 11, 1, 1, 30))
        #expect(second == nyDate(2026, 11, 2, 1, 30))
        // After the first run the repeated 01:30 is not overdue.
        let afterRepeat = first.addingTimeInterval(3_600 + 60)
        #expect(!schedule.isOverdue(lastRun: first.addingTimeInterval(30), now: afterRepeat, calendar: newYork))
    }
}
