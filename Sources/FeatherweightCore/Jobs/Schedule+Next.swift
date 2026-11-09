import Foundation

extension Schedule {
    private var components: DateComponents {
        var components = DateComponents(hour: hour, minute: minute, second: 0)
        if frequency == .weekly { components.weekday = weekday }
        return components
    }

    /// The first scheduled time strictly after `date`.
    public func nextRun(after date: Date, calendar: Calendar) -> Date {
        calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
            ?? date.addingTimeInterval(frequency == .daily ? 86_400 : 7 * 86_400)
    }

    /// True when the most recent scheduled time at or before `now` is later than `lastRun`, or
    /// when there has been no run at all (for example the Mac slept through the scheduled time).
    public func isOverdue(lastRun: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let lastRun else { return true }
        // `nextDate(direction: .backward)` is strictly before its start, so start a second later
        // to include a scheduled time that is exactly `now`; if that overshoots `now`, step back
        // to the occurrence before it.
        // When a wall-clock time repeats (DST fall-back) the earlier occurrence is the scheduled
        // one; searching backward, that is the `.last` one found.
        func previous(before date: Date) -> Date? {
            calendar.nextDate(
                after: date, matching: components, matchingPolicy: .nextTime,
                repeatedTimePolicy: .last, direction: .backward)
        }
        guard var scheduled = previous(before: now.addingTimeInterval(1)) else { return false }
        if scheduled > now {
            guard let earlier = previous(before: scheduled) else { return false }
            scheduled = earlier
        }
        return scheduled > lastRun
    }
}
