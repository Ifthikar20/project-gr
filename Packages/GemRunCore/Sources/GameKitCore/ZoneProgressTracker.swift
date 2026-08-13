import CoreModels
import Foundation

/// One accepted position for zone progress. The caller stamps `t` (epoch
/// seconds at delivery) so map fixes and run samples share one clock even
/// though their native timestamps use different bases.
public struct ZoneFix: Sendable {
    public let t: TimeInterval
    public let lat: Double
    public let lng: Double
    public let accuracyM: Double

    public init(t: TimeInterval, lat: Double, lng: Double, accuracyM: Double) {
        self.t = t
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
    }
}

/// Walk the kilometre: per-segment distance credit inside each zone, in the
/// CollectionEngine mold — pure, synchronous, fed live by the engine and by
/// fixture tracks in tests. Segment gates (accuracy, gap, teleport,
/// per-source speed cap, jitter floor) all come from ZoneRules; crossing
/// `mintDistanceM` emits `.minted`, carries the overflow, and stops at the
/// per-zone daily cap.
public struct ZoneProgressTracker: Sendable {
    public enum Source: Sendable {
        case map, run
    }

    public enum Event: Equatable, Sendable {
        case progress(zoneID: UUID, totalM: Double)
        case minted(zoneID: UUID, creditedM: Double)
    }

    private let zones: [RunnerZone]
    private let mintDistanceM: Double
    public private(set) var progressM: [UUID: Double]
    public private(set) var mintCounts: [UUID: Int]
    private var previous: ZoneFix?

    public init(zones: [RunnerZone],
                initialProgressM: [UUID: Double] = [:],
                mintCounts: [UUID: Int] = [:],
                mintDistanceM: Double = ZoneRules.mintDistanceM) {
        self.zones = zones
        self.progressM = initialProgressM
        self.mintCounts = mintCounts
        self.mintDistanceM = max(mintDistanceM, 1)
    }

    /// Feed one fix; returns the progress/mint events it produced (usually
    /// zero or one per zone the segment touches).
    public mutating func ingest(_ fix: ZoneFix, source: Source) -> [Event] {
        // A bad fix never counts — and never breaks the chain either: an
        // accuracy blip mid-walk shouldn't erase the segment around it.
        guard fix.accuracyM >= 0, fix.accuracyM <= ZoneRules.maxAccuracyM else {
            return []
        }
        guard let prev = previous else {
            previous = fix
            return []
        }
        let dt = fix.t - prev.t
        guard dt > 0, dt <= ZoneRules.maxSampleGapS else {
            // Clock weirdness or a long gap (backgrounded, tunnel): restart
            // the chain here, crediting nothing across the hole.
            previous = fix
            return []
        }
        let distance = RouteGeometry.planarDistance(
            from: Coordinate(lat: prev.lat, lng: prev.lng),
            to: Coordinate(lat: fix.lat, lng: fix.lng))
        // Standing-still shimmer: hold the previous anchor so slow honest
        // movement can still accumulate into a real segment.
        guard distance >= ZoneRules.minSegmentM else { return [] }
        let speed = distance / dt
        if speed > ZoneRules.teleportSpeedMps {
            // Impossible jump — drop it and re-anchor so the next segment
            // isn't poisoned.
            previous = fix
            return []
        }
        let cap = source == .map ? ZoneRules.mapSpeedCapMps
                                 : ZoneRules.runSpeedCapMps
        if speed > cap {
            // Too fast to be on foot for this source (driving past a park
            // must not fill its bar). Re-anchor, credit nothing.
            previous = fix
            return []
        }
        previous = fix

        var events: [Event] = []
        for zone in zones {
            let minted = mintCounts[zone.id, default: 0]
            guard minted < ZoneRules.maxMintsPerZonePerDay else { continue }
            let prevInside = Self.inside(zone, lat: prev.lat, lng: prev.lng)
            let currInside = Self.inside(zone, lat: fix.lat, lng: fix.lng)
            // Both endpoints in → full credit; straddling the rim → half
            // (cheap boundary clip); outside → nothing.
            let credit: Double = if prevInside && currInside {
                distance
            } else if prevInside || currInside {
                distance / 2
            } else {
                0
            }
            guard credit > 0 else { continue }
            var total = progressM[zone.id, default: 0] + credit
            if total >= mintDistanceM {
                mintCounts[zone.id] = minted + 1
                total -= mintDistanceM
                progressM[zone.id] = total
                events.append(.minted(zoneID: zone.id, creditedM: mintDistanceM))
            } else {
                progressM[zone.id] = total
                events.append(.progress(zoneID: zone.id, totalM: total))
            }
        }
        return events
    }

    static func inside(_ zone: RunnerZone, lat: Double, lng: Double) -> Bool {
        // Polygon zones test the real boundary; circles keep the radius.
        if let ring = zone.ring, ring.count >= 4 {
            return NoGoPolygons.pointInRing(lat: lat, lng: lng, ring: ring)
        }
        return RouteGeometry.planarDistance(from: zone.center,
                                            to: Coordinate(lat: lat, lng: lng))
            <= zone.radiusM
    }
}
