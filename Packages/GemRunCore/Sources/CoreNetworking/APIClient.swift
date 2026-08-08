import CoreModels
import Foundation

/// URLSession implementation of GemRunAPI for the real backend (Python/Django,
/// docs/06 paths). Dormant until AppConfig.apiBaseURL is set — the UI runs on
/// MockGemRunAPI until then, against these exact shapes.
public final class HTTPGemRunAPI: GemRunAPI {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    /// JWT from /v1/auth/apple; attach to every request. Keychain in Phase F polish.
    private var token: String?

    public init(baseURL: URL) {
        self.baseURL = baseURL
        // Explicit timeouts instead of URLSession's 60 s default: the
        // server bounds first-contact stocking (PRESENCE_INLINE_BUDGET_S)
        // so an honest answer always arrives well inside 15 s — anything
        // slower is a dead network, and the first-load cover's Retry
        // screen is a better answer than a minute-long hang.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - GemRunAPI

    private struct AuthRequest: Encodable {
        let handle: String
        let externalUserId: String?
        let identityToken: String?
    }

    public func auth(provider: AuthProvider, handle: String,
                     externalID: String?,
                     identityToken: String?) async throws -> AuthResponse {
        let response: AuthResponse = try await send(
            "POST", "auth/\(provider.rawValue)",
            body: AuthRequest(handle: handle, externalUserId: externalID,
                              identityToken: identityToken))
        token = response.token
        return response
    }

    public func adopt(sessionToken: String?) async {
        token = sessionToken
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

    private struct HandleCheckResponse: Decodable {
        let available: Bool
    }

    public func checkHandle(_ handle: String) async throws -> Bool {
        let response: HandleCheckResponse = try await get(
            "handles/check", query: ["handle": handle])
        return response.available
    }

    private struct RoutesResponse: Decodable {
        let routes: [Route]
    }

    public func nearbyRoutes(lat: Double, lng: Double, radiusM: Int) async throws -> [Route] {
        let response: RoutesResponse = try await get(
            "routes", query: ["lat": "\(lat)", "lng": "\(lng)",
                              "radius_m": "\(radiusM)"])
        return response.routes
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

    private struct EntriesResponse: Decodable {
        let entries: [LeaderboardEntry]
    }

    public func routeLeaderboard(routeID: UUID,
                                 window: LeaderboardWindow) async throws -> [LeaderboardEntry] {
        let response: EntriesResponse = try await get(
            "routes/\(routeID.uuidString)/leaderboard",
            query: ["window": window.rawValue])
        return response.entries
    }

    public func localLeaderboard(geohash: String) async throws -> [LeaderboardEntry] {
        let response: EntriesResponse = try await get("leaderboards/local",
                                                      query: ["geohash": geohash])
        return response.entries
    }

    private struct CatalogResponse: Decodable {
        let gems: [Gem]
    }

    public func gemCatalog() async throws -> [Gem] {
        let response: CatalogResponse = try await get("gems/catalog")
        return response.gems
    }

    // MARK: - Standalone drops

    private struct DropsResponse: Decodable {
        let drops: [GemDrop]
        // Optional so older server builds (no flag) still decode.
        let stocking: Bool?
    }

    public func nearbyDrops(lat: Double, lng: Double, radiusM: Int) async throws -> DropsPage {
        let response: DropsResponse = try await get("drops", query: [
            "lat": "\(lat)", "lng": "\(lng)", "radius_m": "\(radiusM)",
        ])
        return DropsPage(drops: response.drops,
                         stocking: response.stocking ?? false)
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

    // MARK: - Compete

    private struct RunsResponse: Decodable { let runs: [CompletedRun] }
    private struct PlayersResponse: Decodable { let players: [PlayerSummary] }
    private struct FriendsResponse: Decodable { let friends: [FriendEntry] }

    public func myRuns() async throws -> [CompletedRun] {
        let response: RunsResponse = try await get("runs/mine")
        return response.runs
    }

    public func searchPlayers(query: String) async throws -> [PlayerSummary] {
        let response: PlayersResponse = try await get("players",
                                                      query: ["search": query])
        return response.players
    }

    public func friends() async throws -> [FriendEntry] {
        let response: FriendsResponse = try await get("friends")
        return response.friends
    }

    public func addFriend(profileID: UUID) async throws -> [FriendEntry] {
        let response: FriendsResponse = try await send(
            "POST", "friends", body: ["profile_id": profileID.uuidString])
        return response.friends
    }

    public func removeFriend(profileID: UUID) async throws {
        let _: Empty = try await send("DELETE",
                                      "friends/\(profileID.uuidString)",
                                      body: Empty())
    }

    // MARK: - Plumbing

    private struct Empty: Codable {}

    public struct HTTPError: Error, Decodable, LocalizedError {
        public let title: String
        public let detail: String?
        public let code: String?
        /// HTTP status — not part of the problem+json body; filled at the
        /// throw site so feature code can branch on 401 vs 409 vs 500
        /// instead of string-matching. -1 when transport never happened.
        public var status: Int = -1

        private enum CodingKeys: String, CodingKey { case title, detail, code }

        public var errorDescription: String? {
            detail.map { "\(title) — \($0)" } ?? title
        }
    }

    private func get<T: Decodable>(_ path: String,
                                   query: [String: String] = [:]) async throws -> T {
        // User-typed input (handle checks, player search) reaches this URL
        // build — a force-unwrap here was a keystroke-triggered crash.
        guard var components = URLComponents(url: baseURL.appending(path: "v1/\(path)"),
                                             resolvingAgainstBaseURL: false) else {
            GemLog.api.error("GET /v1/\(path, privacy: .public): base URL rejected by URLComponents")
            throw URLError(.badURL)
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            GemLog.api.error("GET /v1/\(path, privacy: .public): could not compose request URL")
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        return try decode(data, response, context: "GET /v1/\(path)")
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String,
                                                  body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: "v1/\(path)"))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        return try decode(data, response, context: "\(method) /v1/\(path)")
    }

    private func authorize(_ request: inout URLRequest) {
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Decode with verbose logging: every call logs its outcome, and
    /// failures log the FULL error — a keyNotFound decode mismatch silently
    /// emptied the map once; never again. Failures are `.error` (persisted
    /// on device); success chatter is `.debug` (live-capture only).
    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse,
                                      context: String) throws -> T {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var error = (try? decoder.decode(HTTPError.self, from: data))
                ?? HTTPError(title: "HTTP \(http.statusCode)", detail: nil, code: nil)
            error.status = http.statusCode
            let detailSuffix = error.detail.map { " — \($0)" } ?? ""
            GemLog.api.error("\(context, privacy: .public) -> \(http.statusCode) ERROR: \(error.title, privacy: .public)\(detailSuffix, privacy: .public)")
            throw error
        }
        if data.isEmpty, let empty = Empty() as? T {
            GemLog.api.debug("\(context, privacy: .public) -> OK (empty)")
            return empty
        }
        do {
            let value = try decoder.decode(T.self, from: data)
            GemLog.api.debug("\(context, privacy: .public) -> OK (\(data.count) bytes)")
            return value
        } catch {
            GemLog.api.error("\(context, privacy: .public) -> DECODE FAILED: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
