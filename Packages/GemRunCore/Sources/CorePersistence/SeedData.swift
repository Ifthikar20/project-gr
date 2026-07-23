import CoreModels
import Foundation
import GameKitCore
import SwiftData

/// Cold-start seeding (docs/02): until the backend serves real nearby routes,
/// generate a few loops around the user's location so the map is never empty.
public enum SeedData {
    /// Idempotent: seeds only when no system routes exist yet.
    @MainActor
    public static func seedIfNeeded(context: ModelContext, around center: Coordinate) {
        let existing = (try? context.fetchCount(FetchDescriptor<StoredRoute>())) ?? 0
        guard existing == 0 else { return }
        for route in makeRoutes(around: center) {
            context.insert(StoredRoute(route: route))
        }
        try? context.save()
    }

    static func makeRoutes(around c: Coordinate) -> [Route] {
        [
            loop(named: "First Light Loop", center: c, radiusM: 320, distanceHint: 2_000,
                 difficulty: .easy, gems: [(.common, 0.15), (.common, 0.5), (.uncommon, 0.85)]),
            loop(named: "Gem Hunter's Circuit", center: offset(c, dLatM: 900, dLngM: 400),
                 radiusM: 800, distanceHint: 5_000, difficulty: .moderate,
                 gems: [(.common, 0.1), (.uncommon, 0.35), (.rare, 0.55), (.uncommon, 0.8)]),
            loop(named: "Ridge Endurance Run", center: offset(c, dLatM: -1_200, dLngM: -700),
                 radiusM: 1_450, distanceHint: 9_000, difficulty: .hard,
                 gems: [(.common, 0.1), (.rare, 0.45), (.epic, 0.7), (.uncommon, 0.9)]),
        ]
    }

    /// A smooth circular loop — stands in for OSM-derived paths (docs/02).
    private static func loop(named name: String, center: Coordinate, radiusM: Double,
                             distanceHint: Int, difficulty: RouteDifficulty,
                             gems: [(Rarity, Double)]) -> Route {
        let n = 36
        let coords = (0...n).map { i -> Coordinate in
            let angle = 2 * .pi * Double(i) / Double(n)
            return offset(center, dLatM: radiusM * sin(angle), dLngM: radiusM * cos(angle))
        }
        let geometry = RouteGeometry(coordinates: coords)
        let drops = gems.map { rarity, fraction -> GemDrop in
            let alongM = geometry.totalLengthM * fraction
            let position = geometry.coordinate(atDistance: alongM)
            return GemDrop(id: UUID(), gemID: GemCatalog.gem(of: rarity).id, rarity: rarity,
                           lat: position.lat, lng: position.lng,
                           positionAlongRouteM: Int(alongM),
                           respawnRule: rarity == .common || rarity == .uncommon ? .daily : .oncePerUser,
                           placedBy: .system)
        }
        return Route(id: UUID(), name: name, polyline: PolylineCodec.encode(coords),
                     distanceM: Int(geometry.totalLengthM),
                     elevationGainM: distanceHint / 100,
                     difficulty: difficulty, creatorHandle: nil, gemDrops: drops)
    }

    private static func offset(_ c: Coordinate, dLatM: Double, dLngM: Double) -> Coordinate {
        Coordinate(lat: c.lat + dLatM / 111_320,
                   lng: c.lng + dLngM / (111_320 * cos(c.lat * .pi / 180)))
    }
}
