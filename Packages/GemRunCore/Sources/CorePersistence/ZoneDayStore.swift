import CoreModels
import Foundation
import GameKitCore

/// Day-scoped zone state, deliberately in UserDefaults rather than
/// SwiftData: the day cache and partial progress are disposable by design
/// (tomorrow replaces them wholesale), so they shouldn't cost schema
/// surface. Cards — the things that must last — are StoredRunnerCard.
public enum ZoneCacheStore {
    private static let key = "gemrun.zones.v1"

    struct Snapshot: Codable {
        let day: Int
        let centerLat: Double
        let centerLng: Double
        let zones: [RunnerZone]
    }

    /// The cached line-up, valid only for the same day and while the user
    /// is still within 2 km of where it was fetched — move across town and
    /// the zones re-resolve.
    public static func load(day: Int, near center: Coordinate) -> [RunnerZone]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.day == day,
              RouteGeometry.planarDistance(
                  from: Coordinate(lat: snapshot.centerLat, lng: snapshot.centerLng),
                  to: center) <= 2_000 else { return nil }
        return snapshot.zones
    }

    public static func save(day: Int, center: Coordinate, zones: [RunnerZone]) {
        let snapshot = Snapshot(day: day, centerLat: center.lat,
                                centerLng: center.lng, zones: zones)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Partial metres and mint counts per zone, keyed to the day — cleared by
/// rollover, resumed mid-day so backgrounding never eats a half-walked
/// kilometre.
public enum ZoneProgressStore {
    private static let key = "gemrun.zoneProgress.v1"

    struct Snapshot: Codable {
        let day: Int
        var progressM: [UUID: Double]
        var mintCounts: [UUID: Int]
    }

    public static func load(day: Int) -> (progressM: [UUID: Double],
                                          mintCounts: [UUID: Int]) {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.day == day else { return ([:], [:]) }
        return (snapshot.progressM, snapshot.mintCounts)
    }

    public static func save(day: Int, progressM: [UUID: Double],
                            mintCounts: [UUID: Int]) {
        let snapshot = Snapshot(day: day, progressM: progressM,
                                mintCounts: mintCounts)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Dev shortcut for exercising the mint flow without walking a literal
/// kilometre: `gemrun.debug.mintThresholdM` in UserDefaults, or the
/// RUNNERCARD_MINT_M env var (simulator runs). Absent or non-positive
/// means the real rule.
public enum MintThresholdOverride {
    public static func current() -> Double? {
        let stored = UserDefaults.standard.double(forKey: "gemrun.debug.mintThresholdM")
        if stored > 0 { return stored }
        if let raw = ProcessInfo.processInfo.environment["RUNNERCARD_MINT_M"],
           let value = Double(raw), value > 0 {
            return value
        }
        return nil
    }
}
