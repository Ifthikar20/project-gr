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

/// Energy + step estimates from distance alone (no body-weight profile yet;
/// docs/03's run card assumed the same model inline — this is now the single
/// source both the card and Compete › Calories use).
public enum CalorieRules {
    /// ~MET-derived kcal per kg per km at recreational paces.
    public static let runKcalPerKgKm = 1.03
    public static let walkKcalPerKgKm = 0.53
    /// Until a body-weight profile exists, everyone burns like 70 kg.
    public static let assumedBodyKg = 70.0
    /// Typical step yield when no recorded count survives for a run.
    public static let runStepsPerKm = 1_050.0
    public static let walkStepsPerKm = 1_300.0

    public static func kcal(distanceM: Int, isWalk: Bool) -> Int {
        let km = Double(distanceM) / 1_000
        return Int((km * assumedBodyKg * (isWalk ? walkKcalPerKgKm : runKcalPerKgKm)).rounded())
    }

    /// Burn rate in kcal/hour for a finished effort.
    public static func kcalPerHour(kcal: Int, durationS: Int) -> Int {
        durationS > 0 ? Int((Double(kcal) * 3_600 / Double(durationS)).rounded()) : 0
    }

    /// Distance-based step estimate for history rows that predate any
    /// recorded step count.
    public static func estimatedSteps(distanceM: Int, isWalk: Bool) -> Int {
        let km = Double(distanceM) / 1_000
        return Int((km * (isWalk ? walkStepsPerKm : runStepsPerKm)).rounded())
    }

    /// Cadence in steps per minute.
    public static func cadence(steps: Int, durationS: Int) -> Int {
        durationS > 0 ? Int((Double(steps) * 60 / Double(durationS)).rounded()) : 0
    }
}
