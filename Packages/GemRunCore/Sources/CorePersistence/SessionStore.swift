import CoreModels
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
    public let xpEarned: Int
    public let streakCount: Int
    public let streakExtended: Bool
    public let multiplier: Double
    public let isWalk: Bool
    public let status: RunValidationStatus
    public let durationS: Int
    public let distanceM: Int
    public let paceSPerKm: Int
    public let leaderboardRank: Int?
}

/// App-wide session (docs/07): profile + optimistic XP/streak state, and the
/// two cross-tab presentation triggers (active run, creation flow).
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

    private var context: ModelContext?

    public init() {
        self.isOnboarded = UserDefaults.standard.bool(forKey: "gemrun.onboarded")
    }

    public func attach(context: ModelContext) {
        self.context = context
        profile = try? context.fetch(FetchDescriptor<StoredProfile>()).first
    }

    public func createProfile(handle: String) {
        guard let context else { return }
        let p = StoredProfile(handle: handle.isEmpty ? "runner" : handle)
        context.insert(p)
        try? context.save()
        profile = p
    }

    public var streakMultiplier: Double {
        StreakRules.multiplier(streakDays: profile?.streakCount ?? 0)
    }

    /// Persist a finished run: streak math, XP award, stash inserts, run row,
    /// route runCount, local leaderboard rank. Local-first — in Phase F the
    /// server verdict replaces this as the authority (docs/06).
    public func recordCompletion(_ result: RunResult) -> RunCompletionSummary {
        let v = result.validation
        let streakExtended = updateStreak(distanceM: v.distanceM, isValid: v.status != .invalid)
        let xp = v.status == .invalid ? 0
            : RunValidator.xp(for: result.collectedDrops, isWalk: v.isWalk,
                              streakDays: profile?.streakCount ?? 0)

        let gems: [RunCompletionSummary.CollectedGem] = result.collectedDrops.map { drop in
            let entry = GemCatalog.entry(forGemID: drop.gemID)
            return .init(id: drop.id, name: entry?.gem.name ?? "Gem", rarity: drop.rarity)
        }

        var rank: Int?
        if let context {
            if v.status != .invalid {
                for drop in result.collectedDrops {
                    let entry = GemCatalog.entry(forGemID: drop.gemID)
                    context.insert(StoredStashItem(
                        id: UUID(), gemID: drop.gemID,
                        gemName: entry?.gem.name ?? "Gem",
                        rarityRaw: drop.rarity.rawValue,
                        setName: entry?.setName ?? "Wanderer",
                        routeID: result.route.id, routeName: result.route.name,
                        collectedAt: Date(), isFirstFind: false))
                }
                profile?.xp += xp
                while let p = profile, p.xp >= XPRules.xpToAdvance(from: p.level) {
                    p.xp -= XPRules.xpToAdvance(from: p.level)
                    p.level += 1
                }
            }
            context.insert(StoredRun(
                id: UUID(), routeID: result.route.id, routeName: result.route.name,
                startedAt: result.startedAt, durationS: v.durationS, distanceM: v.distanceM,
                paceSPerKm: v.paceSPerKm, isWalk: v.isWalk, statusRaw: v.status.rawValue,
                xpEarned: xp, gemsCollected: gems.count))

            let routeID = result.route.id
            if let stored = try? context.fetch(FetchDescriptor<StoredRoute>(
                predicate: #Predicate { $0.id == routeID })).first {
                stored.runCount += 1
            }
            // Local best-time rank among valid, run-pace runs on this route.
            if v.status == .valid, !v.isWalk {
                let runs = (try? context.fetch(FetchDescriptor<StoredRun>(
                    predicate: #Predicate { $0.routeID == routeID }))) ?? []
                let faster = runs.filter {
                    $0.statusRaw == RunValidationStatus.valid.rawValue
                        && !$0.isWalk && $0.durationS < v.durationS
                }
                rank = faster.count + 1
            }
            try? context.save()
        }

        return RunCompletionSummary(
            gems: gems, xpEarned: xp,
            streakCount: profile?.streakCount ?? 0, streakExtended: streakExtended,
            multiplier: streakMultiplier, isWalk: v.isWalk, status: v.status,
            durationS: v.durationS, distanceM: v.distanceM, paceSPerKm: v.paceSPerKm,
            leaderboardRank: rank)
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
        // Earn a shield per completed 7-day block, capped (docs/02).
        if profile.streakCount % StreakRules.shieldEarnedEveryDays == 0 {
            profile.streakShields = min(StreakRules.maxShields, profile.streakShields + 1)
        }
        profile.streakLastDate = Date()
        return true
    }
}
