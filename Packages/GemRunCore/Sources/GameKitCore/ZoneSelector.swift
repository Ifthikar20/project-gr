import CoreModels
import Foundation

/// Raw map ingredients for a day's zones: park polygons to anchor on,
/// strict pedestrian ways to require and score by, and closed no-go rings
/// to never sit on. Providers fill it (Overpass, MKLocalSearch, later the
/// API); the selector is the one place placement policy lives.
public struct ZonePlacementData: Sendable {
    public struct Park: Sendable {
        public let name: String?
        public let ring: [Coordinate]

        public init(name: String?, ring: [Coordinate]) {
            self.name = name
            self.ring = ring
        }
    }

    public var parks: [Park]
    public var trails: [[Coordinate]]
    public var noGoRings: [[Coordinate]]

    public init(parks: [Park] = [], trails: [[Coordinate]] = [],
                noGoRings: [[Coordinate]] = []) {
        self.parks = parks
        self.trails = trails
        self.noGoRings = noGoRings
    }
}

/// Turns placement data into the day's 2–4 zones: parks scored by area and
/// by the trail metres inside the would-be circle, vetoed fail-closed
/// against no-go land (centroid plus eight perimeter probes — empty beats
/// misplaced, the server's rule), then a seeded weighted pick so the
/// selection is random across days but identical within one. Pure and
/// deterministic: `day` is injected, nothing here reads the clock.
public enum ZoneSelector {
    struct Candidate {
        let center: Coordinate
        let radiusM: Double
        let name: String?
        let score: Double
    }

    public static func select(data: ZonePlacementData,
                              around user: Coordinate,
                              day: Int,
                              source: String) -> [RunnerZone] {
        let noGo = NoGoPolygons(rings: data.noGoRings)
        // MKLocalSearch has no trail geometry; when a provider supplies
        // none at all, park pedigree carries the walkability argument and
        // the trail gate would only zero every candidate.
        let trailsKnown = !data.trails.isEmpty

        var candidates: [Candidate] = []
        for park in data.parks {
            let area = RingMath.areaM2(park.ring)
            guard area >= ZoneRules.minParkAreaM2 else { continue }
            let center = RingMath.centroid(park.ring)
            guard RouteGeometry.planarDistance(from: center, to: user)
                    <= ZoneRules.searchRadiusM else { continue }
            let radius = min(max((area / .pi).squareRoot() * 1.1,
                                 ZoneRules.minZoneRadiusM),
                             ZoneRules.maxZoneRadiusM)
            guard !vetoed(center: center, radiusM: radius, noGo: noGo) else { continue }
            let trailM = trailLength(within: radius, of: center, trails: data.trails)
            if trailsKnown && trailM < ZoneRules.minTrailLengthM { continue }
            let areaScore = min(area, 300_000) / 300_000
            let trailScore = min(trailM, 5_000) / 5_000
            let score = trailsKnown ? 0.5 * areaScore + 0.5 * trailScore : areaScore
            candidates.append(Candidate(center: center, radiusM: radius,
                                        name: park.name, score: max(score, 0.01)))
        }
        guard !candidates.isEmpty else { return [] }

        // Weighted seeded pick from the top eight, with separation enforced
        // as we go: a candidate overlapping a picked zone is discarded, not
        // retried. Ties break on coordinates so equal scores can't make the
        // pool order — and with it the whole day's pick — depend on input
        // order.
        let pool = candidates.sorted {
            ($0.score, $0.center.lat, $0.center.lng)
                > ($1.score, $1.center.lat, $1.center.lng)
        }.prefix(8)
        var rng = SplitMix64(seed: StableSeed.daily(day: day, lat: user.lat,
                                                    lng: user.lng,
                                                    salt: 0x5A6F_6E65))
        var remaining = Array(pool)
        var picked: [Candidate] = []
        while picked.count < ZoneRules.maxZoneCount, !remaining.isEmpty {
            let total = remaining.map(\.score).reduce(0, +)
            var roll = Double(rng.next() >> 11) / Double(1 << 53) * total
            var index = remaining.count - 1
            for (i, candidate) in remaining.enumerated() {
                roll -= candidate.score
                if roll <= 0 {
                    index = i
                    break
                }
            }
            let choice = remaining.remove(at: index)
            let separated = picked.allSatisfy {
                RouteGeometry.planarDistance(from: $0.center, to: choice.center)
                    >= ZoneRules.minSeparationFactor * ($0.radiusM + choice.radiusM)
            }
            if separated { picked.append(choice) }
        }

        return picked.map { candidate in
            RunnerZone(id: stableZoneID(day: day, center: candidate.center),
                       name: candidate.name ?? "Green Zone",
                       lat: candidate.center.lat, lng: candidate.center.lng,
                       radiusM: candidate.radiusM, day: day, sourceRaw: source)
        }
    }

    /// Fail-closed no-go veto: the anchor or ANY of eight probes at 80% of
    /// the radius sitting inside private/government land drops the
    /// candidate entirely.
    static func vetoed(center: Coordinate, radiusM: Double,
                       noGo: NoGoPolygons) -> Bool {
        guard !noGo.isEmpty else { return false }
        if noGo.contains(lat: center.lat, lng: center.lng) { return true }
        let mPerDegLat = 111_320.0
        let mPerDegLng = mPerDegLat * cos(center.lat * .pi / 180)
        for k in 0..<8 {
            let theta = Double(k) / 8 * 2 * .pi
            let lat = center.lat + 0.8 * radiusM * sin(theta) / mPerDegLat
            let lng = center.lng + 0.8 * radiusM * cos(theta) / mPerDegLng
            if noGo.contains(lat: lat, lng: lng) { return true }
        }
        return false
    }

    /// Metres of trail polyline inside the circle — a segment counts when
    /// its midpoint does.
    static func trailLength(within radiusM: Double, of center: Coordinate,
                            trails: [[Coordinate]]) -> Double {
        var total = 0.0
        for trail in trails where trail.count >= 2 {
            for i in 1..<trail.count {
                let a = trail[i - 1]
                let b = trail[i]
                let mid = Coordinate(lat: (a.lat + b.lat) / 2,
                                     lng: (a.lng + b.lng) / 2)
                if RouteGeometry.planarDistance(from: mid, to: center) <= radiusM {
                    total += RouteGeometry.planarDistance(from: a, to: b)
                }
            }
        }
        return total
    }

    /// Deterministic zone UUID from (day, center rounded to ~1 m): the same
    /// zone keeps the same id across refreshes, so partial progress keyed
    /// by it never orphans mid-day.
    public static func stableZoneID(day: Int, center: Coordinate) -> UUID {
        var rng = SplitMix64(seed: UInt64(bitPattern:
            Int64(day) &* 6_700_417
            &+ Int64((center.lat * 1e5).rounded()) &* 65_537
            &+ Int64((center.lng * 1e5).rounded())))
        let hi = rng.next()
        let lo = rng.next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: hi >> 56), UInt8(truncatingIfNeeded: hi >> 48),
            UInt8(truncatingIfNeeded: hi >> 40), UInt8(truncatingIfNeeded: hi >> 32),
            UInt8(truncatingIfNeeded: hi >> 24), UInt8(truncatingIfNeeded: hi >> 16),
            UInt8(truncatingIfNeeded: hi >> 8), UInt8(truncatingIfNeeded: hi),
            UInt8(truncatingIfNeeded: lo >> 56), UInt8(truncatingIfNeeded: lo >> 48),
            UInt8(truncatingIfNeeded: lo >> 40), UInt8(truncatingIfNeeded: lo >> 32),
            UInt8(truncatingIfNeeded: lo >> 24), UInt8(truncatingIfNeeded: lo >> 16),
            UInt8(truncatingIfNeeded: lo >> 8), UInt8(truncatingIfNeeded: lo)))
    }
}
