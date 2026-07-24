import CoreModels
import CoreNetworking
import Foundation
import GameKitCore
import Observation
import SwiftData

/// Everything a finished run produced, for the summary screen.
public struct RunCompletionSummary: Sendable {
    public struct CollectedGem: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let rarity: Rarity
    }

    public let gems: [CollectedGem]
    public let revokedCount: Int
    public let xpEarned: Int
    public let setBonusXP: Int
    public let completedSetName: String?
    public let streakCount: Int
    public let streakExtended: Bool
    public let multiplier: Double
    public let isWalk: Bool
    public let status: RunValidationStatus
    public let startedAt: Date
    public let durationS: Int
    public let distanceM: Int
    public let paceSPerKm: Int
    public let splitsS: [Int]
    public let leaderboardRank: Int?
    public let routeName: String
}

/// App-wide session (docs/07): profile + optimistic XP/streak state, the two
/// cross-tab presentation triggers, and the API hand-off on run completion.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var profile: StoredProfile?
    /// Stored (not computed) so @Observable notifies RootView when it flips.
    public var isOnboarded: Bool {
        didSet { UserDefaults.standard.set(isOnboarded, forKey: "gemrun.onboarded") }
    }

    /// Setting this presents the Active Run full-screen cover at App root.
    public var activeRoute: Route?
    /// Setting this presents the Route Creation flow at App root.
    public var isCreatingRoute = false
    /// Set by the gemrun://route/{id} deep-link handler; Explore consumes it.
    public var pendingDeepLinkRouteID: UUID?

    // MARK: Gem wallet + free runs (earn-by-running)

    /// Gems available to drop — minted from Apple Health distance; starts at 0.
    public private(set) var wallet: GemWallet = [:]
    /// Presents the free-run cover (collect standalone drops, no route).
    public var isFreeRunning = false
    public var freeRunDrops: [GemDrop] = []

    /// Reads lifetime run km from Health and mints via the API.
    public func refreshWallet() async {
        let km = await HealthDistance.totalRunKm()
        if let minted = try? await API.shared.syncWallet(totalRunKm: km) {
            wallet = minted
        }
    }

    /// Optimistic local decrement after a successful dropGem call.
    public func spend(_ rarity: Rarity) {
        if let count = wallet[rarity], count > 0 {
            wallet[rarity] = count - 1
        }
    }

    public func startFreeRun(drops: [GemDrop]) {
        freeRunDrops = drops
        isFreeRunning = true
    }

    /// Submit a finished free run; persist only what the server awarded.
    public func recordFreeCompletion(track: [TrackSample], collected: [GemDrop],
                                     durationS: Int, distanceM: Int) async -> RunCompletionSummary {
        let result = try? await API.shared.collectDrops(claimed: collected.map(\.id),
                                                        track: track)
        let awarded = result?.awardedDrops ?? []
        let xp = result?.xpEarned ?? 0
        if let context {
            for drop in awarded {
                let entry = GemCatalog.entry(forGemID: drop.gemID)
                context.insert(StoredStashItem(
                    id: UUID(), gemID: drop.gemID, gemDropID: drop.id,
                    gemName: entry?.gem.name ?? "Gem",
                    rarityRaw: drop.rarity.rawValue,
                    setName: entry?.setName ?? "Wanderer",
                    routeID: drop.id, routeName: "Found on a free run",
                    collectedAt: Date(), isFirstFind: true))
            }
            profile?.xp += xp
            while let p = profile, p.xp >= XPRules.xpToAdvance(from: p.level) {
                p.xp -= XPRules.xpToAdvance(from: p.level)
                p.level += 1
            }
            try? context.save()
        }
        let pace = distanceM > 50 ? Int(Double(durationS) / (Double(distanceM) / 1_000)) : 0
        return RunCompletionSummary(
            gems: awarded.map {
                let entry = GemCatalog.entry(forGemID: $0.gemID)
                return .init(id: $0.id, name: entry?.gem.name ?? "Gem", rarity: $0.rarity)
            },
            revokedCount: collected.count - awarded.count,
            xpEarned: xp, setBonusXP: 0, completedSetName: nil,
            streakCount: profile?.streakCount ?? 0, streakExtended: false,
            multiplier: 1.0, isWalk: false, status: .valid,
            startedAt: Date().addingTimeInterval(-TimeInterval(durationS)),
            durationS: durationS, distanceM: distanceM, paceSPerKm: pace,
            splitsS: [], leaderboardRank: nil, routeName: "Free run")
    }

    private var context: ModelContext?

    public init() {
        self.isOnboarded = UserDefaults.standard.bool(forKey: "gemrun.onboarded")
        // Starter gems so a fresh user can drop from Explore immediately —
        // the API resyncs on Stash open, but this avoids an empty-wallet
        // moment on first launch.
        self.wallet = [.common: 5, .uncommon: 3, .rare: 1]
    }

    public func attach(context: ModelContext) {
        self.context = context
        profile = try? context.fetch(FetchDescriptor<StoredProfile>()).first
        Task { await refreshWallet() }
    }

    public func createProfile(handle: String) {
        signIn(provider: .guest, handle: handle, externalID: nil)
    }

    /// Sign-in entry for every provider. While `AuthFlags.allowAllAccounts` is
    /// on (TEMPORARY), any attempt succeeds — including provider failures and
    /// guests. Once Django verifies tokens, unverified sign-ins are rejected.
    @discardableResult
    public func signIn(provider: AuthProvider, handle: String,
                       externalID: String?) -> Bool {
        guard AuthFlags.allowAllAccounts || externalID != nil else { return false }
        guard let context else { return false }
        let cleanHandle = handle.trimmingCharacters(in: .whitespaces)
        if let profile {
            profile.authProviderRaw = provider.rawValue
            profile.externalUserID = externalID
            if !cleanHandle.isEmpty { profile.handle = cleanHandle }
        } else {
            let p = StoredProfile(handle: cleanHandle.isEmpty ? "runner" : cleanHandle,
                                  authProviderRaw: provider.rawValue,
                                  externalUserID: externalID)
            context.insert(p)
            profile = p
        }
        try? context.save()
        isOnboarded = true
        // Register with the API (mock today; Django exchanges the identity
        // token for a JWT here, docs/06) — POST /v1/auth/apple | /google.
        if let handle = profile?.handle {
            Task { _ = try? await API.shared.auth(handle: handle) }
        }
        return true
    }

    /// Keeps local data; just returns the user to onboarding.
    public func signOut() {
        isOnboarded = false
    }

    public var authProvider: AuthProvider {
        AuthProvider(rawValue: profile?.authProviderRaw ?? "guest") ?? .guest
    }

    public var streakMultiplier: Double {
        StreakRules.multiplier(streakDays: profile?.streakCount ?? 0)
    }

    /// Client-side respawn hint (docs/02): the route with drops the user can't
    /// collect right now removed — daily ones collected today, Rare+ ever.
    /// The server verdict remains authoritative; this just avoids celebrating
    /// gems that would be revoked.
    public func collectableRoute(from route: Route) -> Route {
        guard let context else { return route }
        let stash = (try? context.fetch(FetchDescriptor<StoredStashItem>())) ?? []
        let today = Calendar.current.startOfDay(for: Date())
        var filtered = route
        filtered.gemDrops = route.gemDrops.filter { drop in
            let matches = stash.filter { $0.gemDropID == drop.id }
            switch drop.respawnRule {
            case .daily:
                return !matches.contains { $0.collectedAt >= today }
            case .oncePerUser, .oneTime:
                return matches.isEmpty
            }
        }
        return filtered
    }

    /// Submit the finished run to the API and persist from its verdict — the
    /// server is authoritative and may revoke optimistic collections (docs/06).
    /// Falls back to on-device validation if the API is unreachable.
    public func recordCompletion(_ result: RunResult) async -> RunCompletionSummary {
        let v = result.validation
        let streakExtended = updateStreak(distanceM: v.distanceM, isValid: v.status != .invalid)

        let request = RunCompletionRequest(
            idempotencyKey: UUID().uuidString,
            startedAt: result.startedAt,
            endedAt: result.startedAt.addingTimeInterval(TimeInterval(v.durationS)),
            track: result.track,
            claimedCollections: result.collectedDrops.map(\.id),
            clientFlags: v.flags,
            clientStreakDays: profile?.streakCount ?? 0)

        // POST /v1/runs/{id}/complete — the authoritative verdict.
        let verdict = try? await API.shared.completeRun(routeID: result.route.id,
                                                        request: request)

        let status = verdict?.status ?? v.status
        let awardedDrops = verdict?.awardedDrops
            ?? (status == .invalid ? [] : result.collectedDrops)
        let xp = verdict?.xpEarned ?? (status == .invalid ? 0
            : RunValidator.xp(for: awardedDrops, isWalk: v.isWalk,
                              streakDays: profile?.streakCount ?? 0))
        let revokedCount = verdict.map(\.revoked.count)
            ?? (result.collectedDrops.count - awardedDrops.count)

        let gems: [RunCompletionSummary.CollectedGem] = awardedDrops.map { drop in
            let entry = GemCatalog.entry(forGemID: drop.gemID)
            return .init(id: drop.id, name: entry?.gem.name ?? "Gem", rarity: drop.rarity)
        }

        let completedSet = persist(result: result, status: status,
                                   awardedDrops: awardedDrops, xp: xp)
        let setBonus = completedSet != nil ? XPRules.setCompletionBonus : 0

        return RunCompletionSummary(
            gems: gems, revokedCount: revokedCount, xpEarned: xp + setBonus,
            setBonusXP: setBonus, completedSetName: completedSet,
            streakCount: profile?.streakCount ?? 0, streakExtended: streakExtended,
            multiplier: streakMultiplier, isWalk: v.isWalk, status: status,
            startedAt: result.startedAt, durationS: v.durationS, distanceM: v.distanceM,
            paceSPerKm: v.paceSPerKm, splitsS: v.splitsS,
            leaderboardRank: verdict?.leaderboardRank ?? nil,
            routeName: result.route.name)
    }

    /// Returns the name of a set completed by this run, if any (bonus already
    /// applied to the profile).
    private func persist(result: RunResult, status: RunValidationStatus,
                         awardedDrops: [GemDrop], xp: Int) -> String? {
        guard let context else { return nil }
        let v = result.validation
        var completedSet: String?
        if status != .invalid {
            for drop in awardedDrops {
                let entry = GemCatalog.entry(forGemID: drop.gemID)
                context.insert(StoredStashItem(
                    id: UUID(), gemID: drop.gemID, gemDropID: drop.id,
                    gemName: entry?.gem.name ?? "Gem",
                    rarityRaw: drop.rarity.rawValue,
                    setName: entry?.setName ?? "Wanderer",
                    routeID: result.route.id, routeName: result.route.name,
                    collectedAt: Date(),
                    isFirstFind: drop.rarity == .legendary))
            }
            var totalXP = xp
            // Set-completion bonus (docs/02): all gems of a set now collected,
            // bonus not yet awarded → +500 XP + badge (Stash shows completion).
            if let profile {
                let stash = (try? context.fetch(FetchDescriptor<StoredStashItem>())) ?? []
                let owned = Set(stash.map(\.gemID))
                for (setName, entries) in Dictionary(grouping: GemCatalog.entries,
                                                     by: \.setName) {
                    guard !profile.completedSets.contains(setName),
                          entries.allSatisfy({ owned.contains($0.gem.id) }) else { continue }
                    profile.completedSets.insert(setName)
                    completedSet = setName
                    totalXP += XPRules.setCompletionBonus
                    break
                }
            }
            profile?.xp += totalXP
            while let p = profile, p.xp >= XPRules.xpToAdvance(from: p.level) {
                p.xp -= XPRules.xpToAdvance(from: p.level)
                p.level += 1
            }
        }
        context.insert(StoredRun(
            id: UUID(), routeID: result.route.id, routeName: result.route.name,
            startedAt: result.startedAt, durationS: v.durationS, distanceM: v.distanceM,
            paceSPerKm: v.paceSPerKm, isWalk: v.isWalk, statusRaw: status.rawValue,
            xpEarned: xp, gemsCollected: awardedDrops.count))

        let routeID = result.route.id
        if let stored = try? context.fetch(FetchDescriptor<StoredRoute>(
            predicate: #Predicate { $0.id == routeID })).first {
            stored.runCount += 1
        }
        try? context.save()
        return completedSet
    }

    /// Calendar-day streak with shields (docs/02). Returns true if extended today.
    private func updateStreak(distanceM: Int, isValid: Bool) -> Bool {
        guard let profile, isValid, distanceM >= StreakRules.minValidRunDistanceM else { return false }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if let last = profile.streakLastDate {
            let lastDay = cal.startOfDay(for: last)
            let gap = cal.dateComponents([.day], from: lastDay, to: today).day ?? 0
            switch gap {
            case 0:
                return false                       // already ran today
            case 1:
                profile.streakCount += 1
            default:
                let missed = gap - 1
                if profile.streakShields >= missed {
                    profile.streakShields -= missed // shields absorb the gap
                    profile.streakCount += 1
                } else {
                    profile.streakCount = 1        // streak broken, start over
                }
            }
        } else {
            profile.streakCount = 1
        }
        if profile.streakCount % StreakRules.shieldEarnedEveryDays == 0 {
            profile.streakShields = min(StreakRules.maxShields, profile.streakShields + 1)
        }
        profile.streakLastDate = Date()
        return true
    }
}
