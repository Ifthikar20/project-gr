import Foundation
import Observation

/// Every switchable surface in the app. Raw values are the stable storage
/// keys (and the vocabulary a future server-driven entitlement payload
/// would use) — never rename one without migrating its UserDefaults key.
public enum Feature: String, CaseIterable, Identifiable, Sendable {
    case caloriesInsights = "calories_insights"
    case routeCreation = "route_creation"
    case suggestedRoutes = "suggested_routes"
    case gemGifting = "gem_gifting"
    case friendsBoard = "friends_board"
    case shareCard = "share_card"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caloriesInsights: "Calories & steps insights"
        case .routeCreation: "Route creation"
        case .suggestedRoutes: "Suggested routes"
        case .gemGifting: "Gem gifting"
        case .friendsBoard: "Friends board"
        case .shareCard: "Share card"
        }
    }

    public var detail: String {
        switch self {
        case .caloriesInsights: "The Calories board under Compete: burn rate, steps, and the daily graph."
        case .routeCreation: "The + button on Explore and the draw-a-route flow."
        case .suggestedRoutes: "Auto-planned routes through nearby gems on the Explore carousel."
        case .gemGifting: "Placing gems from your stash on the map for others."
        case .friendsBoard: "The This Week board and player search under Compete."
        case .shareCard: "The shareable run-card image on the run summary."
        }
    }
}

/// On-device feature entitlements (docs/07's FeatureFlags, grown up a
/// little): every feature defaults ON; Settings › Features can switch any
/// of them off, and the UI they gate disappears in place. Toggles persist
/// in UserDefaults. When server-driven entitlements arrive, they land here
/// — the gating call sites (`FeatureFlags.shared.isEnabled(_:)`) stay
/// exactly as they are.
@MainActor
@Observable
public final class FeatureFlags {
    public static let shared = FeatureFlags()

    /// In-memory mirror of the persisted values so @Observable views
    /// re-render the moment a toggle flips.
    private var enabled: [Feature: Bool]

    private init() {
        var loaded: [Feature: Bool] = [:]
        for feature in Feature.allCases {
            loaded[feature] = UserDefaults.standard
                .object(forKey: Self.storageKey(feature)) as? Bool ?? true
        }
        enabled = loaded
    }

    private static func storageKey(_ feature: Feature) -> String {
        "gemrun.feature.\(feature.rawValue)"
    }

    public func isEnabled(_ feature: Feature) -> Bool {
        enabled[feature] ?? true
    }

    public func set(_ feature: Feature, enabled value: Bool) {
        enabled[feature] = value
        UserDefaults.standard.set(value, forKey: Self.storageKey(feature))
        GemLog.session.info("feature \(feature.rawValue, privacy: .public) switched \(value ? "ON" : "OFF", privacy: .public)")
    }
}
