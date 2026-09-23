import Foundation

/// A fixed reference day represents wall-clock components, not an execution date.
/// UTC avoids daylight-saving gaps changing a user's scheduled hour in the editor.
enum ScheduleClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func date(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))!
    }

    static func components(_ date: Date) -> (hour: Int, minute: Int) {
        (calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
}
