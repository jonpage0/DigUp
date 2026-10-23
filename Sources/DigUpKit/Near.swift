import Foundation

extension SearchFilter {
    /// Near a place (`digup mcp`'s `near`, Jon 2026-10-23 01:17, its detail ours): files taken within `radiusKm` of a
    /// point, measured along the earth (the great-circle distance on a sphere of its mean radius), by where they were
    /// taken (`locations`: Photos' location, else the file's own GPS, as `area` keeps them). A file with no location
    /// isn't near anywhere.
    public struct Near: Sendable, Hashable {
        /// Degrees: −90 to 90, −180 to 180.
        public let latitude: Double
        public let longitude: Double
        public let radiusKm: Double

        /// The radii it takes, in km: from 10 m to most of the way round the earth (half of it is 20,015 km).
        public static let radii: ClosedRange<Double> = 0.01...20_000
        /// The earth's mean radius (IUGG), in km.
        public static let earthRadiusKm = 6_371.0088
        /// The SQL function its query measures with (`kilometers`), defined on each of the index's connections
        /// (`IndexStore`): SQLite may be built without trigonometry (its math functions are an option).
        static let distanceFunction = "digup_km_between"
        /// How much wider than the circle the box its query looks in first is, in degrees (about 0.1 mm): a place
        /// right on the circle is never lost to rounding before its distance is measured.
        private static let margin = 1e-9

        /// Nil for a point off the map's degrees or a radius outside `radii` (or anything that isn't a number).
        public init?(latitude: Double, longitude: Double, radiusKm: Double) {
            guard (-90...90).contains(latitude), (-180...180).contains(longitude), Self.radii.contains(radiusKm) else {
                return nil
            }
            (self.latitude, self.longitude, self.radiusKm) = (latitude, longitude, radiusKm)
        }

        /// How far apart two points are along the earth, in km (the haversine formula, sound at every distance from
        /// metres to the far side of the earth). Points in degrees.
        public static func kilometers(_ first: (latitude: Double, longitude: Double),
                                      _ second: (latitude: Double, longitude: Double)) -> Double {
            let radians = Double.pi / 180
            let (from, to) = (first.latitude * radians, second.latitude * radians)
            let across = sin((to - from) / 2), along = sin((second.longitude - first.longitude) * radians / 2)
            let half = across * across + cos(from) * cos(to) * along * along
            return 2 * earthRadiusKm * asin(min(1, half.squareRoot()))
        }

        /// The box the circle is in, in degrees: its latitudes, and its longitudes as one range, or two where it
        /// crosses the antimeridian (180°), or every longitude where a pole is inside it. (Jan Matuschek, "Finding
        /// Points Within a Distance of a Latitude/Longitude Using Bounding Coordinates".)
        var box: (latitudes: ClosedRange<Double>, longitudes: [ClosedRange<Double>]) {
            let angle = radiusKm / Self.earthRadiusKm * 180 / .pi   // the radius, in degrees of a great circle
            let (south, north) = (latitude - angle - Self.margin, latitude + angle + Self.margin)
            guard -90 < south, north < 90 else { return (max(south, -90)...min(north, 90), [-180...180]) }
            let half = asin(min(1, sin(angle * .pi / 180) / cos(latitude * .pi / 180))) * 180 / .pi + Self.margin
            let (west, east) = (longitude - half, longitude + half)
            let longitudes: [ClosedRange<Double>] = if half >= 180 { [-180...180] }
                else if west < -180 { [(west + 360)...180, -180...east] }
                else if east > 180 { [west...180, -180...(east - 360)] }
                else { [west...east] }
            return (south...north, longitudes)
        }

        /// The files it keeps, as a query of their ids, and the values it takes: the locations in its box, then
        /// those within its radius.
        var query: (sql: String, values: [SQLValue]) {
            let box = box
            let longitudes = box.longitudes.map { _ in "longitude BETWEEN ? AND ?" }.joined(separator: " OR ")
            let values: [SQLValue] = [.double(box.latitudes.lowerBound), .double(box.latitudes.upperBound)]
                + box.longitudes.flatMap { [SQLValue.double($0.lowerBound), .double($0.upperBound)] }
                + [.double(latitude), .double(longitude), .double(radiusKm)]
            return ("SELECT file FROM locations WHERE latitude BETWEEN ? AND ? AND (\(longitudes)) "
                    + "AND \(Self.distanceFunction)(latitude, longitude, ?, ?) <= ?", values)
        }
    }
}
