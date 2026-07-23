import CoreModels
import Foundation

/// Planar route math (docs/04): projects GPS points onto the route polyline to
/// get cross-track distance and along-route progress. Uses an equirectangular
/// approximation around the route origin — centimeter-irrelevant at run scale.
public struct RouteGeometry: Sendable {
    public let coordinates: [Coordinate]
    /// Cumulative distance (m) at each vertex; last element = total length.
    public let cumulative: [Double]
    private let xs: [Double]
    private let ys: [Double]
    private let origin: Coordinate
    private let metersPerDegLng: Double

    private static let metersPerDegLat = 111_320.0

    public var totalLengthM: Double { cumulative.last ?? 0 }

    public init(coordinates: [Coordinate]) {
        self.coordinates = coordinates
        let origin = coordinates.first ?? Coordinate(lat: 0, lng: 0)
        self.origin = origin
        self.metersPerDegLng = Self.metersPerDegLat * cos(origin.lat * .pi / 180)

        var xs: [Double] = []
        var ys: [Double] = []
        var cumulative: [Double] = []
        var total = 0.0
        for (i, c) in coordinates.enumerated() {
            let x = (c.lng - origin.lng) * metersPerDegLng
            let y = (c.lat - origin.lat) * Self.metersPerDegLat
            if i > 0 {
                total += ((x - xs[i - 1]) * (x - xs[i - 1]) + (y - ys[i - 1]) * (y - ys[i - 1])).squareRoot()
            }
            xs.append(x)
            ys.append(y)
            cumulative.append(total)
        }
        self.xs = xs
        self.ys = ys
        self.cumulative = cumulative
    }

    public init(polyline: String) {
        self.init(coordinates: PolylineCodec.decode(polyline))
    }

    public struct Projection: Sendable {
        public let crossTrackM: Double
        public let alongRouteM: Double
    }

    /// Closest point on the polyline to `c`.
    public func project(_ c: Coordinate) -> Projection {
        guard coordinates.count > 1 else {
            return Projection(crossTrackM: distance(from: c, to: origin), alongRouteM: 0)
        }
        let px = (c.lng - origin.lng) * metersPerDegLng
        let py = (c.lat - origin.lat) * Self.metersPerDegLat
        var best = Projection(crossTrackM: .greatestFiniteMagnitude, alongRouteM: 0)
        for i in 0..<(coordinates.count - 1) {
            let ax = xs[i], ay = ys[i]
            let dx = xs[i + 1] - ax, dy = ys[i + 1] - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) : 0
            let cx = ax + t * dx, cy = ay + t * dy
            let dist = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
            if dist < best.crossTrackM {
                best = Projection(crossTrackM: dist, alongRouteM: cumulative[i] + t * len2.squareRoot())
            }
        }
        return best
    }

    /// Coordinate at a given distance from the start (clamped).
    public func coordinate(atDistance d: Double) -> Coordinate {
        guard let last = cumulative.last, last > 0 else { return origin }
        let d = max(0, min(d, last))
        for i in 1..<cumulative.count where cumulative[i] >= d {
            let segLen = cumulative[i] - cumulative[i - 1]
            let t = segLen > 0 ? (d - cumulative[i - 1]) / segLen : 0
            let a = coordinates[i - 1], b = coordinates[i]
            return Coordinate(lat: a.lat + t * (b.lat - a.lat), lng: a.lng + t * (b.lng - a.lng))
        }
        return coordinates.last ?? origin
    }

    /// Haversine-free planar distance between two nearby coordinates (m).
    public func distance(from a: Coordinate, to b: Coordinate) -> Double {
        let dx = (a.lng - b.lng) * metersPerDegLng
        let dy = (a.lat - b.lat) * Self.metersPerDegLat
        return (dx * dx + dy * dy).squareRoot()
    }
}
