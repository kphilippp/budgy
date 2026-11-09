import Foundation

/// A span of time from one payday up to (not including) the next.
struct PayPeriod: Equatable {
    var start: Date
    var end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    var dayCount: Int {
        max(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0, 1)
    }
}

/// Date math for your pay schedule.
struct PayCycle {
    var frequency: Frequency
    var anchor: Date
    var calendar: Calendar = .current

    init(schedule: PaySchedule, calendar: Calendar = .current) {
        self.frequency = schedule.frequency
        self.anchor = calendar.startOfDay(for: schedule.anchorPayDate)
        self.calendar = calendar
    }

    init(frequency: Frequency, anchor: Date, calendar: Calendar = .current) {
        self.frequency = frequency
        self.anchor = calendar.startOfDay(for: anchor)
        self.calendar = calendar
    }

    /// The pay period containing `date`.
    func period(containing date: Date) -> PayPeriod {
        let day = calendar.startOfDay(for: date)
        var start = anchor
        var guardCount = 0
        while start > day && guardCount < 2000 {
            start = frequency.retreat(start, calendar: calendar)
            guardCount += 1
        }
        var next = frequency.advance(start, calendar: calendar)
        while next <= day && guardCount < 4000 {
            start = next
            next = frequency.advance(start, calendar: calendar)
            guardCount += 1
        }
        return PayPeriod(start: start, end: next)
    }

    /// The period `offset` periods away from the one containing `date`.
    func period(offset: Int, from date: Date = .now) -> PayPeriod {
        var period = period(containing: date)
        if offset > 0 {
            for _ in 0..<offset { period = self.period(containing: period.end) }
        } else if offset < 0 {
            for _ in 0..<(-offset) {
                period = self.period(containing: calendar.date(byAdding: .day, value: -1, to: period.start) ?? period.start)
            }
        }
        return period
    }

    func nextPayday(after date: Date = .now) -> Date {
        period(containing: date).end
    }

    /// Paydays in `[start, end)`.
    func paydays(from start: Date, to end: Date) -> [Date] {
        var result: [Date] = []
        var payday = period(containing: start).start
        if payday < calendar.startOfDay(for: start) {
            payday = frequency.advance(payday, calendar: calendar)
        }
        var guardCount = 0
        while payday < end && guardCount < 500 {
            result.append(payday)
            payday = frequency.advance(payday, calendar: calendar)
            guardCount += 1
        }
        return result
    }
}

/// A calendar month as a period.
extension PayPeriod {
    static func month(containing date: Date, offset: Int = 0, calendar: Calendar = .current) -> PayPeriod {
        let shifted = calendar.date(byAdding: .month, value: offset, to: date) ?? date
        let interval = calendar.dateInterval(of: .month, for: shifted)
        return PayPeriod(start: interval?.start ?? shifted, end: interval?.end ?? shifted)
    }
}
