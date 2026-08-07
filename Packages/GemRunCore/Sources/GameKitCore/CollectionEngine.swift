import CoreModels
import Foundation

/// Collection + validity constants from docs/04 — the single source of truth
/// shared by the engine, tests, and (as documented values) the server pipeline.
public enum CollectionRules {
    /// Route-gem capture: within 200 ft (~61 m), matching standalone
    /// drops — cross into the capture zone drawn around every gem on the
    /// map and it's yours, on every run type. This IS the circle the map
    /// renders (CoreMap's CaptureZone), so what you see is what collects.
    /// Server mirror: rules.COLLECTION_RADIUS_M.
    public static let collectionRadiusM: Double = 61
    /// Standalone (walk-near) drops capture at the same 200 ft.
    /// Server mirror: rules.DROP_COLLECT_RADIUS_M.
    public static let dropCollectRadiusM: Double = 61
    /// Hysteresis scales with the capture radius (~1.3× / ~1.6×), so the
    /// exit ring always sits OUTSIDE the capture zone.
    public static let hysteresisExitRadiusM: Double = 80
    public static let hysteresisAdvanceM: Double = 100

    public static let maxCrossTrackM: Double = 40
    public static let minOnRouteSampleRatio: Double = 0.90
    public static let minRouteCoverageRatio: Double = 0.95

    public static let teleportSpeed: Double = 8          // m/s sustained
    public static let teleportSustainS: TimeInterval = 5
    public static let minRunPaceSPerKm = 150             // 2:30 — faster is a vehicle
    public static let maxValidPaceSPerKm = 1_200         // 20:00 — slower is invalid
    public static let walkPaceThresholdSPerKm = 600      // 10:00 — slower is a walk (0.5× XP)
}

/// Per-sample collection decisions (docs/04): 200 ft threshold + hysteresis +
/// monotonic route progress. Pure and synchronous — ActiveRunEngine feeds it
/// live samples; tests feed it fixture tracks; the server replays full tracks.
public struct CollectionEngine: Sendable {
    public struct Event: Equatable, Sendable {
        public let drop: GemDrop
        public let atAlongRouteM: Double

        public init(drop: GemDrop, atAlongRouteM: Double) {
            self.drop = drop
            self.atAlongRouteM = atAlongRouteM
        }
    }

    private let geometry: RouteGeometry
    private let drops: [GemDrop]                 // sorted by positionAlongRouteM
    private var collectedIDs: Set<UUID> = []
    private var maxProgressM: Double = 0
    private var lastCollection: (coordinate: Coordinate, alongM: Double)?

    public var collected: [UUID] { Array(collectedIDs) }

    public init(geometry: RouteGeometry, drops: [GemDrop]) {
        self.geometry = geometry
        self.drops = drops.sorted { $0.positionAlongRouteM < $1.positionAlongRouteM }
    }

    /// Feed one smoothed sample; returns newly collected drops (usually 0 or 1).
    public mutating func ingest(_ sample: TrackSample) -> [Event] {
        let position = sample.coordinate
        let projection = geometry.project(position)

        // Off-route samples advance nothing and collect nothing.
        guard projection.crossTrackM <= CollectionRules.maxCrossTrackM else { return [] }
        if projection.alongRouteM > maxProgressM { maxProgressM = projection.alongRouteM }

        var events: [Event] = []
        for drop in drops where !collectedIDs.contains(drop.id) {
            let dropAlongM = Double(drop.positionAlongRouteM)
            // Monotonic-progress rule: route progress must have reached the gem's
            // position — physically grazing it across a switchback doesn't count.
            guard maxProgressM + CollectionRules.collectionRadiusM >= dropAlongM else { continue }
            // Physical proximity.
            guard geometry.distance(from: position, to: drop.coordinate)
                    <= CollectionRules.collectionRadiusM else { continue }
            // Hysteresis after the previous collection: leave its exit radius or
            // advance far enough along the route before the next trigger.
            if let last = lastCollection {
                let exited = geometry.distance(from: position, to: last.coordinate)
                    > CollectionRules.hysteresisExitRadiusM
                let advanced = dropAlongM - last.alongM >= CollectionRules.hysteresisAdvanceM
                guard exited || advanced else { continue }
            }
            collectedIDs.insert(drop.id)
            lastCollection = (drop.coordinate, dropAlongM)
            events.append(Event(drop: drop, atAlongRouteM: projection.alongRouteM))
        }
        return events
    }
}
