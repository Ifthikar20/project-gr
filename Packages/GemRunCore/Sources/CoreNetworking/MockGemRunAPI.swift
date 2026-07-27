import CoreMap
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
    private var seeded = false

    private static let competitors: [(String, Int)] = [
        ("maya.runs", 7), ("dev_collects", 4), ("sam_routes", 11),
        ("pace.ghost", 9), ("gemhound", 3),
    ]

    public init() {}

    private func call(_ line: String) async {
        print("[MockAPI] \(line)")
        try? await Task.sleep(nanoseconds: AppConfig.mockLatencyMs * 1_000_000)
    }

    // MARK: - Auth & user

    public func auth(handle: String) async throws -> AuthResponse {
        await call("POST /v1/auth/apple  (handle: \(handle))")
        profile.handle = handle
        return AuthResponse(token: "mock-jwt-\(UUID().uuidString.prefix(8))", profile: profile)
    }

    public func me() async throws -> UserProfile {
        await call("GET /v1/users/me")
        return profile
    }

    public func updateMe(handle: String?) async throws -> UserProfile {
        await call("PATCH /v1/users/me")
        if let handle { profile.handle = handle }
        return profile
    }

    public func deleteAccount() async throws {
        await call("DELETE /v1/users/me")
        stashItems.removeAll()
        awardedKeys.removeAll()
        userTimes.removeAll()
        profile = UserProfile(id: UUID(), handle: "runner")
    }

    // MARK: - Routes

    public func nearbyRoutes(lat: Double, lng: Double, radiusM: Int) async throws -> [Route] {
        await call("GET /v1/routes?lat=\(lat)&lng=\(lng)&radius_m=\(radiusM)")
        await seedIfNeeded(around: Coordinate(lat: lat, lng: lng))
        return routes.values
            .filter { !archived.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    public func route(id: UUID) async throws -> Route {
        await call("GET /v1/routes/\(id.uuidString.prefix(8))")
        guard let route = routes[id] else { throw URLError(.fileDoesNotExist) }
        return route
    }

    public func publishRoute(_ route: Route) async throws -> Route {
        await call("POST /v1/routes  (\(route.name), \(route.gemDrops.count) gems)")
        // Server-side re-validation of the placement budget (docs/02, docs/06).
        let points = route.gemDrops.compactMap { PlacementBudget.cost(of: $0.rarity) }.reduce(0, +)
        guard route.gemDrops.count <= PlacementBudget.slots(forDistanceM: route.distanceM),
              points <= PlacementBudget.points(forDistanceM: route.distanceM),
              !route.gemDrops.contains(where: { $0.rarity == .legendary }) else {
            throw URLError(.cannotParseResponse)
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
        guard let route = routes[routeID] else { throw URLError(.fileDoesNotExist) }

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

    // MARK: - Gem wallet + standalone drops

    // Starter pack: new runners open the app with a handful of gems already
    // in the wallet, so dropping / running feels alive from tap zero.
    private var wallet: GemWallet = [.common: 5, .uncommon: 3, .rare: 1]
    private var mintedCounts: [Rarity: Int] = [:]
    private var standaloneDrops: [UUID: GemDrop] = [:]
    private var myDropIDs: Set<UUID> = []                  // never collect your own
    private var seededStandalone = false

    public func syncWallet(totalRunKm: Double) async throws -> GemWallet {
        await call("POST /v1/wallet/sync  (\(String(format: "%.1f", totalRunKm)) km)")
        for (tier, threshold) in MintRules.thresholdKm {
            let earned = Int(totalRunKm / threshold)
            let delta = earned - (mintedCounts[tier] ?? 0)
            if delta > 0 {
                wallet[tier, default: 0] += delta
                mintedCounts[tier] = earned
            }
        }
        return wallet
    }

    public func nearbyDrops(lat: Double, lng: Double, radiusM: Int) async throws -> [GemDrop] {
        await call("GET /v1/drops?lat=\(lat)&lng=\(lng)&radius_m=\(radiusM)")
        seedStandaloneIfNeeded(around: Coordinate(lat: lat, lng: lng))
        return Array(standaloneDrops.values)
    }

    public func dropGem(gemID: UUID, lat: Double, lng: Double) async throws -> GemDrop {
        await call("POST /v1/drops  (\(gemID.uuidString.prefix(8)))")
        guard let entry = GemCatalog.entry(forGemID: gemID),
              entry.gem.rarity != .legendary,
              wallet[entry.gem.rarity, default: 0] > 0 else {
            throw URLError(.cannotParseResponse)
        }
        wallet[entry.gem.rarity]! -= 1
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
    private func seedStandaloneIfNeeded(around center: Coordinate) {
        guard !seededStandalone else { return }
        seededStandalone = true
        let placements: [(Rarity, Double, Double)] = [
            (.common, 220, 140), (.uncommon, -310, 260), (.rare, 90, -420),
        ]
        for (rarity, dLatM, dLngM) in placements {
            let position = Self.offset(center, dLatM: dLatM, dLngM: dLngM)
            let drop = GemDrop(id: UUID(), gemID: GemCatalog.gem(of: rarity).id,
                               rarity: rarity, lat: position.lat, lng: position.lng,
                               positionAlongRouteM: 0, respawnRule: .oneTime,
                               placedBy: .creator)
            standaloneDrops[drop.id] = drop
        }
    }

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

    /// Cold-start seeding (docs/02): recommended routes START at the caller's
    /// location and follow real streets — every leg snapped through Apple
    /// walking directions (PathSnapper), never geometric circles. A route
    /// whose legs can't be confirmed on the street network is skipped:
    /// better no demo route than one crossing water or backyards.
    private func seedIfNeeded(around center: Coordinate) async {
        guard !seeded else { return }
        seeded = true
        // (name, legs walked out from the start as (bearing°, meters), gems)
        let specs: [(String, [(Double, Double)], [(Rarity, Double)])] = [
            ("First Light Loop", [(20, 450), (140, 450)],
             [(.common, 0.15), (.common, 0.5), (.uncommon, 0.85)]),
            ("Gem Hunter's Circuit", [(60, 900), (170, 900)],
             [(.common, 0.1), (.uncommon, 0.35), (.rare, 0.55), (.uncommon, 0.8)]),
            // The weekly Legendary lives on the hard route (docs/02): one-time,
            // system-seeded, first finder gets the crown.
            ("Ridge Endurance Run", [(300, 1_500), (200, 1_500)],
             [(.common, 0.1), (.rare, 0.45), (.epic, 0.7), (.legendary, 0.78), (.uncommon, 0.9)]),
        ]
        for (name, legs, gems) in specs {
            guard let route = await Self.streetLoop(named: name, from: center,
                                                    legs: legs, gems: gems) else {
                print("[MockAPI] seeding: no walkable loop for '\(name)' here — skipped")
                continue
            }
            routes[route.id] = route
            // Plausible fake times: base pace 4:50–6:20 /km by entry order.
            competitorTimes[route.id] = Self.competitors.prefix(3).enumerated().map { i, c in
                (c.0, c.1, Int(Double(route.distanceM) / 1_000 * Double(290 + i * 45)))
            }
        }
    }

    /// A loop that starts and ends at `start`: walk out along each leg's
    /// bearing, then home — every segment MKDirections-confirmed. Returns nil
    /// when any segment can't be snapped to a real walking path.
    private static func streetLoop(named name: String, from start: Coordinate,
                                   legs: [(Double, Double)],
                                   gems: [(Rarity, Double)]) async -> Route? {
        var waypoints = [start]
        for (bearingDeg, distanceM) in legs {
            let rad = bearingDeg * .pi / 180
            waypoints.append(Self.offset(waypoints.last!,
                                         dLatM: distanceM * cos(rad),
                                         dLngM: distanceM * sin(rad)))
        }
        waypoints.append(start)                      // close the loop back home
        var coords = [start]
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let result = await PathSnapper.snapVerified(from: a, to: b)
            guard result.snapped else { return nil }
            coords.append(contentsOf: result.path.dropFirst())
        }
        let geometry = RouteGeometry(coordinates: coords)
        guard geometry.totalLengthM > 400 else { return nil }
        let difficulty: RouteDifficulty = switch Int(geometry.totalLengthM) {
        case ..<4_000: .easy
        case ..<9_000: .moderate
        default: .hard
        }
        return build(named: name, coords: coords, geometry: geometry,
                     difficulty: difficulty, gems: gems)
    }

    private static func build(named name: String, coords: [Coordinate],
                              geometry: RouteGeometry, difficulty: RouteDifficulty,
                              gems: [(Rarity, Double)]) -> Route {
        let drops = gems.map { rarity, fraction -> GemDrop in
            let alongM = geometry.totalLengthM * fraction
            let position = geometry.coordinate(atDistance: alongM)
            let respawn: RespawnRule = switch rarity {
            case .common, .uncommon: .daily
            case .rare, .epic: .oncePerUser
            case .legendary: .oneTime
            }
            return GemDrop(id: UUID(), gemID: GemCatalog.gem(of: rarity).id, rarity: rarity,
                           lat: position.lat, lng: position.lng,
                           positionAlongRouteM: Int(alongM),
                           respawnRule: respawn, placedBy: .system)
        }
        // Plausible elevation profile: a single main climb scaled to the gain
        // (real elevation arrives with the backend's terrain data, docs/08).
        let gain = Int(geometry.totalLengthM) / 100
        let profile = (0...40).map { i in
            Int(Double(gain) * (0.5 - 0.5 * cos(2 * .pi * Double(i) / 40)))
        }
        return Route(id: UUID(), name: name, polyline: PolylineCodec.encode(coords),
                     distanceM: Int(geometry.totalLengthM),
                     elevationGainM: gain,
                     difficulty: difficulty, gemDrops: drops,
                     elevationProfile: profile)
    }

    private static func offset(_ c: Coordinate, dLatM: Double, dLngM: Double) -> Coordinate {
        Coordinate(lat: c.lat + dLatM / 111_320,
                   lng: c.lng + dLngM / (111_320 * cos(c.lat * .pi / 180)))
    }
}
