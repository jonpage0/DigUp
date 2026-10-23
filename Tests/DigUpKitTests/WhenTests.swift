import Foundation
import Testing
@testable import DigUpKit

/// When (approved 2026-10-23): a file's date (`FileDate`: Photos' date taken, else the camera's, else when it was
/// modified), the filter's two forms (local days, and a window of days ending now), how a saved search keeps it, and
/// how it narrows a search with words, a list with none, and what an AI app sees.
@Suite struct WhenTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    /// A day, in tests.
    func day(_ text: String) throws -> SearchFilter.Day {
        try #require(SearchFilter.Day(text))
    }

    /// A moment of a day here (this Mac's time zone): `seconds` after it starts.
    func at(_ text: String, _ seconds: Double = 0) throws -> Double {
        try day(text).start().timeIntervalSince1970 + seconds
    }

    /// A file modified at `modified`, with a camera's date (`taken`, as EXIF writes it) and a date in Photos if given.
    @discardableResult
    func file(_ path: String, in store: IndexStore, kind: FileKind = .image, modified: Double, taken: String? = nil,
              photos: Double? = nil, words: String? = nil) throws -> Int64 {
        let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: modified,
                                            inode: UInt64.random(in: 1...UInt64.max >> 1), device: 1))
        if let photos { try store.addSegment(file: id, kind: .photosInfo, modality: .text, loc: photos, text: "photo") }
        if let words { try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: words) }
        try store.finish(id, state: "done", info: taken.map { ["taken": $0] } ?? [:])
        return id
    }

    func when(_ text: String) throws -> SearchFilter.When {
        try #require(SearchFilter.When(text))
    }

    /// The names of the files `filter` keeps, with no words, in the order they're listed.
    func listed(_ filter: SearchFilter, in store: IndexStore, kinds: Set<FileKind>? = nil, limit: Int = 100) throws
        -> [String] {
        try Searcher(store: store, loadVectors: false).search("", queryVector: nil, kinds: kinds, filter: filter,
                                                              limit: limit)
            .map { ($0.path as NSString).lastPathComponent }
    }

    @Test func aFilesDateIsPhotosElseTheCamerasElseWhenItWasModified() throws {
        let store = try IndexStore(directory: folder)
        // Each source on a month of its own: Photos' in July, the camera's in August, the file's own in September.
        try file("/L.photoslibrary/originals/A/A.jpeg", in: store, modified: try at("2026-09-12"),
                 taken: "2026:08:10 12:00:00", photos: try at("2026-07-10", 43_200))
        try file("/pictures/camera.jpg", in: store, modified: try at("2026-09-13"), taken: "2026:08:11 12:00:00")
        try file("/pictures/screenshot.png", in: store, kind: .screenshot, modified: try at("2026-09-10"))
        // A camera whose clock was never set: no date of its own, so the file's.
        try file("/pictures/unset.jpg", in: store, modified: try at("2026-09-11"), taken: "0000:00:00 00:00:00")
        func kept(_ text: String) throws -> Set<String> {
            Set(try listed(SearchFilter(when: try when(text)), in: store))
        }
        #expect(try kept("2026-07-01..2026-08-01") == ["A.jpeg"])
        #expect(try kept("2026-08-01..2026-09-01") == ["camera.jpg"])
        #expect(try kept("2026-09-01..2026-10-01") == ["screenshot.png", "unset.jpg"])
        // With no words, newest first by that date, not by when the files were modified.
        #expect(try Searcher(store: store, loadVectors: false).browse(SearchFilter(), kinds: nil, limit: 10)
            .map { ($0.path as NSString).lastPathComponent } == ["unset.jpg", "screenshot.png", "camera.jpg", "A.jpeg"])
    }

    @Test func aCamerasDateIsThisMacsTimeAndAnythingElseIsNoDate() throws {
        // EXIF keeps no time zone: its time is read as the time where the Mac is.
        for name in ["America/Chicago", "Asia/Kolkata", "Pacific/Auckland", "UTC"] {
            let zone = try #require(TimeZone(identifier: name))
            #expect(FileDate.seconds(exif: "2026:07:01 00:00:00", in: zone)
                    == (try day("2026-07-01")).start(in: zone).timeIntervalSince1970, "\(name)")
            #expect(FileDate.seconds(exif: "2026:01:15 13:45:30", in: zone)
                    == (try day("2026-01-15")).start(in: zone).timeIntervalSince1970 + 49_530, "\(name)")
        }
        #expect(FileDate.seconds(exif: "2024:02:29 23:59:59", in: .gmt) == 1_709_251_199)
        for bad in ["0000:00:00 00:00:00", "2026:02:30 12:00:00", "2025:02:29 12:00:00", "2026:13:01 12:00:00",
                    "2026:07:01 24:00:00", "2026:07:01 12:60:00", "2026:07:01 12:00:60", "2026-07-01 12:00:00",
                    "2026:07:01T12:00:00", "2026:07:01 12:00", "2026:07:01 12:00:00 ", "    :  :     :  :  ",
                    "２０２６:07:01 12:00:00", ""] {
            #expect(FileDate.seconds(exif: bad) == nil, "\(bad)")
        }
    }

    @Test func daysAreThisMacsAfterIsKeptAndBeforeIsnt() throws {
        let store = try IndexStore(directory: folder)
        // The file's own date and the camera's, on each side of the window's edges, here.
        try file("/f/june-last.txt", in: store, kind: .doc, modified: try at("2026-07-01", -1))
        try file("/f/july-first.txt", in: store, kind: .doc, modified: try at("2026-07-01"))
        try file("/f/july-last.txt", in: store, kind: .doc, modified: try at("2026-08-01", -0.001))
        try file("/f/august-first.txt", in: store, kind: .doc, modified: try at("2026-08-01"))
        try file("/f/june-last.jpg", in: store, modified: 0, taken: "2026:06:30 23:59:59")
        try file("/f/july-first.jpg", in: store, modified: 0, taken: "2026:07:01 00:00:00")
        try file("/f/july-last.jpg", in: store, modified: 0, taken: "2026:07:31 23:59:59")
        try file("/f/august-first.jpg", in: store, modified: 0, taken: "2026:08:01 00:00:00")
        func kept(_ text: String) throws -> Set<String> {
            Set(try listed(SearchFilter(when: try when(text)), in: store))
        }
        #expect(try kept("2026-07-01..2026-08-01")
                == ["july-first.txt", "july-last.txt", "july-first.jpg", "july-last.jpg"])
        // Either day left out.
        #expect(try kept("2026-08-01..") == ["august-first.txt", "august-first.jpg"])
        #expect(try kept("..2026-07-01") == ["june-last.txt", "june-last.jpg"])
        // One day.
        #expect(try kept("2026-07-31..2026-08-01") == ["july-last.txt", "july-last.jpg"])
        let bounds = try when("2026-07-01..2026-08-01").bounds(in: try #require(TimeZone(identifier: "Asia/Tokyo")))
        #expect(bounds.from == Date(timeIntervalSince1970: 1_782_831_600)   // 2026-06-30 15:00 UTC
                && bounds.to == Date(timeIntervalSince1970: 1_785_510_000))
    }

    @Test func theLastDaysEndNowAndRollWithIt() throws {
        let now = Date()
        let calendar = SearchFilter.Day.calendar(in: .current)
        let week = try #require(SearchFilter.When(lastDays: 7))
        let bounds = week.bounds(now: now)
        #expect(bounds.from == calendar.date(byAdding: .day, value: -7, to: now) && bounds.to == now)
        // A day later, a day later.
        let later = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        #expect(week.bounds(now: later).from == calendar.date(byAdding: .day, value: 1, to: try #require(bounds.from)))
        // Kept as it's searched, now: what's inside the past week, not what's before it or yet to come.
        let store = try IndexStore(directory: folder)
        func ago(_ days: Int, _ seconds: Double) throws -> Double {
            try #require(calendar.date(byAdding: .day, value: -days, to: now)).timeIntervalSince1970 + seconds
        }
        try file("/f/yesterday.txt", in: store, kind: .doc, modified: try ago(1, 0))
        try file("/f/a-week-ago-and-a-minute.txt", in: store, kind: .doc, modified: try ago(7, 60))
        try file("/f/a-week-ago-less-a-minute.txt", in: store, kind: .doc, modified: try ago(7, -60))
        try file("/f/later-today.txt", in: store, kind: .doc, modified: now.timeIntervalSince1970 + 3_600)
        #expect(Set(try listed(SearchFilter(when: week), in: store))
                == ["yesterday.txt", "a-week-ago-and-a-minute.txt"])
        #expect(SearchFilter.When.recent.map(\.title) == ["Past week", "Past month", "Past 3 months", "Past year"])
        #expect(SearchFilter.When(lastDays: 45)?.title == "Past 45 days")
    }

    @Test func aSavedSearchsWhenComesBackAsItWasAndBadOnesAreRefused() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func read(_ json: String) -> SearchFilter.When? {
            try? JSONDecoder().decode(SearchFilter.When.self, from: Data(json.utf8))
        }
        // As saved-searches.json keeps it (approved): local days, either left out, or a number of days.
        for json in [#"{"after":"2026-07-01","before":"2026-08-01"}"#, #"{"after":"2026-07-01"}"#,
                     #"{"before":"2026-08-01"}"#, #"{"lastDays":90}"#, #"{"lastDays":1}"#, #"{"lastDays":36500}"#,
                     #"{"after":"9999-12-31"}"#, #"{"before":"1583-01-02"}"#] {
            let when = try #require(read(json), "\(json)")
            #expect(String(decoding: try encoder.encode(when), as: UTF8.self) == json)
        }
        #expect(read(#"{"lastDays":90}"#) == SearchFilter.When(lastDays: 90))
        #expect(read(#"{"before":"2026-08-01","after":"2026-07-01"}"#) == (try when("2026-07-01..2026-08-01")))
        // Not the shape: no day, days the wrong way round or the same, a day the calendar doesn't have, of a year
        // before 1583 or written another way, a `before` that leaves no last day, a day that's null or not text, a
        // number of days that's 0, over 36,500, not whole or not a number, both forms at once, another key.
        for bad in ["{}", #"{"after":"2026-08-01","before":"2026-07-01"}"#,
                    #"{"after":"2026-07-01","before":"2026-07-01"}"#, #"{"after":"2026-02-30"}"#,
                    #"{"after":"2026-7-1"}"#, #"{"after":"2026/07/01"}"#, #"{"after":"2026-07-01T00:00:00Z"}"#,
                    #"{"after":" 2026-07-01"}"#, #"{"after":"+026-07-01"}"#, #"{"after":"٢٠٢٦-٠٧-٠١"}"#,
                    #"{"after":"0000-01-01"}"#, #"{"after":"1582-12-31"}"#, #"{"before":"1583-01-01"}"#,
                    #"{"before":"10000-01-01"}"#, #"{"after":null}"#, #"{"after":20260701}"#, #"{"lastDays":0}"#,
                    #"{"lastDays":36501}"#, #"{"lastDays":-1}"#, #"{"lastDays":1.5}"#, #"{"lastDays":"90"}"#,
                    #"{"lastDays":true}"#, #"{"lastDays":null}"#, #"{"lastDays":1e30}"#,
                    #"{"lastDays":90,"after":"2026-07-01"}"#, #"{"last_days":90}"#,
                    #"{"after":"2026-07-01","until":"2026-08-01"}"#, #""last:90""#, "90", "[]", "null"] {
            #expect(read(bad) == nil, "\(bad)")
        }
    }

    @Test func whenIsWrittenAsTheCLITakesIt() throws {
        #expect(SearchFilter.When("2026-07-01..2026-08-01")
                == SearchFilter.When(after: try day("2026-07-01"), before: try day("2026-08-01")))
        #expect(SearchFilter.When("2026-07-01..") == SearchFilter.When(after: try day("2026-07-01")))
        #expect(SearchFilter.When("..2026-08-01") == SearchFilter.When(before: try day("2026-08-01")))
        #expect(SearchFilter.When("last:90") == SearchFilter.When(lastDays: 90))
        for text in ["2026-07-01..2026-08-01", "2026-07-01..", "..2026-08-01", "last:1", "last:36500"] {
            #expect(SearchFilter.When(text)?.text == text)
        }
        for bad in ["", "..", "last:", "last:0", "last:36501", "last:-5", "last:+5", "last:9x", "last:1e3", "last: 9",
                    "2026-08-01..2026-07-01", "2026-07-01..2026-07-01", "2026-07-01", "2026-07-01...2026-08-01",
                    "2026-07-01..2026-08-01..", "july..", "90"] {
            #expect(SearchFilter.When(bad) == nil, "\(bad)")
        }
        #expect(try day("2026-12-31").adding(days: 1) == (try day("2027-01-01")))
        #expect(try day("2024-03-01").adding(days: -1) == (try day("2024-02-29")))
        // A range says its last day kept, not the day it stops before.
        let july = try when("2026-07-01..2026-08-01").title
        #expect(july.contains("31") && !july.contains("Aug") && july.contains(" – "))
        #expect(try when("2026-07-31..2026-08-01").title.contains("31") && !(try when("2026-07-31..2026-08-01").title)
            .contains(" – "))
        #expect(try when("2026-07-01..").title.hasPrefix("Since ") && when("..2026-08-01").title.hasPrefix("Before "))
    }

    // MARK: Custom Range…

    /// Where the Mac may be: here, a zone whose clocks skipped midnight (São Paulo's summer time began at 00:00 on
    /// 2018-11-04), zones that skipped a whole day crossing the date line (Samoa had no 2011-12-30, Kwajalein no
    /// 1993-08-21), and zones far east and west.
    static let zones = [TimeZone.current] + ["America/Sao_Paulo", "Pacific/Apia", "Pacific/Kwajalein", "Asia/Tokyo",
                                             "Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Chicago"]
        .compactMap(TimeZone.init(identifier:))

    /// The cold review's steps (WHEN-1): Custom Range… on a range that ends on the last day there is, its Through moved
    /// to that day, made a When whose `before` (10000-01-01) the strict reader refuses, and the saved searches with
    /// it couldn't be read. No range Custom Range… makes is one the reader refuses.
    @Test func noRangeCustomRangeMakesIsOneTheReaderRefuses() throws {
        let last = SearchFilter.Day.last
        #expect(SearchFilter.When(first: try day("9999-12-30"), last: last) == nil)
        // Every range made from what the pickers give, wherever the Mac is, at the ends of what they offer and just
        // past them (no day: the end keeps its day), is read back as written; Through's latest moment is on the day
        // before the last.
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for zone in Self.zones {
            let first = SearchFilter.Day.first.start(in: zone)
            #expect(SearchFilter.Day(last.start(in: zone).addingTimeInterval(-1), in: zone) == (try day("9999-12-30")))
            let edges = [first.addingTimeInterval(-1), first, try day("1583-01-02").start(in: zone),
                         try day("2011-12-30").start(in: zone), try day("2026-07-01").start(in: zone),
                         try day("9999-12-30").start(in: zone), last.start(in: zone),
                         last.start(in: zone).addingTimeInterval(86_400 * 2)]
            let days = edges.compactMap { SearchFilter.Day($0, in: zone) }
            #expect(days.count == edges.count - 2, "\(zone.identifier)")
            for from in days.map(Optional.some) + [nil] {
                for through in days.map(Optional.some) + [nil] {
                    guard let made = SearchFilter.When(first: from, last: through) else { continue }
                    #expect((try? decoder.decode(SearchFilter.When.self, from: encoder.encode(made))) == made,
                            "\(made.text) in \(zone.identifier)")
                }
            }
        }
    }

    /// The ranges the cold reviews opened in Custom Range…: "..0001-01-01" (came back "..0002-01-01"), and in Samoa
    /// "2011-12-29..2011-12-31", whose last day is the one Samoa skipped (came back "2011-12-29..2012-01-01").
    static let opened = ["2026-07-01..2026-08-01", "2026-07-31..2026-08-01", "..2026-08-01", "2026-07-01..",
                         "2018-11-03..2018-11-05", "..1583-01-02", "1583-01-01..1583-01-02", "9999-12-30..9999-12-31",
                         "9999-12-31..", "..0001-01-01", "1582-10-10..1582-10-20", "2011-12-29..2011-12-31",
                         "..2011-12-31", "2011-12-30..2011-12-31", "2011-12-30..", "1993-08-20..1993-08-22",
                         "1993-08-21..1993-08-22"]

    /// A range opened in it comes back as it was when its ends aren't touched, wherever the Mac is: they're kept as
    /// days, not as the moments its pickers show them at.
    @Test func aRangeOpenedInCustomRangeComesBackAsItWas() throws {
        for text in Self.opened {
            guard let opened = SearchFilter.When(text) else { continue }   // the reader refuses it: never opened
            #expect(SearchFilter.When(first: opened.firstDay, last: opened.lastDay) == opened, "\(text)")
        }
    }

    /// Its pickers show days in the Mac's zone (their calendar's Today is today here, cold review WHEN-3), and a day
    /// picked is the day shown here. A range whose ends are given to them and picked again as shown comes back as
    /// it was, but for the one old oddity: a day the Mac's zone skipped crossing the date line (Samoa's 2011-12-30,
    /// Kwajalein's 1993-08-21) has no moment here, its start is the next day's, and its picker shows the next day.
    @Test func aDayPickedIsTheDayItsPickerShowsHere() throws {
        let skipped: [String: SearchFilter.Day] = ["Pacific/Apia": try day("2011-12-30"),
                                                   "Pacific/Kwajalein": try day("1993-08-21")]
        func shown(_ day: SearchFilter.Day, in zone: TimeZone) -> SearchFilter.Day? {
            SearchFilter.Day(day.start(in: zone), in: zone)
        }
        for zone in Self.zones {
            let skip = skipped[zone.identifier]
            for text in ["1583-01-01", "2011-12-29", "2011-12-30", "2011-12-31", "1993-08-21", "2018-11-04",
                         "2024-02-29", "9999-12-31"] {
                let day = try day(text)
                #expect(shown(day, in: zone) == (day == skip ? day.adding(days: 1) : day),
                        "\(text) in \(zone.identifier)")
                // Any moment of a day here is that day.
                if day != skip, let next = day.adding(days: 1) {
                    #expect(SearchFilter.Day(next.start(in: zone).addingTimeInterval(-1), in: zone) == day,
                            "\(text) in \(zone.identifier)")
                }
            }
            for text in Self.opened {
                guard let opened = SearchFilter.When(text) else { continue }
                let picked = SearchFilter.When(first: opened.firstDay.flatMap { shown($0, in: zone) },
                                               last: opened.lastDay.flatMap { shown($0, in: zone) })
                let touchesSkip = skip.map { [opened.firstDay, opened.lastDay].contains($0) } ?? false
                #expect((picked == opened) != touchesSkip, "\(text) in \(zone.identifier)")
            }
        }
    }

    /// A day is in the years 1583 to 9999: ISO 8601's without prior agreement, and the ones this Mac's calendar
    /// writes as the kit does (Foundation's reads days before October 15, 1582 as Julian ones, ten days off). Nothing
    /// makes another: not a moment, not counting days on, not a range's end.
    @Test func aDayIsFrom1583To9999AndNothingMakesAnother() throws {
        let first = try day("1583-01-01"), last = try day("9999-12-31")
        for bad in ["0001-01-01", "1582-10-10", "1582-12-31", "0000-01-01"] {
            #expect(SearchFilter.Day(bad) == nil, "\(bad)")
        }
        #expect(SearchFilter.Day(year: 1582, month: 12, day: 31) == nil && SearchFilter.Day(year: 10_000, month: 1,
                                                                                             day: 1) == nil)
        #expect(first.adding(days: -1) == nil && last.adding(days: 1) == nil)
        #expect(first.adding(days: Int.min) == nil && last.adding(days: Int.max) == nil)
        #expect(first.adding(days: 3_074_245) == last && last.adding(days: -3_074_245) == first)
        #expect(try day("2024-02-28").adding(days: 2) == (try day("2024-03-01")))
        for zone in Self.zones {
            #expect(SearchFilter.Day(first.start(in: zone).addingTimeInterval(-1), in: zone) == nil)
            #expect(SearchFilter.Day(last.start(in: zone).addingTimeInterval(86_400 * 2), in: zone) == nil)
            // A day's start is on it, around a midnight the clocks skipped too.
            var day = try day("2018-11-02")
            for _ in 0..<5 {
                #expect(SearchFilter.Day(day.start(in: zone), in: zone) == day, "\(day.text) in \(zone.identifier)")
                day = try #require(day.adding(days: 1))
            }
            for edge in [first, last] { #expect(SearchFilter.Day(edge.start(in: zone), in: zone) == edge) }
        }
        for far in [-1e15, 1e15, -Double.infinity, .infinity, .nan] {
            #expect(SearchFilter.Day(Date(timeIntervalSince1970: far), in: .gmt) == nil, "\(far)")
        }
        // A range's `before` leaves it a last day.
        #expect(SearchFilter.When("..1583-01-01") == nil && SearchFilter.When("..1583-01-02")?.lastDay == first)
        #expect(SearchFilter.When("..0001-01-01") == nil)
    }

    @Test func whenNarrowsWordsRequiredWordsAndAListOfOneKind() throws {
        let store = try IndexStore(directory: folder)
        let beach = "a day at the beach"
        try file("/f/beach-july.txt", in: store, kind: .doc, modified: try at("2026-07-10"), words: beach)
        try file("/f/beach-june.txt", in: store, kind: .doc, modified: try at("2026-06-10"), words: beach)
        try file("/f/forest-july.txt", in: store, kind: .doc, modified: try at("2026-07-11"), words: "the forest")
        try file("/f/july.png", in: store, kind: .screenshot, modified: try at("2026-07-12"))
        try file("/f/early-july.png", in: store, kind: .screenshot, modified: try at("2026-07-02"))
        try file("/f/june.png", in: store, kind: .screenshot, modified: try at("2026-06-12"))
        let july = SearchFilter(when: try when("2026-07-01..2026-08-01"))
        let searcher = try Searcher(store: store, loadVectors: false)
        func found(_ query: String) throws -> [String] {
            try searcher.search(query, queryVector: nil, filter: july).map { ($0.path as NSString).lastPathComponent }
        }
        #expect(try found("beach") == ["beach-july.txt"])
        #expect(try found("+beach day") == ["beach-july.txt"])
        // With no words, a kind and When list that window, newest first ("screenshots from July").
        #expect(try listed(july, in: store, kinds: [.screenshot]) == ["july.png", "early-july.png"])
        #expect(try listed(july, in: store, kinds: [.screenshot], limit: 1) == ["july.png"])
        #expect(!july.isEmpty && SearchFilter(when: SearchFilter.When(lastDays: 7)).query != nil)
    }

    @Test func anAIAppsWhenKeepsOnlyWhatItMaySee() throws {
        // A library's picture and a note, both from July and both saying "beach"; the AI app may not see Photos.
        let store = try IndexStore(directory: folder)
        let library = "/L.photoslibrary/originals/F/\(UUID().uuidString).jpeg"
        try file(library, in: store, modified: try at("2026-09-01"), photos: try at("2026-07-04"), words: "beach")
        try file("/f/beach.txt", in: store, kind: .doc, modified: try at("2026-07-05"), words: "beach")
        try file("/f/beach-june.txt", in: store, kind: .doc, modified: try at("2026-06-05"), words: "beach")
        var seen = SearchFilter(when: try when("2026-07-01..2026-08-01"))
        seen.photosOnly = []
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("beach", queryVector: nil, filter: seen).map(\.path) == ["/f/beach.txt"])
        #expect(try searcher.browse(seen, kinds: nil, limit: 10).map(\.path) == ["/f/beach.txt"])
        #expect(try store.counts(keeping: seen) == [.doc: ["done": 1]])
        // With Photos allowed, the library's picture is in July by Photos' date, not September's file.
        seen.photosOnly = nil
        #expect(try searcher.browse(seen, kinds: nil, limit: 10).map(\.path) == ["/f/beach.txt", library])
    }

    /// A saved search with a When, as the kit reads, runs and says it for the app's Saved menu and `digup mcp`'s
    /// `saved` alike (`SavedSearch`): read strictly and written as it was, at most one When; run, it keeps what the
    /// window's When token keeps; its line names it as the token does; and no AI apps' switch keeps it from one.
    @Test func aSavedSearchWithWhenRunsAndIsSaidThroughTheKit() throws {
        func file(_ filters: String) -> Data {
            Data(#"""
                { "version": 1, "searches": [ { "id": "\#(UUID().uuidString)", "name": "July at the beach",
                  "query": "beach", "kind": null, "filters": [\#(filters)], "saved": "2026-10-23T08:00:00Z" } ] }
                """#.utf8)
        }
        let july = #"{ "when": { "after": "2026-07-01", "before": "2026-08-01" } }"#
        let saved = try #require(try SavedSearch.searches(in: file(july)).first)
        #expect(saved.filters == [.when(try when("2026-07-01..2026-08-01"))])
        let written = try SavedSearch.data([saved])
        #expect(try SavedSearch.searches(in: written) == [saved])
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let filters = try #require(((object["searches"] as? [[String: Any]])?.first)?["filters"] as? [[String: Any]])
        #expect(filters.first?["when"] as? [String: String] == ["after": "2026-07-01", "before": "2026-08-01"])
        #expect(throws: SavedSearch.FileError.notWellFormed) {
            try SavedSearch.searches(in: file(july + #", { "when": { "lastDays": 30 } }"#))
        }
        #expect(throws: DecodingError.self) {
            try SavedSearch.searches(in: file(#"{ "when": { "after": "2026-08-01", "before": "2026-07-01" } }"#))
        }

        // Run: what the searcher may see stays as it was, and the When narrows it.
        let store = try IndexStore(directory: folder)
        try self.file("/f/beach-july.txt", in: store, kind: .doc, modified: try at("2026-07-10"), words: "beach")
        try self.file("/f/beach-june.txt", in: store, kind: .doc, modified: try at("2026-06-10"), words: "beach")
        try self.file("/f/july.png", in: store, kind: .screenshot, modified: try at("2026-07-12"))
        var base = SearchFilter()
        base.photosOnly = []
        let filter = saved.searchFilter(narrowing: base, people: [], albums: [], myDevices: [], blurring: .off,
                                        favorites: { [] })
        #expect(filter.when == (try when("2026-07-01..2026-08-01")) && filter.photosOnly == [])
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search(saved.query, queryVector: nil, filter: filter).map(\.path) == ["/f/beach-july.txt"])
        #expect(try searcher.browse(filter, kinds: nil, limit: 10).map(\.path) == ["/f/july.png", "/f/beach-july.txt"])

        // Said as Save This Search… says it, the When as its token; and it needs no AI apps' switch.
        #expect(saved.summary(people: [], albums: []) == "“beach” · All kinds · Jul 1 – Jul 31, 2026")
        #expect(SavedSearch.Filter.when(try when("last:30")).title == SearchFilter.When(lastDays: 30)?.title)
        #expect(saved.aiUses.isEmpty)
    }
}
