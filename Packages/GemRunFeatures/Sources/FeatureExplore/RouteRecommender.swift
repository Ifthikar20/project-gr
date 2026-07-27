import CoreMap
import CoreModels
import Foundation
import GameKitCore

/// Client-side route synthesis: given the user's current location and
/// nearby standalone gem drops, propose a handful of open-ended walking
/// routes that start where the user is standing and visit different
/// combinations of nearby gems. Segments are snapped to real walking
/// paths via MKDirections (PathSnapper), so recommendations track the
/// same walkability contract as user-drawn routes.
///
/// Recommendations are ephemeral — regenerated when the user moves, and
/// never persisted server-side.
@MainActor
public enum RouteRecommender {
    /// Up to four suggestions per user location:
    ///   • Quick pick   — one nearest gem
    ///   • Two-gem run  — two nearest, nearest first
    ///   • Triple threat — three nearest, nearest first
    ///   • Reverse triple — same three, farthest first (tougher opener)
    public static func recommend(from origin: Coordinate,
                                 drops: [GemDrop]) async -> [Route] {
        let ranked = drops.sorted {
            planarDistance(origin, $0.coordinate) < planarDistance(origin, $1.coordinate)
        }
        guard !ranked.isEmpty else { return [] }

        var routes: [Route] = []
        if let one = await buildRoute(named: "Quick pick",
                                      from: origin,
                                      through: Array(ranked.prefix(1))) {
            routes.append(one)
        }
        if ranked.count >= 2,
           let two = await buildRoute(named: "Two-gem run",
                                      from: origin,
                                      through: Array(ranked.prefix(2))) {
            routes.append(two)
        }
        if ranked.count >= 3 {
            let three = Array(ranked.prefix(3))
            if let triple = await buildRoute(named: "Triple threat",
                                             from: origin, through: three) {
                routes.append(triple)
            }
            if let reverse = await buildRoute(named: "Reverse triple",
                                              from: origin,
                                              through: Array(three.reversed())) {
                routes.append(reverse)
            }
        }
        return routes
    }

    private static func buildRoute(named name: String,
                                   from origin: Coordinate,
                                   through drops: [GemDrop]) async -> Route? {
        guard !drops.isEmpty else { return nil }
        // Snap each leg to real walking paths so recommended routes stay on
        // sidewalks and trails — not straight lines cutting across yards.
        var coords: [Coordinate] = [origin]
        var lastPoint = origin
        for drop in drops {
            let target = drop.coordinate
            let (path, _) = await PathSnapper.snapVerified(from: lastPoint, to: target)
            coords.append(contentsOf: path.dropFirst())
            lastPoint = target
        }
        let totalM = Int(RouteGeometry(coordinates: coords).totalLengthM)
        guard totalM > 0 else { return nil }

        // Snap each drop to its position along the built polyline so the run
        // engine can order collections correctly.
        let placed = drops.enumerated().map { i, drop -> GemDrop in
            let fraction = Double(i + 1) / Double(drops.count)
            return GemDrop(id: drop.id, gemID: drop.gemID, rarity: drop.rarity,
                           lat: drop.lat, lng: drop.lng,
                           positionAlongRouteM: Int(fraction * Double(totalM)),
                           respawnRule: drop.respawnRule,
                           placedBy: drop.placedBy,
                           fuzzRadiusM: drop.fuzzRadiusM)
        }
        let difficulty: RouteDifficulty =
            totalM < 4_000 ? .easy : totalM < 9_000 ? .moderate : .hard

        return Route(
            id: UUID(), name: name,
            description: "Auto-planned from your location.",
            polyline: PolylineCodec.encode(coords),
            distanceM: totalM, elevationGainM: 0,
            difficulty: difficulty, status: .published,
            creatorHandle: "GemRun/auto", runCount: 0,
            gemDrops: placed)
    }

    private static func planarDistance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let mPerDegLat = 111_320.0
        let dy = (b.lat - a.lat) * mPerDegLat
        let dx = (b.lng - a.lng) * mPerDegLat * cos(a.lat * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }
}
