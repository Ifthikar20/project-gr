import CoreModels
import Foundation

/// Zone selection + mint constants (docs/21) — the single source of truth
/// the selector, the progress tracker, tests, and (as documented values)
/// the future server pipeline all share, in the CollectionRules mold.
public enum ZoneRules {
    /// How many zones a day gets, when the map offers enough candidates.
    public static let maxZoneCount = 4
    /// How far out candidate anchors are considered.
    public static let searchRadiusM: Double = 2_500
    /// Zone circles are large on purpose — this is ground to cover, not a
    /// capture ring: 350–500 m radius vs the gems' 61 m.
    public static let minZoneRadiusM: Double = 350
    public static let maxZoneRadiusM: Double = 500
    /// A park must be at least this big (m²) to anchor a zone.
    public static let minParkAreaM2: Double = 8_000
    /// Polygon zones grow to at least this footprint (the min-radius
    /// circle's area): a small park's ring is scaled outward — odd shape,
    /// large area — capped at maxRingScale so a pocket park can't project
    /// a district.
    public static let targetZoneAreaM2: Double = .pi * 350 * 350
    public static let maxRingScale: Double = 3.0
    /// Vertex budget per stored zone ring (big traced parks carry
    /// hundreds; rendering and point-in-ring don't need them).
    public static let maxRingVertices = 160
    /// "Plenty of walkable trails": metres of strict pedestrian way that
    /// must run inside the circle when trail data is available.
    public static let minTrailLengthM: Double = 200
    /// Center-to-center distance between two picked zones must be at least
    /// this factor × the sum of their radii.
    public static let minSeparationFactor: Double = 1.2

    /// The mile: metres credited inside a zone that mint a card. (The app
    /// speaks miles everywhere; internals stay metric.)
    public static let mintDistanceM: Double = UnitFormat.metersPerMile
    /// GPS fixes worse than this never count (server anti-cheat rule,
    /// mirrored client-side).
    public static let maxAccuracyM: Double = 50
    /// Per-source speed caps: on the open map anything faster than a brisk
    /// walk is a vehicle; during a run, real runners hit 4–5 m/s.
    public static let mapSpeedCapMps: Double = 3.5
    public static let runSpeedCapMps: Double = 6.0
    /// Mirror of CollectionRules.teleportSpeed — sustained jumps reset the
    /// segment chain instead of crediting impossible metres.
    public static let teleportSpeedMps: Double = 8.0
    /// A gap longer than this between fixes breaks the segment chain
    /// (backgrounding, tunnel, app switch).
    public static let maxSampleGapS: TimeInterval = 120
    /// Segments shorter than this are GPS shimmer, not walking.
    public static let minSegmentM: Double = 3
    /// A zone stops minting after this many cards in one day.
    public static let maxMintsPerZonePerDay = 3
}
