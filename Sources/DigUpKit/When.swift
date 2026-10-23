import Foundation

/// A file's date, as search goes by it (approved 2026-10-23 with When): when Photos says a library's file was taken,
/// else when the camera says a picture was taken (EXIF's date, in this Mac's time: EXIF keeps no time zone), else when
/// the file was last modified (a screenshot on disk: when it was made). The When filter keeps files by it, and a search
/// with no words lists what it keeps newest first by it (`Searcher.browse`). The rule is kept here alone: Jon may
/// still change it.
enum FileDate {
    /// The SQL function `sql` reads a camera's date with (`seconds(exif:)`, in the time zone this Mac is in when it's
    /// called), defined on each of the index's connections (`IndexStore`).
    static let exifFunction = "digup_exif_seconds"

    /// The date of the `files` row named `file` in a query, as SQL: seconds since 1970.
    static func sql(of file: String) -> String {
        "coalesce((SELECT loc FROM segments WHERE file = \(file).id AND kind = '\(SegmentKind.photosInfo.rawValue)' "
            + "LIMIT 1), \(exifFunction)(json_extract(\(file).info, '$.taken')), \(file).mtime)"
    }

    /// When a camera says a picture was taken, as EXIF writes it ("2024:05:01 12:00:00", the indexer's info "taken"),
    /// read as `zone`'s time then: seconds since 1970. Nil for anything that isn't a time of a day of the calendar: a
    /// camera whose clock was never set writes "0000:00:00 00:00:00".
    static func seconds(exif: String, in zone: TimeZone = .current) -> Double? {
        let bytes = Array(exif.utf8)
        guard bytes.count == 19, [4, 7, 13, 16].allSatisfy({ bytes[$0] == UInt8(ascii: ":") }),
              bytes[10] == UInt8(ascii: " ") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              isDay(year: year, month: month, day: day), hour < 24, minute < 60, second < 60 else { return nil }
        let wall = Double(days(year: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second)
        // The zone's offset then: guessed at the time read as UTC's, then taken at the moment that guess gives.
        let guess = wall - Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: wall)))
        return wall - Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: guess)))
    }

    /// Whether it's a day of the (proleptic Gregorian) calendar, from year 1 to 9999: what a camera's date can be.
    static func isDay(year: Int, month: Int, day: Int) -> Bool {
        guard (1...9999).contains(year), (1...12).contains(month) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[month - 1]).contains(day)
    }

    /// Days from 1970-01-01 to that day (Howard Hinnant's `days_from_civil`).
    static func days(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1   // from March 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The day `days` days from 1970-01-01 (Howard Hinnant's `civil_from_days`, the inverse of `days`), for days of
    /// years 1 to 9999.
    static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468   // from 0000-03-01
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)   // from March 1
        let monthFromMarch = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
        let month = monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

extension SearchFilter {
    /// A day of the calendar, as the When filter takes it: "2026-07-01". Not a moment: where it starts depends on the
    /// time zone it's taken in (`start(in:)`), this Mac's. Only days of `years` are made, however a day is come to.
    public struct Day: Sendable, Hashable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int

        /// The years a day can be in: ISO 8601's without prior agreement, and the ones this Mac's calendar writes as
        /// the kit does. Foundation's Gregorian calendar reads days before October 15, 1582 as Julian ones, ten days
        /// off: a date picker given an earlier day shows, and gives back, another one.
        public static let years = 1583...9999
        public static let first = Day(valid: years.lowerBound, month: 1, day: 1)
        public static let last = Day(valid: years.upperBound, month: 12, day: 31)

        /// Nil for a day the calendar doesn't have (February 30), or a year outside `years`.
        public init?(year: Int, month: Int, day: Int) {
            guard Self.years.contains(year), FileDate.isDay(year: year, month: month, day: day) else { return nil }
            self.init(valid: year, month: month, day: day)
        }

        /// For a day known to be one of `years`.
        private init(valid year: Int, month: Int, day: Int) {
            (self.year, self.month, self.day) = (year, month, day)
        }

        /// From `text` written exactly so: "2026-07-01" (four digits, two, two).
        public init?(_ text: String) {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.map(\.count) == [4, 2, 2],
                  parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isWholeNumber } }),
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
            self.init(year: year, month: month, day: day)
        }

        /// The day `date` is on in `zone` (the clock's time there then, by its offset from UTC then); nil when that's
        /// no day of `years`.
        public init?(_ date: Date, in zone: TimeZone = .current) {
            let local = (date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))) / 86_400
            // Compared as a number first: one far out (or not a number) is no day, and isn't made a whole one.
            guard (Double(Self.first.daysSince1970)...Double(Self.last.daysSince1970)).contains(local.rounded(.down))
            else { return nil }
            self.init(daysSince1970: Int(local.rounded(.down)))
        }

        /// The day `days` days from 1970-01-01; nil when that's no day of `years`.
        private init?(daysSince1970 days: Int) {
            guard (Self.first.daysSince1970...Self.last.daysSince1970).contains(days) else { return nil }
            let (year, month, day) = FileDate.civil(fromDays: days)
            self.init(year: year, month: month, day: day)
        }

        /// Days from 1970-01-01 to it.
        var daysSince1970: Int {
            FileDate.days(year: year, month: month, day: day)
        }

        public var text: String {
            String(format: "%04d-%02d-%02d", year, month, day)
        }

        /// The day `count` days after it (before it, for a count below 0); nil past the first or the last day.
        public func adding(days count: Int) -> Day? {
            let (days, overflow) = daysSince1970.addingReportingOverflow(count)
            return overflow ? nil : Day(daysSince1970: days)
        }

        /// When it starts in `zone`: its midnight, or its first moment where a change of the clocks skips midnight. A
        /// day the zone skipped altogether crossing the date line (Samoa's 2011-12-30, Kwajalein's 1993-08-21) has no
        /// moment there: it gets the next day's start, which `init(_:in:)` reads as the next day.
        public func start(in zone: TimeZone = .current) -> Date {
            Self.calendar(in: zone).date(from: DateComponents(year: year, month: month, day: day))
                ?? Date(timeIntervalSince1970: Double(daysSince1970 * 86_400))
        }

        /// The zone a date picker shows days in (Custom Range…'s), whatever zone the Mac is in: UTC, where every day
        /// of the calendar is a day of the clock. In a zone that skipped a day no moment shows it, so a range ending on
        /// it can't be shown there, and came back a day longer (cold review WHEN-2).
        public static let pickerZone = TimeZone.gmt

        /// The moment a date picker in `pickerZone` is given to show it: its start there.
        public var pickerDate: Date { start(in: Self.pickerZone) }

        /// The day a date picker in `pickerZone` shows for `date`; nil when that's no day of `years`.
        public init?(pickerDate date: Date) {
            self.init(date, in: Self.pickerZone)
        }

        static func calendar(in zone: TimeZone) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar
        }

        public static func < (first: Day, second: Day) -> Bool {
            (first.year, first.month, first.day) < (second.year, second.month, second.day)
        }
    }

    /// What the When filter keeps (approved 2026-10-23: "we definitely need date range filtering", "relative and
    /// absolute"): files whose date (`FileDate`) is on local days of this Mac from `after` (included) to `before`
    /// (not), either left out but not both; or within the last so many days, a window ending now that rolls with time
    /// (a saved "past 3 months" stays the past 3 months). A saved search keeps it as `{"after": "2026-07-01",
    /// "before": "2026-08-01"}` or `{"lastDays": 90}` (its `Codable`); `digup mcp` takes `{after, before}` or
    /// `{last_days}`.
    public struct When: Sendable, Hashable {
        public enum Span: Sendable, Hashable {
            case days(after: Day?, before: Day?)
            case lastDays(Int)
        }

        public let span: Span

        /// The most days a window ending now can have: a hundred years.
        public static let mostDays = 36_500
        /// The When menu's: the past week, month, 3 months and year.
        public static let recent: [When] = [7, 30, 90, 365].compactMap { When(lastDays: $0) }

        /// Nil with neither day, `after` not before `before`, or a `before` that leaves no last day (`Day.first`): a
        /// range of days has a first one and a last one, as Custom Range… shows it, wherever either is open.
        public init?(after: Day? = nil, before: Day? = nil) {
            guard after != nil || before != nil, before != Day.first else { return nil }
            if let after, let before, after >= before { return nil }
            span = .days(after: after, before: before)
        }

        /// Nil outside 1 to `mostDays`.
        public init?(lastDays: Int) {
            guard (1...Self.mostDays).contains(lastDays) else { return nil }
            span = .lastDays(lastDays)
        }

        /// As `digup search --when` and the app's debug flags write it (`text`): "2026-07-01..2026-08-01" (either day
        /// left out: "2026-07-01..", "..2026-08-01"), or "last:90".
        public init?(_ text: String) {
            if text.hasPrefix(Self.lastPrefix) {
                let number = text.dropFirst(Self.lastPrefix.count)
                guard number.allSatisfy({ $0.isASCII && $0.isWholeNumber }), let days = Int(number) else { return nil }
                self.init(lastDays: days)
                return
            }
            let days = text.components(separatedBy: "..")
            guard days.count == 2 else { return nil }
            func day(_ text: String) -> Day?? {
                if text.isEmpty { return .some(nil) }
                guard let day = Day(text) else { return nil }
                return .some(day)
            }
            guard let after = day(days[0]), let before = day(days[1]) else { return nil }
            self.init(after: after, before: before)
        }

        /// The days from `first` to `last`, both kept, as the window's Custom Range… holds them, either left out but
        /// not both. Civil days, not moments: a range opened there and used as it is comes back as it was, wherever
        /// the Mac is (`firstDay` and `lastDay` are what it opens with). Nil for a `last` that's the last day (no day
        /// after it to stop before), or `first` after `last`: every When made so is one the strict reader reads.
        public init?(first: Day?, last: Day?) {
            var before: Day?
            if let last {
                guard let next = last.adding(days: 1) else { return nil }
                before = next
            }
            self.init(after: first, before: before)
        }

        /// The first day it keeps (`after`), as Custom Range… shows it; nil when it's open at that end, or for the
        /// last so many days.
        public var firstDay: Day? {
            guard case .days(let after?, _) = span else { return nil }
            return after
        }

        /// The last day it keeps, the day before `before`, as Custom Range… shows it; nil when it's open at that end,
        /// or for the last so many days. (`init` keeps a `before` after `Day.first`, so it has one.)
        public var lastDay: Day? {
            guard case .days(_, let before?) = span else { return nil }
            return before.adding(days: -1)
        }

        private static let lastPrefix = "last:"

        public var text: String {
            switch span {
            case .days(let after, let before): (after?.text ?? "") + ".." + (before?.text ?? "")
            case .lastDays(let days): Self.lastPrefix + String(days)
            }
        }

        /// Where it starts and ends in `zone` at `now`: from (included) to (not), nil where it's open.
        public func bounds(now: Date = Date(), in zone: TimeZone = .current) -> (from: Date?, to: Date?) {
            switch span {
            case .days(let after, let before): (after?.start(in: zone), before?.start(in: zone))
            case .lastDays(let days): (Day.calendar(in: zone).date(byAdding: .day, value: -days, to: now), now)
            }
        }

        /// The files it keeps now, as a query of their ids, and the values it takes. BETWEEN reads a file's date once
        /// (`FileDate.sql` is a lookup and a JSON read), and the moment before `to` is the last it keeps.
        var query: (sql: String, values: [SQLValue]) {
            let (from, to) = bounds()
            return ("SELECT f.id FROM files f WHERE \(FileDate.sql(of: "f")) BETWEEN ? AND ?",
                    [.double(from?.timeIntervalSince1970 ?? -.infinity),
                     .double(to.map { $0.timeIntervalSince1970.nextDown } ?? .infinity)])
        }

        /// What a token and a saved search's line call it: "Past week", "Past month", "Past 3 months", "Past year",
        /// "Past 45 days"; "Jul 1 – Jul 31, 2026" (the last day kept, not `before`), "Jul 1, 2026" for one day,
        /// "Since Jul 1, 2026", "Before Aug 1, 2026" (in the user's language's way of writing a date).
        public var title: String {
            switch span {
            case .lastDays(let days):
                switch days {
                case 1: "Past day"
                case 7: "Past week"
                case 30: "Past month"
                case 90: "Past 3 months"
                case 365: "Past year"
                default: "Past \(days) days"
                }
            case .days(let after?, _?):   // `init` keeps a last day before any `before`
                lastDay.map { Self.written(from: after, through: $0) } ?? ""
            case .days(let after?, nil): "Since \(Self.written(after))"
            case .days(nil, let before?): "Before \(Self.written(before))"
            case .days(nil, nil): ""   // not a When (`init` turns it down)
            }
        }

        /// "Jul 1 – Jul 31, 2026", "Dec 20, 2025 – Jan 5, 2026", or "Jul 1, 2026" for one day.
        private static func written(from first: Day, through last: Day) -> String {
            if last == first { return written(first) }
            return "\(written(first, year: last.year != first.year)) – \(written(last))"
        }

        /// "Jul 1, 2026", or "Jul 1".
        private static func written(_ day: Day, year: Bool = true) -> String {
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            if year { style = style.year() }
            style.timeZone = .gmt
            return day.start(in: .gmt).formatted(style)
        }
    }
}

/// A When as a saved search keeps it (`saved-searches.json`'s `{"when": …}`, approved 2026-10-23): `{"after":
/// "2026-07-01", "before": "2026-08-01"}`, either day left out, or `{"lastDays": 90}`. Read strictly, as the app reads
/// the file: another key, both forms at once, a day that's null, not written "YYYY-MM-DD" or not of the years 1583 to
/// 9999 (`Day.years`), days the wrong way round, a `before` of 1583-01-01 (no last day), or a number of days that
/// isn't a whole number from 1 to 36,500 aren't this shape.
extension SearchFilter.When: Codable {
    private enum CodingKeys: String, CodingKey {
        case after, before, lastDays
    }

    public init(from decoder: any Decoder) throws {
        let keys = Set(try decoder.container(keyedBy: JSONKey.self).allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wrong = DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription:
            "a when is {after, before} in days YYYY-MM-DD of the years \(SearchFilter.Day.years.lowerBound) to "
            + "\(SearchFilter.Day.years.upperBound), either left out, after earlier than before, before after the "
            + "first day, or {lastDays} from 1 to \(Self.mostDays)"))
        if keys == [CodingKeys.lastDays.rawValue] {
            guard let when = Self(lastDays: try container.decode(Int.self, forKey: .lastDays)) else { throw wrong }
            self = when
            return
        }
        guard keys.isSubset(of: [CodingKeys.after.rawValue, CodingKeys.before.rawValue]) else { throw wrong }
        func day(_ key: CodingKeys) throws -> SearchFilter.Day? {
            guard container.contains(key) else { return nil }
            guard let day = SearchFilter.Day(try container.decode(String.self, forKey: key)) else { throw wrong }
            return day
        }
        guard let when = Self(after: try day(.after), before: try day(.before)) else { throw wrong }
        self = when
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch span {
        case .days(let after, let before):
            try container.encodeIfPresent(after?.text, forKey: .after)
            try container.encodeIfPresent(before?.text, forKey: .before)
        case .lastDays(let days):
            try container.encode(days, forKey: .lastDays)
        }
    }
}
