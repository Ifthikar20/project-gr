import Foundation

/// One of the day's large walkable zones: a circle anchored on a park or
/// trail cluster, selected fresh each day. Walk `ZoneRules.mintDistanceM`
/// inside one and a Runner Card mints. The `id` is derived
/// deterministically from (day, center), so partial progress keyed by it
/// survives refreshes and cache round-trips within the day.
public struct RunnerZone: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let lat: Double
    public let lng: Double
    public let radiusM: Double
    /// Unix day stamp (UTC days since 1970) — zones rotate daily.
    public let day: Int
    /// Which provider produced it ("overpass" / "localsearch" / later "api").
    public let sourceRaw: String

    public init(id: UUID, name: String, lat: Double, lng: Double,
                radiusM: Double, day: Int, sourceRaw: String) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lng = lng
        self.radiusM = radiusM
        self.day = day
        self.sourceRaw = sourceRaw
    }

    public var center: Coordinate { Coordinate(lat: lat, lng: lng) }
}

/// Where a day's zones come from — the seam the backend replaces when the
/// API takes over zone selection. Three-valued like the server's
/// walkability contract: `nil` means the source was unreachable (try the
/// next provider), `[]` means it answered and found nothing near here
/// (stop — an answer is an answer, empty beats misplaced).
public protocol ZoneProviding: Sendable {
    func zones(around center: Coordinate, day: Int) async -> [RunnerZone]?
}
