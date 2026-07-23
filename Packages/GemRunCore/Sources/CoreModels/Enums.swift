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
