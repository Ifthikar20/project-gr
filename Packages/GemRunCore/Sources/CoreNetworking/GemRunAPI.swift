import CoreModels
import Foundation

// The full client-facing API surface (docs/06). Two implementations:
//   MockGemRunAPI — in-app dummy server (in-memory, simulated latency, fake
//                   competitors). Active whenever no base URL is configured.
//   HTTPGemRunAPI — URLSession client for the real backend (Python/Django,
//                   same paths + JSON shapes). Activates via AppConfig.
// UI code only ever sees `API.shared`, so the Django swap is one URL change.

public enum AppConfig {
    /// Backend base URL, resolved at launch — never hardcoded. Priority:
    ///   1. `GEMRUN_API_URL` env var  ("mock" forces the in-app mock;
    ///      run.sh passes the local Django URL here via SIMCTL_CHILD_…)
    ///   2. `GemRunAPIBaseURL` Info.plist key (set per-config in project.yml)
    ///   3. Simulator debug builds default to the local Django server
    ///      (backend/README.md) so the UI reads live data out of the box.
    /// nil = in-app MockGemRunAPI (device builds with nothing configured).
    public static let apiBaseURL: URL? = resolveBaseURL()

    /// Simulated latency for the mock, in milliseconds. Keep small — the UI
    /// renders cached data instantly and refreshes when calls land.
    public static let mockLatencyMs: UInt64 = 150

    private static func resolveBaseURL() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["GEMRUN_API_URL"] {
            return raw.lowercased() == "mock" ? nil : URL(string: raw)
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "GemRunAPIBaseURL") as? String,
           !raw.isEmpty {
            return raw.lowercased() == "mock" ? nil : URL(string: raw)
        }
        #if DEBUG && targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8000")
        #else
        return nil
        #endif
    }
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

    enum CodingKeys: String, CodingKey {
        case exactDrops
        case runID = "runId"
    }

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


public struct DropCollectResult: Sendable {
    public let awardedDrops: [GemDrop]
    public let xpEarned: Int

    public init(awardedDrops: [GemDrop], xpEarned: Int) {
        self.awardedDrops = awardedDrops
        self.xpEarned = xpEarned
    }
}

/// A player found by handle search (Compete → friends board).
public struct PlayerSummary: Codable, Identifiable, Sendable {
    public let id: UUID
    public let handle: String
    public let level: Int

    public init(id: UUID, handle: String, level: Int) {
        self.id = id
        self.handle = handle
        self.level = level
    }
}

/// One row of the weekly friends board — you plus everyone you follow,
/// with this week's totals (Monday 00:00 UTC onward), ranked by XP.
public struct FriendEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let handle: String
    public let level: Int
    public let isMe: Bool
    public let weeklyXp: Int
    public let weeklyDistanceM: Int
    public let weeklyRuns: Int

    public init(id: UUID, handle: String, level: Int, isMe: Bool,
                weeklyXp: Int, weeklyDistanceM: Int, weeklyRuns: Int) {
        self.id = id
        self.handle = handle
        self.level = level
        self.isMe = isMe
        self.weeklyXp = weeklyXp
        self.weeklyDistanceM = weeklyDistanceM
        self.weeklyRuns = weeklyRuns
    }
}

/// A completed run from the server's history (Compete → "My Routes").
/// The phone's own SwiftData copy is richer (gems collected, free runs);
/// this fills in history on a fresh install or second device.
public struct CompletedRun: Codable, Identifiable, Sendable {
    public let id: UUID
    public let routeId: UUID
    public let routeName: String
    public let startedAt: Date
    public let durationS: Int
    public let distanceM: Int
    public let paceSPerKm: Int
    public let isWalk: Bool
    public let status: String
    public let xpEarned: Int

    public init(id: UUID, routeId: UUID, routeName: String, startedAt: Date,
                durationS: Int, distanceM: Int, paceSPerKm: Int, isWalk: Bool,
                status: String, xpEarned: Int) {
        self.id = id
        self.routeId = routeId
        self.routeName = routeName
        self.startedAt = startedAt
        self.durationS = durationS
        self.distanceM = distanceM
        self.paceSPerKm = paceSPerKm
        self.isWalk = isWalk
        self.status = status
        self.xpEarned = xpEarned
    }
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

    // Compete — GET /v1/runs/mine, GET /v1/players?search=,
    //           GET/POST /v1/friends, DELETE /v1/friends/{id}
    /// My completed-run history (server copy of the local StoredRun list).
    func myRuns() async throws -> [CompletedRun]
    /// Case-insensitive handle search, excluding me. Empty under 2 chars.
    func searchPlayers(query: String) async throws -> [PlayerSummary]
    /// The weekly board: me + everyone I follow, ranked by this week's XP.
    func friends() async throws -> [FriendEntry]
    /// Follow a player; returns the refreshed board. Idempotent.
    func addFriend(profileID: UUID) async throws -> [FriendEntry]
    /// Unfollow — removes only MY follow row.
    func removeFriend(profileID: UUID) async throws

    // Catalog — GET /v1/gems/catalog
    func gemCatalog() async throws -> [Gem]

    // Standalone drops — GET/POST /v1/drops, POST /v1/drops/collect
    /// Standalone drops other runners left near this location.
    func nearbyDrops(lat: Double, lng: Double, radiusM: Int) async throws -> [GemDrop]
    /// Give one of your stash gems away as a map drop (one-time; first
    /// finder takes it; the stash row stays as the collection record).
    func dropGem(gemID: UUID, lat: Double, lng: Double) async throws -> GemDrop
    /// Claim standalone drops passed during a free run; server checks the track.
    func collectDrops(claimed: [UUID], track: [TrackSample]) async throws -> DropCollectResult
}
