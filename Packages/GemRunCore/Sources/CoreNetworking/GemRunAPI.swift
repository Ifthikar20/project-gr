import CoreModels
import Foundation

// The full client-facing API surface (docs/06). Two implementations:
//   MockGemRunAPI — in-app dummy server (in-memory, simulated latency, fake
//                   competitors). Active whenever no base URL is configured.
//   HTTPGemRunAPI — URLSession client for the real backend (Python/Django,
//                   same paths + JSON shapes). Activates via AppConfig.
// UI code only ever sees `API.shared`, so the Django swap is one URL change.

public enum AppConfig {
    /// Set to the deployed Django backend URL to switch off the mock.
    public static let apiBaseURL: URL? = nil
    /// Simulated latency for the mock, in milliseconds. Keep small — the UI
    /// renders cached data instantly and refreshes when calls land.
    public static let mockLatencyMs: UInt64 = 150
}

public enum API {
    public static let shared: any GemRunAPI = {
        if let url = AppConfig.apiBaseURL {
            HTTPGemRunAPI(baseURL: url)
        } else {
            MockGemRunAPI()
        }
    }()
}

// MARK: - Wire types

public struct AuthResponse: Codable, Sendable {
    public let token: String
    public let profile: UserProfile

    public init(token: String, profile: UserProfile) {
        self.token = token
        self.profile = profile
    }
}

/// POST /v1/runs response: server run session + exact coordinates for every
/// active drop (including fuzzed ones) so offline collection works (docs/06).
public struct RunSession: Codable, Sendable {
    public let runID: UUID
    public let exactDrops: [GemDrop]

    public init(runID: UUID, exactDrops: [GemDrop]) {
        self.runID = runID
        self.exactDrops = exactDrops
    }
}

public struct RunCompletionRequest: Codable, Sendable {
    public let idempotencyKey: String
    public let startedAt: Date
    public let endedAt: Date
    public let track: [TrackSample]
    public let claimedCollections: [UUID]
    public let clientFlags: [String]
    /// Mock-only convenience: the real backend owns streak state itself.
    public let clientStreakDays: Int

    public init(idempotencyKey: String, startedAt: Date, endedAt: Date,
                track: [TrackSample], claimedCollections: [UUID],
                clientFlags: [String], clientStreakDays: Int) {
        self.idempotencyKey = idempotencyKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.track = track
        self.claimedCollections = claimedCollections
        self.clientFlags = clientFlags
        self.clientStreakDays = clientStreakDays
    }
}

/// The authoritative verdict (docs/06): client collection was optimistic;
/// `awardedDrops` is what actually counts and `revoked` is what didn't survive.
public struct RunVerdict: Codable, Sendable {
    public let status: RunValidationStatus
    public let awardedDrops: [GemDrop]
    public let revoked: [UUID]
    public let xpEarned: Int
    public let leaderboardRank: Int?

    public init(status: RunValidationStatus, awardedDrops: [GemDrop], revoked: [UUID],
                xpEarned: Int, leaderboardRank: Int?) {
        self.status = status
        self.awardedDrops = awardedDrops
        self.revoked = revoked
        self.xpEarned = xpEarned
        self.leaderboardRank = leaderboardRank
    }
}

public struct StashResponse: Codable, Sendable {
    public let items: [StashItem]

    public init(items: [StashItem]) {
        self.items = items
    }
}

public enum LeaderboardWindow: String, Codable, Sendable {
    case allTime = "all"
    case month
}

// MARK: - The contract

public protocol GemRunAPI: Sendable {
    // Auth & user — POST /v1/auth/apple, GET/PATCH/DELETE /v1/users/me
    func auth(handle: String) async throws -> AuthResponse
    func me() async throws -> UserProfile
    func updateMe(handle: String?) async throws -> UserProfile
    func deleteAccount() async throws

    // Routes — GET /v1/routes, GET /v1/routes/{id}, POST /v1/routes,
    //          DELETE /v1/routes/{id} (archive)
    func nearbyRoutes(lat: Double, lng: Double, radiusM: Int) async throws -> [Route]
    func route(id: UUID) async throws -> Route
    func publishRoute(_ route: Route) async throws -> Route
    func archiveRoute(id: UUID) async throws

    // Runs — POST /v1/runs, POST /v1/runs/{id}/complete (idempotent)
    func startRun(routeID: UUID) async throws -> RunSession
    func completeRun(routeID: UUID, request: RunCompletionRequest) async throws -> RunVerdict

    // Stash & boards — GET /v1/stash, GET /v1/routes/{id}/leaderboard,
    //                  GET /v1/leaderboards/local
    func stash() async throws -> StashResponse
    func routeLeaderboard(routeID: UUID, window: LeaderboardWindow) async throws -> [LeaderboardEntry]
    func localLeaderboard(geohash: String) async throws -> [LeaderboardEntry]

    // Catalog — GET /v1/gems/catalog
    func gemCatalog() async throws -> [Gem]
}
