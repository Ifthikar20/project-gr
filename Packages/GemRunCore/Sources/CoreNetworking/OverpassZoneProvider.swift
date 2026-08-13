import CoreModels
import Foundation
import GameKitCore

/// The day's zones straight from OpenStreetMap: one POST per refresh for
/// parks, strict pedestrian ways and no-go polygons in a 2.5 km circle,
/// classified by OverpassZoneParser and picked by ZoneSelector.
///
/// Overpass is keyless and rate-limits per IP, so this client keeps the
/// backend's manners, ported: mirror loop, per-mirror timeout, an
/// identifying User-Agent with contact, and a 120 s circuit breaker once
/// every mirror fails (429/504 count as failures). The engine calls this
/// roughly once per user per day thanks to the zone day-cache — beta-scale
/// polite. An actor, because the breaker is shared mutable state.
public actor OverpassZoneProvider: ZoneProviding {
    /// Same mirror set the backend queries (gemrun.settings.OVERPASS_URLS).
    static let mirrors: [URL] = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]

    private let timeoutS: TimeInterval = 15
    private let cooldown: Duration = .seconds(120)
    private var downUntil: ContinuousClock.Instant?

    public init() {}

    public func zones(around center: Coordinate, day: Int) async -> [RunnerZone]? {
        if let downUntil, ContinuousClock.now < downUntil {
            GemLog.api.debug("overpass zones: circuit open — skipped")
            return nil
        }
        let query = OverpassZoneParser.query(lat: center.lat, lng: center.lng,
                                            radiusM: Int(ZoneRules.searchRadiusM),
                                            timeoutS: Int(timeoutS))
        for mirror in Self.mirrors {
            do {
                let data = try await post(query, to: mirror)
                let placement = try OverpassZoneParser.placementData(fromJSON: data)
                let zones = ZoneSelector.select(data: placement, around: center,
                                                day: day, source: "overpass")
                GemLog.api.info("overpass zones: \(mirror.host() ?? "?", privacy: .public) answered — \(placement.parks.count) park(s), \(placement.trails.count) trail(s), \(placement.noGoRings.count) no-go ring(s) → \(zones.count) zone(s)")
                return zones
            } catch {
                GemLog.api.warning("overpass zones: \(mirror.host() ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        downUntil = .now + cooldown
        GemLog.api.warning("overpass zones: all mirrors failed — pausing 120s, falling through to the next provider")
        return nil
    }

    private struct BadStatus: Error { let code: Int }

    private func post(_ query: String, to url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeoutS)
        request.httpMethod = "POST"
        // Overpass etiquette: identify yourself and be reachable.
        request.setValue("RunnerCard-iOS/0.1 (+https://runnercard.app; hey@runnercard.app)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = Data("data=\(encoded)".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BadStatus(code: http.statusCode)
        }
        return data
    }
}
