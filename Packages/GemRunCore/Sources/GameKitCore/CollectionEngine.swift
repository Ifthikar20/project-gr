import CoreModels
import Foundation

/// Collection + validity constants from docs/04 — the single source of truth
/// shared by the engine, tests, and (as documented values) the server pipeline.
public enum CollectionRules {
    public static let collectionRadiusM: Double = 25
    public static let hysteresisExitRadiusM: Double = 40
    public static let hysteresisAdvanceM: Double = 50
    public static let gemLookaheadWindowM: Double = 300

    public static let maxCrossTrackM: Double = 40
    public static let minOnRouteSampleRatio: Double = 0.90
    public static let minRouteCoverageRatio: Double = 0.95

    public static let teleportSpeed: Double = 8          // m/s sustained
    public static let teleportSustainS: TimeInterval = 5
    public static let minRunPaceSPerKm = 150             // 2:30 — faster is a vehicle
    public static let maxValidPaceSPerKm = 1_200         // 20:00 — slower is invalid
    public static let walkPaceThresholdSPerKm = 600      // 10:00 — slower is a walk (0.5× XP)
}

/// Per-sample collection decisions: 25 m threshold + hysteresis + monotonic
/// route progress (docs/04). Pure and synchronous — the ActiveRunEngine actor
/// (Phase D) feeds it samples; tests feed it fixture tracks.
public struct CollectionEngine {
    public private(set) var collected: [UUID] = []

    public init(drops: [GemDrop]) {
        // TODO(Phase B): index drops by positionAlongRouteM for the lookahead window.
        _ = drops
    }

    /// Feed one smoothed sample; returns newly collected drop IDs (usually 0 or 1).
    public mutating func ingest(_ sample: TrackSample) -> [UUID] {
        // TODO(Phase B): project onto polyline, check threshold, apply hysteresis
        // and the monotonic-progress rule.
        _ = sample
        return []
    }
}
