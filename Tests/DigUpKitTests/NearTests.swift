import Foundation
import Testing
@testable import DigUpKit

/// Near a place (`digup mcp`'s `near`): what's within a distance along the earth of a point, by where files were
/// taken, at the circle's edge, across the antimeridian and around the poles, beside a box on the map and inside what
/// an AI app may see.
@Suite struct NearTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    func near(_ latitude: Double, _ longitude: Double, km: Double) throws -> SearchFilter.Near {
        try #require(SearchFilter.Near(latitude: latitude, longitude: longitude, radiusKm: km))
    }

    /// A picture taken at that place, named by it unless `path` is given.
    @discardableResult
    func picture(_ latitude: Double, _ longitude: Double, in store: IndexStore, path: String? = nil) throws -> String {
        let path = path ?? "/pictures/\(latitude),\(longitude).jpg"
        let id = try store.insert(Candidate(path: path, kind: .image, size: 1, mtime: 1,
                                            inode: UInt64.random(in: 1...UInt64.max >> 1), device: 1))
        try store.setLocation(try #require(Location(latitude: latitude, longitude: longitude, source: .exif)), of: id)
        return path
    }

    /// The paths of the files `filter` keeps, with no words.
    func kept(_ filter: SearchFilter, in store: IndexStore) throws -> Set<String> {
        Set(try Searcher(store: store, loadVectors: false).search("", queryVector: nil, filter: filter, limit: 10_000)
            .map(\.path))
    }

    @Test func distancesAreAlongTheEarth() {
        let km = SearchFilter.Near.kilometers
        #expect(abs(km((0, 0), (1, 0)) - 111.195) < 0.001)                         // a degree of a great circle
        #expect(abs(km((51.5007, -0.1246), (48.8584, 2.2945)) - 340.54) < 0.05)    // Big Ben to the Eiffel Tower
        #expect(abs(km((10, 20), (-10, -160)) - 20_015.1) < 0.1)                   // the far side of the earth
        #expect(abs(km((10, 179.9), (10, -179.9)) - km((10, -0.1), (10, 0.1))) < 1e-9)   // the short way round
        #expect(km((89, 0), (89, 180)) == km((89, 90), (89, -90)))                 // over the pole
        #expect(km((25.79, -80.13), (25.79, -80.13)) == 0)
    }

    @Test func nearKeepsWhatsWithinItsRadiusAndNotJustPast() throws {
        let store = try IndexStore(directory: folder)
        let edge = try picture(11, 20, in: store)              // north of the centre, a degree away
        let inside = try picture(10.999, 20, in: store)
        let outside = try picture(11.001, 20, in: store)
        let east = try picture(10, 21.01, in: store)           // a degree of longitude is shorter at 10°: inside
        let farEast = try picture(10, 21.02, in: store)
        let radius = SearchFilter.Near.kilometers((10, 20), (11, 20))
        #expect(SearchFilter.Near.kilometers((10, 20), (10, 21.01)) < radius
                && SearchFilter.Near.kilometers((10, 20), (10, 21.02)) > radius)
        // Right on the circle counts: within means at most.
        #expect(try kept(SearchFilter(near: try near(10, 20, km: radius)), in: store) == [edge, inside, east])
        #expect(try kept(SearchFilter(near: try near(10, 20, km: radius - 0.01)), in: store) == [inside, east])
        #expect(try kept(SearchFilter(near: try near(10, 20, km: 200)), in: store).isSuperset(of: [outside, farEast]))
        // A file that says nowhere is near nowhere.
        try store.insert(Candidate(path: "/pictures/nowhere.jpg", kind: .image, size: 1, mtime: 1, inode: 1, device: 1))
        #expect(try kept(SearchFilter(near: try near(10, 20, km: 20_000)), in: store).count == 5)
    }

    @Test func nearCrossesTheAntimeridian() throws {
        let store = try IndexStore(directory: folder)
        let west = try picture(-17, 179.95, in: store)          // Fiji, either side of 180°
        let east = try picture(-17, -179.95, in: store)
        try picture(-17, 179.5, in: store)
        try picture(-17, -179.5, in: store)
        let fiji = try near(-17, 179.95, km: 30)
        #expect(fiji.box.longitudes.count == 2)
        #expect(try kept(SearchFilter(near: fiji), in: store) == [west, east])
        #expect(try kept(SearchFilter(near: try near(-17, -180, km: 30)), in: store) == [west, east])
        #expect(try kept(SearchFilter(near: try near(-17, 180, km: 30)), in: store) == [west, east])
    }

    @Test func nearTakesInAPoleWithEveryLongitude() throws {
        let store = try IndexStore(directory: folder)
        let here = try picture(89.95, 10, in: store)
        let across = try picture(89.95, -170, in: store)      // over the pole: 11 km
        let aside = try picture(89.9, 100, in: store)
        try picture(89.6, 10, in: store)                       // 39 km south
        let station = try near(89.95, 10, km: 20)
        #expect(station.box.longitudes == [-180...180] && station.box.latitudes.upperBound == 90)
        #expect(try kept(SearchFilter(near: station), in: store) == [here, across, aside])
        let south = try picture(-89.99, 45, in: store)
        #expect(try kept(SearchFilter(near: try near(-90, 0, km: 5)), in: store) == [south])
    }

    /// The box only narrows what's measured: wherever the centre and whatever the radius, what's kept is exactly what's
    /// within it.
    @Test func whatsKeptIsExactlyWhatsWithinWhereverAndHoweverFar() throws {
        let store = try IndexStore(directory: folder)
        var places: [String: (Double, Double)] = [:]
        for latitude in stride(from: -88.5, through: 88.5, by: 7.5) {
            for longitude in stride(from: -179.5, through: 179.5, by: 10) {
                places[try picture(latitude, longitude, in: store)] = (latitude, longitude)
            }
        }
        for (latitude, longitude, km) in [(0.0, 0.0, 1_000.0), (45, 179, 3_000), (-60, -178, 2_500), (85, 30, 1_500),
                                          (-80, 120, 900), (30, 90, 19_000), (12, -45, 20_000), (-1, 1, 0.01)] {
            let point = try near(latitude, longitude, km: km)
            let within = Set(places.filter {
                SearchFilter.Near.kilometers((latitude, longitude), $0.value) <= km
            }.keys)
            #expect(try kept(SearchFilter(near: point), in: store) == within, "\(latitude), \(longitude), \(km) km")
        }
    }

    @Test func aPlaceOffTheMapOrARadiusOutOfRangeIsRefused() {
        #expect(SearchFilter.Near(latitude: 90, longitude: -180, radiusKm: 0.01) != nil)
        #expect(SearchFilter.Near(latitude: -90, longitude: 180, radiusKm: 20_000) != nil)
        for (latitude, longitude, km) in [(90.5, 0.0, 1.0), (-91, 0, 1), (0, 180.1, 1), (0, -181, 1), (0, 0, 0.009),
                                          (0, 0, 20_000.5), (0, 0, 0), (0, 0, -1), (.nan, 0, 1), (0, .nan, 1),
                                          (0, 0, .nan), (0, 0, .infinity)] {
            #expect(SearchFilter.Near(latitude: latitude, longitude: longitude, radiusKm: km) == nil,
                    "\(latitude), \(longitude), \(km)")
        }
    }

    @Test func nearAndABoxBothHoldAndAnAIAppsKeepOnlyWhatItMaySee() throws {
        let store = try IndexStore(directory: folder)
        let pier = try picture(25.77, -80.13, in: store)                       // Miami Beach
        let park = try picture(25.79, -80.19, in: store)                       // Miami, 6 km west
        let library = try picture(25.78, -80.14, in: store,
                                  path: "/L.photoslibrary/originals/F/\(UUID().uuidString).jpeg")
        try picture(26.12, -80.14, in: store)                                  // Fort Lauderdale, 39 km north
        let miami = try near(25.78, -80.15, km: 10)
        #expect(try kept(SearchFilter(near: miami), in: store) == [pier, park, library])
        // Beside a box on the map (taken_within): what's in both.
        let east = SearchFilter.Area(latitudes: 25...27, longitudes: -80.16 ... -79)
        #expect(try kept(SearchFilter(area: east, near: miami), in: store) == [pier, library])
        // An AI app that may not see Photos: the library's picture is left out, counted nowhere.
        var seen = SearchFilter(near: miami)
        seen.photosOnly = []
        #expect(try kept(seen, in: store) == [pier, park])
        #expect(try store.counts(keeping: seen) == [.image: ["pending": 2]])
        #expect(!SearchFilter(near: miami).isEmpty)
    }
}
