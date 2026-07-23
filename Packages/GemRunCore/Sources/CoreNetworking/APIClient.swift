import CoreModels
import Foundation

/// URLSession implementation of GemRunAPI for the real backend (Python/Django,
/// docs/06 paths). Dormant until AppConfig.apiBaseURL is set — the UI runs on
/// MockGemRunAPI until then, against these exact shapes.
public final class HTTPGemRunAPI: GemRunAPI {
    private let baseURL: URL
    private let session = URLSession.shared
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    /// JWT from /v1/auth/apple; attach to every request. Keychain in Phase F polish.
    private var token: String?

    public init(baseURL: URL) {
        self.baseURL = baseURL
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - GemRunAPI

    public func auth(handle: String) async throws -> AuthResponse {
        let response: AuthResponse = try await send("POST", "auth/apple",
                                                    body: ["handle": handle])
        token = response.token
        return response
    }

    public func me() async throws -> UserProfile {
        try await get("users/me")
    }

    public func updateMe(handle: String?) async throws -> UserProfile {
        try await send("PATCH", "users/me", body: ["handle": handle])
    }

    public func deleteAccount() async throws {
        let _: Empty = try await send("DELETE", "users/me", body: Empty())
    }

    public func nearbyRoutes(lat: Double, lng: Double, radiusM: Int) async throws -> [Route] {
        try await get("routes", query: ["lat": "\(lat)", "lng": "\(lng)",
                                        "radius_m": "\(radiusM)"])
    }

    public func route(id: UUID) async throws -> Route {
        try await get("routes/\(id.uuidString)")
    }

    public func publishRoute(_ route: Route) async throws -> Route {
        try await send("POST", "routes", body: route)
    }

    public func archiveRoute(id: UUID) async throws {
        let _: Empty = try await send("DELETE", "routes/\(id.uuidString)", body: Empty())
    }

    public func startRun(routeID: UUID) async throws -> RunSession {
        try await send("POST", "runs", body: ["route_id": routeID.uuidString])
    }

    public func completeRun(routeID: UUID,
                            request: RunCompletionRequest) async throws -> RunVerdict {
        try await send("POST", "runs/\(routeID.uuidString)/complete", body: request)
    }

    public func stash() async throws -> StashResponse {
        try await get("stash")
    }

    public func routeLeaderboard(routeID: UUID,
                                 window: LeaderboardWindow) async throws -> [LeaderboardEntry] {
        try await get("routes/\(routeID.uuidString)/leaderboard",
                      query: ["window": window.rawValue])
    }

    public func localLeaderboard(geohash: String) async throws -> [LeaderboardEntry] {
        try await get("leaderboards/local", query: ["geohash": geohash])
    }

    public func gemCatalog() async throws -> [Gem] {
        try await get("gems/catalog")
    }

    // MARK: - Gem wallet + standalone drops

    private struct WalletResponse: Decodable {
        let wallet: [String: Int]
    }

    public func syncWallet(totalRunKm: Double) async throws -> GemWallet {
        let response: WalletResponse = try await send("POST", "wallet/sync",
                                                      body: ["total_run_km": totalRunKm])
        var wallet: GemWallet = [:]
        for (key, count) in response.wallet {
            if let rarity = Rarity(rawValue: key) { wallet[rarity] = count }
        }
        return wallet
    }

    private struct DropsResponse: Decodable {
        let drops: [GemDrop]
    }

    public func nearbyDrops(lat: Double, lng: Double, radiusM: Int) async throws -> [GemDrop] {
        let response: DropsResponse = try await get("drops", query: [
            "lat": "\(lat)", "lng": "\(lng)", "radius_m": "\(radiusM)",
        ])
        return response.drops
    }

    private struct DropRequest: Encodable {
        let gemId: String
        let lat: Double
        let lng: Double
    }

    public func dropGem(gemID: UUID, lat: Double, lng: Double) async throws -> GemDrop {
        try await send("POST", "drops",
                       body: DropRequest(gemId: gemID.uuidString, lat: lat, lng: lng))
    }

    private struct CollectRequest: Encodable {
        let claimed: [UUID]
        let track: [TrackSample]
    }

    private struct CollectResponse: Decodable {
        let awardedDrops: [GemDrop]
        let xpEarned: Int
    }

    public func collectDrops(claimed: [UUID],
                             track: [TrackSample]) async throws -> DropCollectResult {
        let response: CollectResponse = try await send(
            "POST", "drops/collect", body: CollectRequest(claimed: claimed, track: track))
        return DropCollectResult(awardedDrops: response.awardedDrops,
                                 xpEarned: response.xpEarned)
    }

    // MARK: - Plumbing

    private struct Empty: Codable {}

    public struct HTTPError: Error, Decodable {
        public let title: String
        public let detail: String?
        public let code: String?
    }

    private func get<T: Decodable>(_ path: String,
                                   query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: "v1/\(path)"),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String,
                                                  body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: "v1/\(path)"))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    private func authorize(_ request: inout URLRequest) {
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw (try? decoder.decode(HTTPError.self, from: data))
                ?? HTTPError(title: "HTTP \(http.statusCode)", detail: nil, code: nil)
        }
        if data.isEmpty, let empty = Empty() as? T { return empty }
        return try decoder.decode(T.self, from: data)
    }
}
