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
    /// Playful route names, drawn without replacement per batch so the four
    /// cards never share a name. Kept ≤ ~24 chars — RouteCard titles are
    /// lineLimit(1). The draw is seeded by (day, ~500 m cell): names hold
    /// steady while you stand in one area today, and roll over with the
    /// daily gem rotation — a new world gets new names.
    static let namePool = [
        "Sidewalk Safari", "Sunrise Scramble", "Gem Gallop", "Treasure Trot",
        "Pocket Expedition", "Loot Before Lunch", "The Long Way Home",
        "Curb Appeal", "Shiny Object Detour", "Block Party", "Corner Cutter",
        "Glitter Mile", "Sparkle Sprint", "Neighborhood Heist", "Lucky Lap",
        "Pebble Patrol", "Crosswalk Quest", "Fresh Air Fortune", "Gem Jog",
        "Morning Miner", "Pavement Prowl", "Second Wind", "Street Sweep",
        "Hidden Carats", "Rock Hound Run", "Five-Star Stroll", "Easy Money",
        "Backyard Bounty", "Dazzle Dash", "Errand With Benefits", "Gold Hour",
        "Jewel Hunt Jr.", "Lamppost Loop", "Magpie Mission", "Out & About",
        "Prize Fighter", "Quick Karat", "Shortcut Scandal", "Small Fortune",
        "Snack-Sized Quest", "Sparkle Circuit", "Stone's Throw", "Sunset Run",
        "The Scenic Bit", "Twinkle Trail", "Urban Prospector", "Walkabout",
        "Window Shopper",
    ]

    /// Up to four suggestions per user location — one nearest gem, two
    /// nearest, three nearest, and the same three farthest-first — each
    /// wearing a distinct name from the seeded pool draw.
    public static func recommend(from origin: Coordinate,
                                 drops: [GemDrop]) async -> [Route] {
        let ranked = drops.sorted {
            planarDistance(origin, $0.coordinate) < planarDistance(origin, $1.coordinate)
        }
        guard !ranked.isEmpty else { return [] }
        let names = pickNames(count: 4, near: origin)

        var routes: [Route] = []
        if let one = await buildRoute(named: names[0],
                                      from: origin,
                                      through: Array(ranked.prefix(1))) {
            routes.append(one)
        }
        if ranked.count >= 2,
           let two = await buildRoute(named: names[1],
                                      from: origin,
                                      through: Array(ranked.prefix(2))) {
            routes.append(two)
        }
        if ranked.count >= 3 {
            let three = Array(ranked.prefix(3))
            if let triple = await buildRoute(named: names[2],
                                             from: origin, through: three) {
                routes.append(triple)
            }
            if let reverse = await buildRoute(named: names[3],
                                              from: origin,
                                              through: Array(three.reversed())) {
                routes.append(reverse)
            }
        }
        return routes
    }

    /// A deterministic, distinct pick of `count` names for this (day, area).
    /// Swift's `hashValue` is salted per launch and the system RNG can't be
    /// seeded, so the shuffle runs on a tiny SplitMix64 seeded from stable
    /// inputs — same names all day in one place, fresh tomorrow.
    static func pickNames(count: Int, near origin: Coordinate) -> [String] {
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        let cellLat = Int((origin.lat / 0.005).rounded())
        let cellLng = Int((origin.lng / 0.005).rounded())
        var rng = SplitMix64(seed: UInt64(bitPattern:
            Int64(day) &* 1_000_003 &+ Int64(cellLat) &* 8_191 &+ Int64(cellLng)))
        var pool = namePool
        pool.shuffle(using: &rng)
        return Array(pool.prefix(count))
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
            let (path, snapped) = await PathSnapper.snapVerified(from: lastPoint, to: target)
            // An unconfirmed leg is a straight line through who-knows-what —
            // drop the whole candidate route instead of drawing it.
            guard snapped else { return nil }
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

/// Minimal seedable RNG (SplitMix64) — deterministic across launches, which
/// `SystemRandomNumberGenerator` and `hashValue` are not.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
