import Foundation

/// Turns what you would actually type into a date.
///
/// Pure and `nonisolated` so the whole vocabulary is testable as a table.
/// Accepts, case-insensitively:
///
/// - `today`, `tomorrow`, `tom`, `yesterday`
/// - a weekday name or prefix — `mon`, `friday` — meaning the *next* one
/// - `+3d`, `3d`, `+2w`, `1m` — relative offsets
/// - `2026-11-05`, `11/05`, `5 nov`, `nov 5`
/// - `none`, `clear`, `-` — clear the date
enum DateParsing {
    enum Result: Equatable {
        case date(CalendarDate)
        case clear
    }

    nonisolated static func parse(
        _ input: String,
        today: CalendarDate = .today(),
        calendar: Calendar = .current
    ) -> Result? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        if ["none", "clear", "-", "never", "no date"].contains(text) { return .clear }
        if ["today", "tod"].contains(text) { return .date(today) }
        if ["tomorrow", "tom", "tmr"].contains(text) {
            return today.adding(days: 1, calendar: calendar).map(Result.date)
        }
        if text == "yesterday" {
            return today.adding(days: -1, calendar: calendar).map(Result.date)
        }
        if ["next week", "nextweek"].contains(text) {
            return today.adding(days: 7, calendar: calendar).map(Result.date)
        }

        if let offset = parseOffset(text),
           let moved = today.adding(days: offset, calendar: calendar) {
            return .date(moved)
        }
        if let weekday = parseWeekday(text),
           let moved = nextWeekday(weekday, from: today, calendar: calendar) {
            return .date(moved)
        }
        if let explicit = parseExplicit(text, today: today, calendar: calendar) {
            return .date(explicit)
        }
        return nil
    }

    // MARK: Pieces

    /// `+3d`, `3d`, `2w`, `+1m`. A bare number means days.
    private nonisolated static func parseOffset(_ text: String) -> Int? {
        var body = text
        if body.hasPrefix("+") { body.removeFirst() }
        guard !body.isEmpty else { return nil }

        let unit = body.last!
        if unit.isNumber {
            return Int(body)
        }
        let digits = String(body.dropLast())
        guard let value = Int(digits) else { return nil }
        switch unit {
        case "d": return value
        case "w": return value * 7
        // Calendar months vary; 30 days is the honest approximation for a
        // shortcut whose whole point is speed, and the explicit form is one
        // keystroke away when it matters.
        case "m": return value * 30
        default: return nil
        }
    }

    private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// 1 = Sunday, matching `Calendar.component(.weekday:)`.
    private nonisolated static func parseWeekday(_ text: String) -> Int? {
        guard text.count >= 3 else { return nil }
        for (index, name) in weekdayNames.enumerated() where name.hasPrefix(text) {
            return index + 1
        }
        return nil
    }

    /// The next occurrence, never today — typing "friday" on a Friday means the
    /// one coming, otherwise the word would be a slower way to type "today".
    private nonisolated static func nextWeekday(
        _ weekday: Int, from today: CalendarDate, calendar: Calendar
    ) -> CalendarDate? {
        guard let base = today.date(calendar: calendar) else { return nil }
        let current = calendar.component(.weekday, from: base)
        var delta = weekday - current
        if delta <= 0 { delta += 7 }
        return today.adding(days: delta, calendar: calendar)
    }

    /// `2026-11-05`, `11/05`, `5 nov`, `nov 5`.
    private nonisolated static func parseExplicit(
        _ text: String, today: CalendarDate, calendar: Calendar
    ) -> CalendarDate? {
        // `CalendarDate(wireValue:)` only range-checks month and day, so it
        // happily accepts 2026-02-30. Everything typed goes through
        // `validated`, which rejects a date the calendar does not have rather
        // than letting Calendar silently normalise it to 3 March.
        if text.count >= 10, let iso = CalendarDate(wireValue: text) {
            return validated(year: iso.year, month: iso.month, day: iso.day)
        }

        let separators = CharacterSet(charactersIn: "/-. ")
        let parts = text.components(separatedBy: separators).filter { !$0.isEmpty }

        if parts.count == 3, let year = Int(parts[0]), year > 1000 {
            if let month = Int(parts[1]), let day = Int(parts[2]) {
                return validated(year: year, month: month, day: day)
            }
        }
        if parts.count == 2 {
            // Numeric `11/05` is month/day, and rolls to next year if past.
            if let first = Int(parts[0]), let second = Int(parts[1]) {
                return rollForward(month: first, day: second, today: today)
            }
            // `5 nov` or `nov 5`.
            if let day = Int(parts[0]), let month = monthNumber(parts[1]) {
                return rollForward(month: month, day: day, today: today)
            }
            if let month = monthNumber(parts[0]), let day = Int(parts[1]) {
                return rollForward(month: month, day: day, today: today)
            }
        }
        return nil
    }

    private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    private nonisolated static func monthNumber(_ text: String) -> Int? {
        guard text.count >= 3 else { return nil }
        for (index, name) in monthNames.enumerated() where name.hasPrefix(text) {
            return index + 1
        }
        return nil
    }

    /// A month/day with no year means the next time that date happens.
    private nonisolated static func rollForward(
        month: Int, day: Int, today: CalendarDate
    ) -> CalendarDate? {
        guard let thisYear = validated(year: today.year, month: month, day: day) else { return nil }
        if thisYear < today {
            return validated(year: today.year + 1, month: month, day: day)
        }
        return thisYear
    }

    private nonisolated static func validated(year: Int, month: Int, day: Int) -> CalendarDate? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let candidate = CalendarDate(year: year, month: month, day: day)
        // Rejects 31 February: round-tripping through Calendar would silently
        // normalise it to 3 March, and a due date you did not pick is worse
        // than an error.
        guard let resolved = candidate.date(),
              CalendarDate(resolved) == candidate
        else { return nil }
        return candidate
    }
}
