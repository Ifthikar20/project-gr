import CoreModels
import Foundation

/// Everything a finished run needs for validation + persistence. Produced by
/// ActiveRunEngine (CoreLocationKit), consumed by SessionStore (CorePersistence).
public struct RunResult: Sendable {
    public let route: Route
    public let startedAt: Date
    public let track: [TrackSample]
    public let collectedDrops: [GemDrop]
    public let validation: RunValidator.Result

    public init(route: Route, startedAt: Date, track: [TrackSample],
                collectedDrops: [GemDrop], validation: RunValidator.Result) {
        self.route = route
        self.startedAt = startedAt
        self.track = track
        self.collectedDrops = collectedDrops
        self.validation = validation
    }
}

/// Full-track validation (docs/04): route adherence, coverage, pace bounds,
/// teleport detection. The client runs this for instant honest UX; the server
/// re-runs the same rules authoritatively (docs/06).
public enum RunValidator {
    public struct Result: Sendable {
        public let status: RunValidationStatus
        public let flags: [String]
        public let durationS: Int
        public let distanceM: Int
        public let paceSPerKm: Int
        public let isWalk: Bool
        public let onRouteRatio: Double
        public let coverageRatio: Double
    }

    public static func validate(track: [TrackSample], geometry: RouteGeometry) -> Result {
        guard track.count >= 2, geometry.totalLengthM > 0 else {
            return Result(status: .invalid, flags: ["empty_track"], durationS: 0,
                          distanceM: 0, paceSPerKm: 0, isWalk: false,
                          onRouteRatio: 0, coverageRatio: 0)
        }

        var onRoute = 0
        var maxProgress = 0.0
        var distanceM = 0.0
        var teleportRunS: TimeInterval = 0
        var flags: [String] = []

        for (i, sample) in track.enumerated() {
            let projection = geometry.project(sample.coordinate)
            if projection.crossTrackM <= CollectionRules.maxCrossTrackM {
                onRoute += 1
                maxProgress = max(maxProgress, projection.alongRouteM)
            }
            if i > 0 {
                let prev = track[i - 1]
                let dt = max(0.001, sample.t - prev.t)
                let d = geometry.distance(from: prev.coordinate, to: sample.coordinate)
                distanceM += d
                if d / dt > CollectionRules.teleportSpeed {
                    teleportRunS += dt
                    if teleportRunS >= CollectionRules.teleportSustainS,
                       !flags.contains("teleport") {
                        flags.append("teleport")
                    }
                } else {
                    teleportRunS = 0
                }
            }
        }

        let durationS = Int(track.last!.t - track.first!.t)
        let onRouteRatio = Double(onRoute) / Double(track.count)
        let coverageRatio = maxProgress / geometry.totalLengthM
        let paceSPerKm = distanceM > 50 ? Int(Double(durationS) / (distanceM / 1_000)) : 0
        let isWalk = paceSPerKm > CollectionRules.walkPaceThresholdSPerKm
            && paceSPerKm <= CollectionRules.maxValidPaceSPerKm

        if onRouteRatio < CollectionRules.minOnRouteSampleRatio { flags.append("adherence") }
        if coverageRatio < CollectionRules.minRouteCoverageRatio { flags.append("coverage") }
        if paceSPerKm > 0, paceSPerKm < CollectionRules.minRunPaceSPerKm { flags.append("too_fast") }
        if paceSPerKm > CollectionRules.maxValidPaceSPerKm { flags.append("too_slow") }

        let status: RunValidationStatus =
            flags.contains("too_fast") || flags.contains("too_slow") || coverageRatio < 0.5
            ? .invalid
            : (flags.isEmpty ? .valid : .flagged)

        return Result(status: status, flags: flags, durationS: durationS,
                      distanceM: Int(distanceM), paceSPerKm: paceSPerKm, isWalk: isWalk,
                      onRouteRatio: onRouteRatio, coverageRatio: coverageRatio)
    }

    /// Total XP for a set of collected drops under the docs/02 rules.
    public static func xp(for drops: [GemDrop], isWalk: Bool, streakDays: Int) -> Int {
        let base = drops.reduce(0) { $0 + XPRules.base(for: $1.rarity) }
        let walkFactor = isWalk ? XPRules.walkMultiplier : 1.0
        let streakFactor = StreakRules.multiplier(streakDays: streakDays)
        return Int((Double(base) * walkFactor * streakFactor).rounded())
    }
}
