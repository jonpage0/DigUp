import Foundation
import Testing
@testable import DigUpKit

/// The searches saved in the app's Saved menu as the kit reads, runs and says them (`SavedSearch`), for the app and for
/// `digup mcp` alike.
@Suite struct SavedSearchTests {
    static let library = "/Users/jon/Pictures/Photos Library.photoslibrary"

    /// A search as `saved-searches.json` keeps it, with these filters (JSON).
    static func entry(_ filters: String = "", name: String = "a search", id: String = UUID().uuidString) -> String {
        """
        { "id": "\(id)", "name": "\(name)", "query": "beach", "kind": null, "filters": [\(filters)],
          "saved": "2026-10-22T19:55:00Z" }
        """
    }

    /// `saved-searches.json` with these searches.
    static func file(_ entries: String...) -> Data {
        Data(#"{ "version": 1, "searches": [\#(entries.joined(separator: ", "))] }"#.utf8)
    }

    /// The approved example (PHOTOS-FACTS-SCHEMA.md, "saved searches"), with every element added since: Match by
    /// written by hand, out of its order.
    static let tati = """
        { "id": "5D0C2E8A-6A3B-4C55-9B0E-2F7F7C1E4A10", "name": "Tati at the beach", "query": "+beach",
          "kind": "images",
          "filters": [
            { "person": { "name": "Tatiana Rotari", "photos": [ { "library": "\(library)", "uuid": "P-TATI" } ] } },
            { "album": { "title": "Florida", "folders": ["Trips", "2024"],
                         "photos": [ { "library": "\(library)", "uuid": "A-FLORIDA" } ] } },
            { "photosFavorites": true }, { "digupFavorites": true }, { "from": "mine" },
            { "area": { "south": 25.10, "west": -80.90, "north": 26.20, "east": -79.80 } },
            { "sensitive": true }, { "length": { "atLeast": 15, "under": 60 } }, { "shape": "16:9" },
            { "matchBy": ["text", "visual"] } ],
          "saved": "2026-10-22T19:55:00Z" }
        """

    static func search(_ filters: [SavedSearch.Filter] = [], query: String = "beach",
                       kind: ResultGroupKind? = nil) -> SavedSearch {
        SavedSearch(id: UUID(), name: "a search", query: query, kind: kind, filters: filters, saved: Date())
    }

    @Test func aFileIsReadOnlyInTheApprovedShape() throws {
        let searches = try SavedSearch.searches(in: Self.file(Self.entry(), Self.tati))
        #expect(searches.map(\.name) == ["a search", "Tati at the beach"])
        #expect(searches[1].kind == .images && searches[1].filters.count == 10)
        #expect(searches[1].filters[4] == .from(.mine) && searches[1].filters[6] == .sensitive)
        #expect(searches[1].filters[9] == .matchBy(try #require(SearchFilter.MatchBy([.visual, .text]))))
        // Written back, it reads the same, Match by in its order.
        let written = try SavedSearch.data(searches)
        #expect(try SavedSearch.searches(in: written) == searches)
        let file = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let filters = try #require(((file["searches"] as? [[String: Any]])?[1])?["filters"] as? [[String: Any]])
        #expect(filters.last?["matchBy"] as? [String] == ["visual", "text"])
        // Any other shape isn't read, so the app leaves the file alone.
        let newer = String(decoding: Self.file(Self.entry()), as: UTF8.self)
            .replacingOccurrences(of: #""version": 1"#, with: #""version": 2"#)
        #expect(throws: SavedSearch.FileError.version(2)) { try SavedSearch.searches(in: Data(newer.utf8)) }
        let id = UUID().uuidString
        for notWellFormed in [Self.file(Self.entry(#"{ "from": "mine" }, { "from": "saved" }"#)),
                              Self.file(Self.entry(#"{ "matchBy": ["text"] }, { "matchBy": ["spoken"] }"#)),
                              Self.file(Self.entry(name: "")), Self.file(Self.entry(id: id), Self.entry(id: id))] {
            #expect(throws: SavedSearch.FileError.notWellFormed) { try SavedSearch.searches(in: notWellFormed) }
        }
        for filters in [#"{ "photosFavorites": true, "digupFavorites": true }"#, #"{ "photosFavorites": false }"#,
                        #"{ "smile": true }"#, #"{ "shape": "16:0" }"#, #"{ "matchBy": [] }"#,
                        #"{ "matchBy": ["text", "text"] }"#] {
            #expect(throws: DecodingError.self) { try SavedSearch.searches(in: Self.file(Self.entry(filters))) }
        }
    }

    @Test func aSavedSearchKeepsWhatTheWindowKeepsForIt() throws {
        let saved = try #require(try SavedSearch.searches(in: Self.file(Self.tati)).first)
        // Tati, renamed in Photos since, in two libraries; Florida, moved to another folder; someone else.
        let people = [IndexStore.PhotosPerson(id: 1, library: Self.library, uuid: "P-ANA", name: "Ana", files: 3),
                      IndexStore.PhotosPerson(id: 2, library: Self.library, uuid: "P-TATI", name: "Tati", files: 5),
                      IndexStore.PhotosPerson(id: 7, library: "/Other.photoslibrary", uuid: "P-TATI", name: "Tati",
                                              files: 1)]
        let albums = [IndexStore.PhotosAlbum(id: 4, library: Self.library, uuid: "A-FLORIDA", title: "Florida",
                                             folders: ["Trips"], files: 9)]
        // What the searcher may see stays as it was.
        var base = SearchFilter()
        base.photosOnly = ["/seen.jpeg"]
        let filter = saved.searchFilter(narrowing: base, people: people, albums: albums, myDevices: ["iPhone 15 Pro"],
                                        blurring: .off, favorites: { ["/f/heart.jpg"] })
        #expect(filter.photosOnly == ["/seen.jpeg"])
        #expect(filter.people == [[2, 7]] && filter.albums == [4])
        #expect(filter.favorites && filter.paths == ["/f/heart.jpg"] && filter.shotOn == ["iPhone 15 Pro"])
        #expect(filter.area == SearchFilter.Area(latitudes: 25.10...26.20, longitudes: -80.90 ... -79.80))
        // The Sensitive filter at blurring's position, Revealing while blurring is off.
        #expect(filter.sensitive == .revealing)
        #expect(filter.length == SearchFilter.Length(atLeast: 15, under: 60))
        #expect(filter.shape == .ratio(width: 16, height: 9))
        #expect(filter.matchBy == SearchFilter.MatchBy([.visual, .text]))
        #expect(saved.kinds == [.image] && !saved.isCode)
        // Match by keeps to parts of what an AI app sees: no switch keeps it from one.
        #expect(Self.search([.matchBy(try #require(SearchFilter.MatchBy([.spoken])))]).aiUses.isEmpty)
        // Gone from Photos: the person keeps nothing (never everyone), and the album adds nothing.
        let gone = saved.searchFilter(people: [], albums: [], myDevices: [], blurring: .nudityOnly, favorites: { [] })
        #expect(gone.people == [[]] && gone.albums == [] && gone.sensitive == .nudityOnly && gone.shotOn == [])
        // From saved or imported, by its origin; DigUp's favorites are looked up only for a search that has them.
        var asked = false
        let origin = Self.search([.from(.saved)]).searchFilter(people: [], albums: [], myDevices: ["iPhone 15 Pro"],
                                                               blurring: .off, favorites: { asked = true; return [] })
        #expect(origin.origins == ["saved"] && origin.shotOn == nil && origin.paths == nil && !asked)
        // Code: the Code kind, or "code:" typed.
        #expect(Self.search(query: "code: retry with backoff").isCode && Self.search(query: "", kind: .code).isCode)
    }

    @Test func aSavedSearchIsSaidAsSaveThisSearchSaysIt() throws {
        let saved = try #require(try SavedSearch.searches(in: Self.file(Self.tati)).first)
        let people = [IndexStore.PhotosPerson(id: 2, library: Self.library, uuid: "P-TATI", name: "Tati", files: 5)]
        let albums = [IndexStore.PhotosAlbum(id: 4, library: Self.library, uuid: "A-FLORIDA", title: "Florida 2024",
                                             folders: ["Trips"], files: 9)]
        // Its people and albums as Photos has them now; the others as their tokens say.
        let rest = "Photos Favorites · Favorites · Shot on my devices · In the map's area · Sensitive · "
            + "15 s – 1 min · 16:9 · Match: Visual + Text"
        #expect(saved.summary(people: people, albums: albums) == "“+beach” · Images · Tati · Florida 2024 · " + rest)
        // As saved, when they aren't there now.
        #expect(saved.summary(people: [], albums: []) == "“+beach” · Images · Tatiana Rotari · Florida · " + rest)
        #expect(SavedSearch.summary(query: " ", kind: nil, filters: [SavedSearch.Filter.from(.imported).title])
                == "All kinds · Imported into Photos")
    }
}
