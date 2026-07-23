import Foundation

// Client-side domain types mirroring the canonical model in docs/05.

public struct UserProfile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var handle: String
    public var avatarURL: URL?
    public var xp: Int
    public var level: Int
    public var streakCount: Int
    public var streakShields: Int

    public init(id: UUID, handle: String, avatarURL: URL? = nil,
                xp: Int = 0, level: Int = 1, streakCount: Int = 0, streakShields: Int = 0) {
        self.id = id
        self.handle = handle
        self.avatarURL = avatarURL
        self.xp = xp
        self.level = level
        self.streakCount = streakCount
        self.streakShields = streakShields
    }
}

public struct Route: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var description: String?
    /// Encoded polyline (Google format) of the snapped path.
    public var polyline: String
    public var distanceM: Int
    public var elevationGainM: Int
    public var difficulty: RouteDifficulty
    public var status: RouteStatus
    public var creatorHandle: String?
    public var runCount: Int
    public var gemDrops: [GemDrop]
    /// Sampled elevations (m) evenly spaced start→finish; nil when unknown.
    public var elevationProfile: [Int]?

    public init(id: UUID, name: String, description: String? = nil, polyline: String,
                distanceM: Int, elevationGainM: Int, difficulty: RouteDifficulty,
                status: RouteStatus = .published, creatorHandle: String? = nil,
                runCount: Int = 0, gemDrops: [GemDrop] = [],
                elevationProfile: [Int]? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.polyline = polyline
        self.distanceM = distanceM
        self.elevationGainM = elevationGainM
        self.difficulty = difficulty
        self.status = status
        self.creatorHandle = creatorHandle
        self.runCount = runCount
        self.gemDrops = gemDrops
        self.elevationProfile = elevationProfile
    }
}

public struct Gem: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var rarity: Rarity
    public var setID: UUID
    public var iconRef: String

    public init(id: UUID, name: String, rarity: Rarity, setID: UUID, iconRef: String) {
        self.id = id
        self.name = name
        self.rarity = rarity
        self.setID = setID
        self.iconRef = iconRef
    }
}

public struct GemSet: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var badgeRef: String

    public init(id: UUID, name: String, badgeRef: String) {
        self.id = id
        self.name = name
        self.badgeRef = badgeRef
    }
}

/// A gem placed at a point on a route. Rare+ drops may carry a fuzzed zone
/// instead of exact coordinates until collected (docs/06).
public struct GemDrop: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var gemID: UUID
    public var rarity: Rarity
    public var lat: Double
    public var lng: Double
    /// Distance from route start; drives collection ordering (docs/04).
    public var positionAlongRouteM: Int
    public var respawnRule: RespawnRule
    public var placedBy: GemPlacer
    /// Non-nil when coordinates are fuzzed: radius of the hint zone.
    public var fuzzRadiusM: Int?

    public init(id: UUID, gemID: UUID, rarity: Rarity, lat: Double, lng: Double,
                positionAlongRouteM: Int, respawnRule: RespawnRule,
                placedBy: GemPlacer = .creator, fuzzRadiusM: Int? = nil) {
        self.id = id
        self.gemID = gemID
        self.rarity = rarity
        self.lat = lat
        self.lng = lng
        self.positionAlongRouteM = positionAlongRouteM
        self.respawnRule = respawnRule
        self.placedBy = placedBy
        self.fuzzRadiusM = fuzzRadiusM
    }
}

/// One accepted GPS sample in a run's track (docs/04).
public struct TrackSample: Codable, Sendable {
    public let t: TimeInterval
    public let lat: Double
    public let lng: Double
    public let horizontalAccuracy: Double
    public let speed: Double

    public init(t: TimeInterval, lat: Double, lng: Double, horizontalAccuracy: Double, speed: Double) {
        self.t = t
        self.lat = lat
        self.lng = lng
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
    }
}

public struct Run: Codable, Identifiable, Sendable {
    public let id: UUID
    public let routeID: UUID
    public let idempotencyKey: String
    public var startedAt: Date
    public var durationS: Int
    public var distanceM: Int
    public var claimedCollections: [UUID]
    public var validationStatus: RunValidationStatus
    public var xpEarned: Int

    public init(id: UUID, routeID: UUID, idempotencyKey: String, startedAt: Date,
                durationS: Int = 0, distanceM: Int = 0, claimedCollections: [UUID] = [],
                validationStatus: RunValidationStatus = .pending, xpEarned: Int = 0) {
        self.id = id
        self.routeID = routeID
        self.idempotencyKey = idempotencyKey
        self.startedAt = startedAt
        self.durationS = durationS
        self.distanceM = distanceM
        self.claimedCollections = claimedCollections
        self.validationStatus = validationStatus
        self.xpEarned = xpEarned
    }
}

public struct StashItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let gemID: UUID
    public let gemDropID: UUID
    public let runID: UUID
    public let collectedAt: Date
    public let isFirstFind: Bool

    public init(id: UUID, gemID: UUID, gemDropID: UUID, runID: UUID,
                collectedAt: Date, isFirstFind: Bool = false) {
        self.id = id
        self.gemID = gemID
        self.gemDropID = gemDropID
        self.runID = runID
        self.collectedAt = collectedAt
        self.isFirstFind = isFirstFind
    }
}

public struct LeaderboardEntry: Codable, Sendable {
    public let rank: Int
    public let handle: String
    public let level: Int
    public let bestTimeS: Int
    public let isMe: Bool

    public init(rank: Int, handle: String, level: Int, bestTimeS: Int, isMe: Bool = false) {
        self.rank = rank
        self.handle = handle
        self.level = level
        self.bestTimeS = bestTimeS
        self.isMe = isMe
    }
}
