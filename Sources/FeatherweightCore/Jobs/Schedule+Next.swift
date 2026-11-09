import Foundation

extension Schedule {
    private var components: DateComponents {
        var components = DateComponents(hour: hour, minute: minute, second: 0)
        if frequency == .weekly { components.weekday = weekday }
        return components
    }

    /// The first scheduled time strictly after `date`.
    public func nextRun(after date: Date, calendar: Calendar) -> Date {
        calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(frequency == .daily ? 86_400 : 7 * 86_400)
    }

    /// True when the most recent scheduled time at or before `now` is later than `lastRun`, or
    /// when there has been no run at all (for example the Mac slept through the scheduled time).
    public func isOverdue(lastRun: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let lastRun else { return true }
        // `nextDate(direction: .backward)` is strictly before its start, so start a second later
        // to include a scheduled time that is exactly `now`.
        guard let scheduled = calendar.nextDate(
            after: now.addingTimeInterval(1), matching: components, matchingPolicy: .nextTime,
            direction: .backward)
        else { return false }
        return scheduled > lastRun
    }
}
