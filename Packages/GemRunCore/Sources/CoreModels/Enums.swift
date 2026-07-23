import Foundation

public enum Rarity: String, Codable, CaseIterable, Sendable {
    case common, uncommon, rare, epic, legendary
}

public enum RespawnRule: String, Codable, Sendable {
    case daily, oncePerUser = "once_per_user", oneTime = "one_time"
}

public enum GemPlacer: String, Codable, Sendable {
    case creator, system
}

public enum RouteDifficulty: String, Codable, Sendable {
    case easy, moderate, hard
}

public enum RouteStatus: String, Codable, Sendable {
    case draft, published, archived
}

public enum RunValidationStatus: String, Codable, Sendable {
    case pending, valid, flagged, invalid
}

public enum AuthProvider: String, Codable, Sendable {
    case apple, google, guest
}

/// Auth rollout switches.
public enum AuthFlags {
    /// TEMPORARY (dev): accept every sign-in — Apple/Google failures and guest
    /// logins all produce a working local account, and no identity token is
    /// verified. Flip to false when the Django backend verifies tokens
    /// (docs/06 auth exchange); unverified sign-ins are then rejected.
    public static let allowAllAccounts = true
}
