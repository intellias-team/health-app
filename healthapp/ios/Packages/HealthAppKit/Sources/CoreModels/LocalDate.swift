import Foundation

/// A calendar date in the user's timezone, serialised as `yyyy-mm-dd` (docs/03 §3.1 "Transport").
///
/// Arithmetic is done on a proleptic-Gregorian day number so it is DST-safe and does not
/// depend on `Calendar` (which keeps this type cheap and deterministic in tests).
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-mm-dd`. Returns nil for malformed input.
    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The local date of `date` in `calendar` (defaults to the user's current calendar/timezone).
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public static func today(calendar: Calendar = .current) -> LocalDate {
        LocalDate(Date(), calendar: calendar)
    }

    /// `yyyy-mm-dd`
    public var iso: String {
        let y = String(format: "%04d", year)
        let m = String(format: "%02d", month)
        let d = String(format: "%02d", day)
        return "\(y)-\(m)-\(d)"
    }

    public var description: String { iso }

    /// Start of this day in `calendar`.
    public func startDate(calendar: Calendar = .current) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    /// Start of the next day (exclusive end of this day) in `calendar`.
    public func endDate(calendar: Calendar = .current) -> Date {
        adding(days: 1).startDate(calendar: calendar)
    }

    // MARK: Day-number arithmetic (Howard Hinnant's civil algorithms)

    /// Days since 1970-01-01.
    public var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(dayNumber z0: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: m <= 2 ? y + 1 : y, month: m, day: d)
    }

    public func adding(days: Int) -> LocalDate { LocalDate(dayNumber: dayNumber + days) }

    /// Number of days from `self` to `other` (positive when `other` is later).
    public func days(to other: LocalDate) -> Int { other.dayNumber - dayNumber }

    /// 1 = Monday … 7 = Sunday (ISO weekday).
    public var isoWeekday: Int {
        // 1970-01-01 was a Thursday (ISO 4).
        let w = ((dayNumber % 7) + 7 + 3) % 7 // 0 = Monday
        return w + 1
    }

    public var firstOfMonth: LocalDate { LocalDate(year: year, month: month, day: 1) }

    public var daysInMonth: Int {
        let next = month == 12 ? LocalDate(year: year + 1, month: 1, day: 1) : LocalDate(year: year, month: month + 1, day: 1)
        return firstOfMonth.days(to: next)
    }

    public func addingMonths(_ n: Int) -> LocalDate {
        let total = (year * 12 + (month - 1)) + n
        let y = total / 12
        let m = total % 12 + 1
        let first = LocalDate(year: y, month: m, day: 1)
        return LocalDate(year: y, month: m, day: min(day, first.daysInMonth))
    }

    /// Inclusive range of dates.
    public static func range(from: LocalDate, through to: LocalDate) -> [LocalDate] {
        guard from <= to else { return [] }
        return (from.dayNumber...to.dayNumber).map(LocalDate.init(dayNumber:))
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool { lhs.dayNumber < rhs.dayNumber }
}

extension LocalDate: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Accept a full timestamp too, taking its date prefix.
        guard let value = LocalDate(String(raw.prefix(10))) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected yyyy-mm-dd, got \(raw)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}
