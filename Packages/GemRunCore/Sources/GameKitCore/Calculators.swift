import CoreModels
import Foundation

/// Economy math from docs/02. Implemented now (it's tiny and the rest of the
/// scaffold exercises it); the server re-implements identically.
public enum XPRules {
    public static func base(for rarity: Rarity) -> Int {
        switch rarity {
        case .common: 10
        case .uncommon: 25
        case .rare: 75
        case .epic: 200
        case .legendary: 500
        }
    }

    public static let setCompletionBonus = 500
    public static let walkMultiplier = 0.5

    /// XP required to advance FROM the given level.
    public static func xpToAdvance(from level: Int) -> Int { 100 * level }
}

public enum StreakRules {
    public static let minValidRunDistanceM = 1_000
    public static let maxShields = 2
    public static let shieldEarnedEveryDays = 7

    /// 1.0×, +0.1 per 7 consecutive days, capped at 1.5×.
    public static func multiplier(streakDays: Int) -> Double {
        min(1.5, 1.0 + 0.1 * Double(max(0, streakDays) / 7))
    }
}

/// Creator placement budget (docs/02): slots + rarity points + spacing.
public enum PlacementBudget {
    public static let metersPerSlot = 250
    public static let minGemSpacingM = 100
    public static let rareMinRouteFraction = 0.4

    public static func slots(forDistanceM distanceM: Int) -> Int {
        distanceM / metersPerSlot
    }

    /// budget = distance_km × 10
    public static func points(forDistanceM distanceM: Int) -> Int {
        distanceM / 100
    }

    /// nil = not placeable by creators (Legendary is system-seeded only).
    public static func cost(of rarity: Rarity) -> Int? {
        switch rarity {
        case .common: 1
        case .uncommon: 3
        case .rare: 10
        case .epic: 25
        case .legendary: nil
        }
    }
}
