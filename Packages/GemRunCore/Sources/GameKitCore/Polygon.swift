import CoreModels
import Foundation

/// Closed no-go polygons (private grounds, golf courses, school yards,
/// military/industrial land, airfields) with per-ring bbox prefilters —
/// a faithful Swift port of the backend's walkability.NoGoZones, so the
/// client vetoes zone anchors by exactly the rules the server uses to
/// veto gem placements.
public struct NoGoPolygons: Sendable {
    private struct Bounded: Sendable {
        let minLat, maxLat, minLng, maxLng: Double
        let ring: [Coordinate]
    }

    private let rings: [Bounded]

    public init(rings: [[Coordinate]]) {
        self.rings = rings.compactMap { ring in
            guard ring.count >= 4,
                  let minLat = ring.map(\.lat).min(),
                  let maxLat = ring.map(\.lat).max(),
                  let minLng = ring.map(\.lng).min(),
                  let maxLng = ring.map(\.lng).max() else { return nil }
            return Bounded(minLat: minLat, maxLat: maxLat,
                           minLng: minLng, maxLng: maxLng, ring: ring)
        }
    }

    public var isEmpty: Bool { rings.isEmpty }
    public var count: Int { rings.count }

    public func contains(lat: Double, lng: Double) -> Bool {
        for bounded in rings {
            guard bounded.minLat <= lat, lat <= bounded.maxLat,
                  bounded.minLng <= lng, lng <= bounded.maxLng else { continue }
            if Self.pointInRing(lat: lat, lng: lng, ring: bounded.ring) {
                return true
            }
        }
        return false
    }

    /// Ray casting over a closed ring of vertices (walkability._point_in_ring).
    /// Public: zone containment and the map tap hit-test use it on zone
    /// rings, not just no-go vetoes.
    public static func pointInRing(lat: Double, lng: Double, ring: [Coordinate]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i]
            let b = ring[j]
            if (a.lat > lat) != (b.lat > lat) {
                let dLat = b.lat - a.lat
                let denom = dLat == 0 ? 1e-18 : dLat
                let cross = (b.lng - a.lng) * (lat - a.lat) / denom + a.lng
                if lng < cross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

/// Small planar ring math for zone anchoring: area for scoring and sizing,
/// centroid for the anchor point. Planar with cos-lat scaling — the same
/// approximation RouteGeometry runs on, fine at park scale.
public enum RingMath {
    public static func areaM2(_ ring: [Coordinate]) -> Double {
        guard ring.count >= 3 else { return 0 }
        let mPerDegLat = 111_320.0
        let mPerDegLng = mPerDegLat * cos(ring[0].lat * .pi / 180)
        var sum = 0.0
        var j = ring.count - 1
        for i in 0..<ring.count {
            let xi = ring[i].lng * mPerDegLng
            let yi = ring[i].lat * mPerDegLat
            let xj = ring[j].lng * mPerDegLng
            let yj = ring[j].lat * mPerDegLat
            sum += (xj + xi) * (yj - yi)
            j = i
        }
        return abs(sum) / 2
    }

    public static func centroid(_ ring: [Coordinate]) -> Coordinate {
        guard let first = ring.first else { return Coordinate(lat: 0, lng: 0) }
        var points = ring
        // Overpass rings repeat the first vertex at the end — don't let it
        // count twice in the mean.
        if points.count > 1,
           abs(first.lat - points[points.count - 1].lat) < 1e-9,
           abs(first.lng - points[points.count - 1].lng) < 1e-9 {
            points.removeLast()
        }
        let lat = points.map(\.lat).reduce(0, +) / Double(points.count)
        let lng = points.map(\.lng).reduce(0, +) / Double(points.count)
        return Coordinate(lat: lat, lng: lng)
    }

    /// The ring scaled about a point — shape-preserving growth, so a small
    /// park becomes a park-shaped neighborhood. k = 1 returns the ring
    /// untouched.
    public static func scaled(_ ring: [Coordinate], about center: Coordinate,
                              by k: Double) -> [Coordinate] {
        guard k != 1 else { return ring }
        return ring.map { p in
            Coordinate(lat: center.lat + (p.lat - center.lat) * k,
                       lng: center.lng + (p.lng - center.lng) * k)
        }
    }

    /// Uniform-stride decimation to at most `maxVertices`, preserving the
    /// repeated-first-vertex closure when present. Big traced parks can
    /// carry hundreds of nodes; zones don't need them all.
    public static func decimated(_ ring: [Coordinate],
                                 maxVertices: Int) -> [Coordinate] {
        guard maxVertices >= 4, ring.count > maxVertices else { return ring }
        var open = ring
        let isClosed = ring.count > 1
            && abs(ring[0].lat - ring[ring.count - 1].lat) < 1e-9
            && abs(ring[0].lng - ring[ring.count - 1].lng) < 1e-9
        if isClosed { open.removeLast() }
        let target = maxVertices - (isClosed ? 1 : 0)
        guard open.count > target else { return ring }
        var out: [Coordinate] = []
        out.reserveCapacity(maxVertices)
        for i in 0..<target {
            out.append(open[i * open.count / target])
        }
        if isClosed { out.append(out[0]) }
        return out
    }
}
