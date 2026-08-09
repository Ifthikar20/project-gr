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
    /// Off: the client no longer advertises a permissive dev mode, matching
    /// the server's strict default (apple/google sign-ins are verified against
    /// the provider identity token; guests use a stable per-install secret).
    /// Every real sign-in path supplies an external id, so the local
    /// sign-in guard is satisfied without this. (docs/06 auth exchange.)
    public static let allowAllAccounts = false
}
