import CoreModels
import Foundation
import GameKitCore

/// The in-app dummy server. Behaves like the future Django backend:
/// - seeds routes around the caller's location (cold start, docs/02)
/// - re-validates completed runs authoritatively by REPLAYING the track
///   through the same CollectionEngine/RunValidator the client used (docs/04)
/// - enforces respawn rules (daily / once-per-user) at award time
/// - fakes competitor leaderboard entries so multi-user UI is visible today
/// Every call logs to the Xcode console with its real /v1 path.
public actor MockGemRunAPI: GemRunAPI {
    private var profile = UserProfile(id: UUID(), handle: "runner")
    private var routes: [UUID: Route] = [:]
    private var archived: Set<UUID> = []
    private var stashItems: [StashItem] = []
    /// Respawn dedupe keys (docs/02): daily → drop+day, once_per_user → drop.
    private var awardedKeys: Set<String> = []
    /// Verdicts by idempotency key — repeat submissions return the same result.
    private var verdicts: [String: RunVerdict] = [:]
    private var userTimes: [UUID: [(timeS: Int, date: Date)]] = [:]
    private var competitorTimes: [UUID: [(handle: String, level: Int, timeS: Int)]] = [:]

    private static let competitors: [(String, Int)] = [
        ("maya.runs", 7), ("dev_collects", 4), ("sam_routes", 11),
        ("pace.ghost", 9), ("gemhound", 3),
    ]

    public init() {
        // First login = the account exists now → welcome gift in the stash.
        stashItems = MockGemRunAPI.welcomeGift()
    }

    private func call(_ line: String) async {
        GemLog.api.debug("[mock] \(line, privacy: .public)")
        try? await Task.sleep(nanoseconds: AppConfig.mockLatencyMs * 1_000_000)
    }

    /// The mock fails the way Django fails — typed HTTPError with the same
    /// title/code/status — so feature code that branches on `code` behaves
    /// identically in mock mode (bare URLErrors made those catches dead).
    private func reject(_ status: Int, _ title: String,
                        code: String? = nil) -> HTTPGemRunAPI.HTTPError {
        HTTPGemRunAPI.HTTPError(title: title, detail: nil, code: code,
                                status: status)
    }

    // MARK: - Auth & user

    public func auth(provider: AuthProvider, handle: String,
                     externalID: String?) async throws -> AuthResponse {
        await call("POST /v1/auth/\(provider.rawValue)  (handle: \(handle))")
        profile.handle = handle
        return AuthResponse(token: "mock-jwt-\(UUID().uuidString.prefix(8))", profile: profile)
    }

    public func adopt(sessionToken: String?) async {
        // The mock has no transport; the session is always "this device".
    }

    public func me() async throws -> UserProfile {
        await call("GET /v1/users/me")
        return profile
    }

    public func checkHandle(_ handle: String) async throws -> Bool {
        await call("GET /v1/handles/check?handle=\(handle)")
        guard handle.count >= 3 else { return false }
        // Mock competitors squat their names; your own handle stays free.
        let taken = Self.competitors.map { $0.0.lowercased() }
        return handle.lowercased() == profile.handle.lowercased()
            || !taken.contains(handle.lowercased())
    }

    public func updateMe(handle: String?) async throws -> UserProfile {
        await call("PATCH /v1/users/me")
        if let handle { profile.handle = handle }
        return profile
    }

    public func deleteAccount() async throws {
        await call("DELETE /v1/users/me")
        awardedKeys.removeAll()
        userTimes.removeAll()
        profile = UserProfile(id: UUID(), handle: "runner")
        // A fresh account starts over — including a fresh welcome gift.
        stashItems = Self.welcomeGift()
    }

    // MARK: - Routes

    public func nearbyRoutes(lat: Double, lng: Double, radiusM: Int) async throws -> [Route] {
        await call("GET /v1/routes?lat=\(lat)&lng=\(lng)&radius_m=\(radiusM)")
        // No demo seeding: only routes users actually published exist.
        return routes.values
            .filter { !archived.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    public func route(id: UUID) async throws -> Route {
        await call("GET /v1/routes/\(id.uuidString.prefix(8))")
        guard let route = routes[id] else {
            throw reject(404, "Route not found")
        }
        return route
    }

    public func publishRoute(_ route: Route) async throws -> Route {
        await call("POST /v1/routes  (\(route.name), \(route.gemDrops.count) gems)")
        // Server-side re-validation of the placement budget (docs/02, docs/06).
        let points = route.gemDrops.compactMap { PlacementBudget.cost(of: $0.rarity) }.reduce(0, +)
        guard route.gemDrops.count <= PlacementBudget.slots(forDistanceM: route.distanceM),
              points <= PlacementBudget.points(forDistanceM: route.distanceM),
              !route.gemDrops.contains(where: { $0.rarity == .legendary }) else {
            throw reject(422, "Gem placement rejected", code: "placement")
        }
        var published = route
        published.status = .published
        routes[route.id] = published
        return published
    }

    public func archiveRoute(id: UUID) async throws {
        await call("DELETE /v1/routes/\(id.uuidString.prefix(8))")
        archived.insert(id)
    }

    // MARK: - Runs

    public func startRun(routeID: UUID) async throws -> RunSession {
        await call("POST /v1/runs  (route \(routeID.uuidString.prefix(8)))")
        let drops = routes[routeID]?.gemDrops ?? []
        return RunSession(runID: UUID(), exactDrops: drops)
    }

    public func completeRun(routeID: UUID, request: RunCompletionRequest) async throws -> RunVerdict {
        await call("POST /v1/runs/\(routeID.uuidString.prefix(8))/complete  "
            + "(\(request.track.count) samples, \(request.claimedCollections.count) claimed)")

        // Idempotency (docs/06): same key → same verdict, no double awards.
        if let existing = verdicts[request.idempotencyKey] { return existing }
        guard let route = routes[routeID] else {
            throw reject(404, "Route not found")
        }

        // Authoritative re-validation: replay the full track (docs/04).
        let geometry = RouteGeometry(polyline: route.polyline)
        let validation = RunValidator.validate(track: request.track, geometry: geometry)
        var engine = CollectionEngine(geometry: geometry, drops: route.gemDrops)
        for sample in request.track { _ = engine.ingest(sample) }
        let replayed = Set(engine.collected)

        var awarded: [GemDrop] = []
        var revoked: [UUID] = []
        if validation.status != .invalid {
            for id in request.claimedCollections {
                guard let drop = route.gemDrops.first(where: { $0.id == id }),
                      replayed.contains(id),                    // track actually supports it
                      claimRespawn(drop) else {                 // dedupe rules (docs/02)
                    revoked.append(id)
                    continue
                }
                awarded.append(drop)
                stashItems.append(StashItem(id: UUID(), gemID: drop.gemID, gemDropID: drop.id,
                                            runID: UUID(), collectedAt: Date()))
            }
        } else {
            revoked = request.claimedCollections
        }

        let xp = validation.status == .invalid ? 0
            : RunValidator.xp(for: awarded, isWalk: validation.isWalk,
                              streakDays: request.clientStreakDays)

        var rank: Int?
        if validation.status == .valid, !validation.isWalk {
            userTimes[routeID, default: []].append((validation.durationS, Date()))
            let allTimes = (competitorTimes[routeID] ?? []).map(\.timeS)
                + userTimes[routeID]!.map(\.timeS)
            rank = allTimes.filter { $0 < validation.durationS }.count + 1
        }

        let verdict = RunVerdict(status: validation.status, awardedDrops: awarded,
                                 revoked: revoked, xpEarned: xp, leaderboardRank: rank)
        verdicts[request.idempotencyKey] = verdict
        return verdict
    }

    // MARK: - Stash & boards

    public func stash() async throws -> StashResponse {
        await call("GET /v1/stash")
        return StashResponse(items: stashItems)
    }

    public func routeLeaderboard(routeID: UUID,
                                 window: LeaderboardWindow) async throws -> [LeaderboardEntry] {
        await call("GET /v1/routes/\(routeID.uuidString.prefix(8))/leaderboard?window=\(window.rawValue)")
        var rows: [(handle: String, level: Int, timeS: Int, isMe: Bool)] =
            (competitorTimes[routeID] ?? []).map { ($0.handle, $0.level, $0.timeS, false) }
        if let best = userTimes[routeID]?.map(\.timeS).min() {
            rows.append((profile.handle, profile.level, best, true))
        }
        return rows.sorted { $0.timeS < $1.timeS }
            .enumerated()
            .map { LeaderboardEntry(rank: $0.offset + 1, handle: $0.element.handle,
                                    level: $0.element.level, bestTimeS: $0.element.timeS,
                                    isMe: $0.element.isMe) }
    }

    public func localLeaderboard(geohash: String) async throws -> [LeaderboardEntry] {
        await call("GET /v1/leaderboards/local?geohash=\(geohash)")
        let weekXP = stashItems.filter {
            $0.collectedAt > Date().addingTimeInterval(-7 * 86_400)
        }.count * 25
        var rows = Self.competitors.enumerated().map { i, c in
            (handle: c.0, level: c.1, score: 950 - i * 180, isMe: false)
        }
        rows.append((profile.handle, profile.level, weekXP, true))
        return rows.sorted { $0.score > $1.score }
            .enumerated()
            .map { LeaderboardEntry(rank: $0.offset + 1, handle: $0.element.handle,
                                    level: $0.element.level, bestTimeS: $0.element.score,
                                    isMe: $0.element.isMe) }
    }

    public func gemCatalog() async throws -> [Gem] {
        await call("GET /v1/gems/catalog")
        return GemCatalog.entries.map(\.gem)
    }

    // MARK: - Compete (friends board + run history)

    private static func rosterID(_ n: UInt8) -> UUID {
        UUID(uuid: (0xF0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    private var mockFriends: [FriendEntry] = [
        FriendEntry(id: MockGemRunAPI.rosterID(1), handle: "strideking",
                    level: 7, isMe: false,
                    weeklyXp: 240, weeklyDistanceM: 12_400, weeklyRuns: 3),
        FriendEntry(id: MockGemRunAPI.rosterID(2), handle: "gemhunter42",
                    level: 5, isMe: false,
                    weeklyXp: 130, weeklyDistanceM: 6_100, weeklyRuns: 2),
    ]
    private let mockPlayers: [PlayerSummary] = [
        PlayerSummary(id: MockGemRunAPI.rosterID(1), handle: "strideking", level: 7),
        PlayerSummary(id: MockGemRunAPI.rosterID(2), handle: "gemhunter42", level: 5),
        PlayerSummary(id: MockGemRunAPI.rosterID(3), handle: "dawnpatrol", level: 9),
        PlayerSummary(id: MockGemRunAPI.rosterID(4), handle: "sidewalksam", level: 3),
        PlayerSummary(id: MockGemRunAPI.rosterID(5), handle: "pearldiver", level: 6),
        PlayerSummary(id: MockGemRunAPI.rosterID(6), handle: "quartzqueen", level: 8),
    ]

    public func myRuns() async throws -> [CompletedRun] {
        await call("GET /v1/runs/mine")
        return []           // mock UI is driven by the local StoredRun list
    }

    public func searchPlayers(query: String) async throws -> [PlayerSummary] {
        await call("GET /v1/players?search=\(query)")
        let q = query.lowercased()
        guard q.count >= 2 else { return [] }
        return mockPlayers.filter { $0.handle.lowercased().contains(q) }
    }

    public func friends() async throws -> [FriendEntry] {
        await call("GET /v1/friends")
        let me = FriendEntry(id: profile.id, handle: profile.handle,
                             level: profile.level, isMe: true,
                             weeklyXp: 120, weeklyDistanceM: 5_200,
                             weeklyRuns: 2)
        return ([me] + mockFriends).sorted { $0.weeklyXp > $1.weeklyXp }
    }

    public func addFriend(profileID: UUID) async throws -> [FriendEntry] {
        await call("POST /v1/friends")
        if !mockFriends.contains(where: { $0.id == profileID }),
           let player = mockPlayers.first(where: { $0.id == profileID }) {
            mockFriends.append(FriendEntry(
                id: player.id, handle: player.handle, level: player.level,
                isMe: false, weeklyXp: 0, weeklyDistanceM: 0, weeklyRuns: 0))
        }
        return try await friends()
    }

    public func removeFriend(profileID: UUID) async throws {
        await call("DELETE /v1/friends/\(profileID)")
        mockFriends.removeAll { $0.id == profileID }
    }

    // MARK: - Standalone drops & the welcome gift

    private var standaloneDrops: [UUID: GemDrop] = [:]
    private var myDropIDs: Set<UUID> = []                  // never collect your own

    /// Server mirror of grant_welcome_gift: a deterministic starter set
    /// (3 common, 2 uncommon, 1 rare) lands in the stash at first login,
    /// so dropping / collecting feels alive from tap zero. No wallet.
    static func welcomeGift() -> [StashItem] {
        func first(_ rarity: Rarity, _ count: Int) -> [GemCatalog.Entry] {
            Array(GemCatalog.entries.filter { $0.gem.rarity == rarity }.prefix(count))
        }
        return (first(.common, 3) + first(.uncommon, 2) + first(.rare, 1)).map {
            StashItem(id: UUID(), gemID: $0.gem.id, gemDropID: UUID(uuid: UUID_NULL),
                      runID: UUID(uuid: UUID_NULL), collectedAt: Date(),
                      isFirstFind: false, source: "gift", dropped: false)
        }
    }

    public func nearbyDrops(lat: Double, lng: Double, radiusM: Int) async throws -> DropsPage {
        await call("GET /v1/drops?lat=\(lat)&lng=\(lng)&radius_m=\(radiusM)")
        // No phantom seeding: real gem placement lives on the backend and
        // is verified walkable. A fixed offset pattern here once produced
        // "the same 3 gems, equally spaced, anywhere" — sometimes on water.
        return DropsPage(drops: Array(standaloneDrops.values), stocking: false)
    }

    public func dropGem(gemID: UUID, lat: Double, lng: Double) async throws -> GemDrop {
        await call("POST /v1/drops  (\(gemID.uuidString.prefix(8)))")
        // Spend one droppable copy from the stash (mirror of the server's
        // not_in_stash rule); the row stays, flagged dropped.
        guard let entry = GemCatalog.entry(forGemID: gemID),
              entry.gem.rarity != .legendary,
              let index = stashItems.firstIndex(where: {
                  $0.gemID == gemID && !($0.dropped ?? false)
              }) else {
            throw reject(422, "That gem isn't in your stash", code: "not_in_stash")
        }
        let spent = stashItems[index]
        stashItems[index] = StashItem(id: spent.id, gemID: spent.gemID,
                                      gemDropID: spent.gemDropID, runID: spent.runID,
                                      collectedAt: spent.collectedAt,
                                      isFirstFind: spent.isFirstFind,
                                      source: spent.source, dropped: true)
        let drop = GemDrop(id: UUID(), gemID: gemID, rarity: entry.gem.rarity,
                           lat: lat, lng: lng, positionAlongRouteM: 0,
                           respawnRule: .oneTime, placedBy: .creator)
        standaloneDrops[drop.id] = drop
        myDropIDs.insert(drop.id)
        return drop
    }

    public func collectDrops(claimed: [UUID],
                             track: [TrackSample]) async throws -> DropCollectResult {
        await call("POST /v1/drops/collect  (\(claimed.count) claimed, \(track.count) samples)")
        var awarded: [GemDrop] = []
        for id in claimed {
            guard let drop = standaloneDrops[id], !myDropIDs.contains(id),
                  trackPassesNear(track, lat: drop.lat, lng: drop.lng) else { continue }
            standaloneDrops.removeValue(forKey: id)        // one-time: first finder
            awarded.append(drop)
            stashItems.append(StashItem(id: UUID(), gemID: drop.gemID, gemDropID: drop.id,
                                        runID: UUID(), collectedAt: Date(),
                                        isFirstFind: true))
        }
        let xp = awarded.reduce(0) { $0 + XPRules.base(for: $1.rarity) }
        return DropCollectResult(awardedDrops: awarded, xpEarned: xp)
    }

    private func trackPassesNear(_ track: [TrackSample], lat: Double, lng: Double) -> Bool {
        let k = 111_320.0
        let klng = k * cos(lat * .pi / 180)
        return track.contains { s in
            let dy = (s.lat - lat) * k
            let dx = (s.lng - lng) * klng
            return (dx * dx + dy * dy).squareRoot() <= CollectionRules.dropCollectRadiusM
        }
    }

    /// "Someone else loaded the app and left gems near you": three drops from
    /// other runners within a few hundred meters, waiting to be run to.
    // MARK: - Internals

    private func claimRespawn(_ drop: GemDrop) -> Bool {
        let key: String = switch drop.respawnRule {
        case .daily:
            "\(drop.id)-\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)"
        case .oncePerUser, .oneTime:
            "\(drop.id)"
        }
        guard !awardedKeys.contains(key) else { return false }
        awardedKeys.insert(key)
        return true
    }

}
