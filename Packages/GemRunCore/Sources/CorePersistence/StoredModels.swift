import CoreModels
import Foundation
import SwiftData

// SwiftData mirror of the docs/05 client subset. Complex values (gem drops,
// tracks) are stored as JSON blobs — simple, migration-friendly, and they're
// only ever read whole.

@Model
public final class StoredRoute {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var routeDescription: String?
    public var polyline: String
    public var distanceM: Int
    public var elevationGainM: Int
    public var difficultyRaw: String
    public var statusRaw: String
    public var creatorHandle: String?
    public var runCount: Int
    public var gemDropsData: Data
    public var elevationProfileData: Data?
    public var createdAt: Date

    public init(route: Route) {
        self.id = route.id
        self.name = route.name
        self.routeDescription = route.description
        self.polyline = route.polyline
        self.distanceM = route.distanceM
        self.elevationGainM = route.elevationGainM
        self.difficultyRaw = route.difficulty.rawValue
        self.statusRaw = route.status.rawValue
        self.creatorHandle = route.creatorHandle
        self.runCount = route.runCount
        // A silent encode failure here is the "cached route has no gems"
        // failure mode — log it at the moment it happens, not when the
        // empty map is discovered later.
        self.gemDropsData = GemLog.attempt(GemLog.persist, "encode cached route gems", {
            try JSONEncoder().encode(route.gemDrops)
        }) ?? Data()
        self.elevationProfileData = route.elevationProfile.flatMap { profile in
            GemLog.attempt(GemLog.persist, "encode elevation profile") {
                try JSONEncoder().encode(profile)
            }
        }
        self.createdAt = Date()
    }

    public var gemDrops: [GemDrop] {
        GemLog.attempt(GemLog.persist, "decode cached route gems", {
            try JSONDecoder().decode([GemDrop].self, from: gemDropsData)
        }) ?? []
    }

    public func toRoute() -> Route {
        Route(id: id, name: name, description: routeDescription, polyline: polyline,
              distanceM: distanceM, elevationGainM: elevationGainM,
              difficulty: RouteDifficulty(rawValue: difficultyRaw) ?? .moderate,
              status: RouteStatus(rawValue: statusRaw) ?? .published,
              creatorHandle: creatorHandle, runCount: runCount, gemDrops: gemDrops,
              elevationProfile: elevationProfileData.flatMap { data in
                  GemLog.attempt(GemLog.persist, "decode elevation profile") {
                      try JSONDecoder().decode([Int].self, from: data)
                  }
              })
    }
}

@Model
public final class StoredRun {
    @Attribute(.unique) public var id: UUID
    public var routeID: UUID
    public var routeName: String
    public var startedAt: Date
    public var durationS: Int
    public var distanceM: Int
    public var paceSPerKm: Int
    public var isWalk: Bool
    public var statusRaw: String
    public var xpEarned: Int
    public var gemsCollected: Int
    /// Encoded polyline of the runner's actual GPS track — used to validate
    /// gem drops ("only on trails you've run"). Optional so old runs migrate.
    public var trackPolyline: String?

    public init(id: UUID, routeID: UUID, routeName: String, startedAt: Date,
                durationS: Int, distanceM: Int, paceSPerKm: Int, isWalk: Bool,
                statusRaw: String, xpEarned: Int, gemsCollected: Int,
                trackPolyline: String? = nil) {
        self.id = id
        self.routeID = routeID
        self.routeName = routeName
        self.startedAt = startedAt
        self.durationS = durationS
        self.distanceM = distanceM
        self.paceSPerKm = paceSPerKm
        self.isWalk = isWalk
        self.statusRaw = statusRaw
        self.xpEarned = xpEarned
        self.gemsCollected = gemsCollected
        self.trackPolyline = trackPolyline
    }
}

@Model
public final class StoredStashItem {
    @Attribute(.unique) public var id: UUID
    public var gemID: UUID
    /// Which placement was collected — drives client-side respawn hints.
    public var gemDropID: UUID?
    public var gemName: String
    public var rarityRaw: String
    public var setName: String
    public var routeID: UUID
    public var routeName: String
    public var collectedAt: Date
    public var isFirstFind: Bool
    /// Given away as a map drop: still shown in the collection, no longer
    /// offered by the drop sheet.
    public var isDropped: Bool = false

    public init(id: UUID, gemID: UUID, gemDropID: UUID? = nil, gemName: String,
                rarityRaw: String, setName: String, routeID: UUID, routeName: String,
                collectedAt: Date, isFirstFind: Bool, isDropped: Bool = false) {
        self.id = id
        self.gemID = gemID
        self.gemDropID = gemDropID
        self.gemName = gemName
        self.rarityRaw = rarityRaw
        self.setName = setName
        self.routeID = routeID
        self.routeName = routeName
        self.collectedAt = collectedAt
        self.isFirstFind = isFirstFind
        self.isDropped = isDropped
    }

    public var rarity: Rarity { Rarity(rawValue: rarityRaw) ?? .common }
}

@Model
public final class StoredRunnerCard {
    @Attribute(.unique) public var id: UUID
    public var cardID: UUID
    public var name: String
    public var typeRaw: String
    public var rarityRaw: String
    public var zoneID: UUID
    public var zoneName: String
    public var mintedAt: Date
    public var serial: Int
    /// MintStats as a JSON blob — the StoredRoute pattern for values the
    /// binder never queries by.
    public var statsData: Data

    public init(from card: RunnerCard) {
        self.id = card.id
        self.cardID = card.cardID
        self.name = card.name
        self.typeRaw = card.type.rawValue
        self.rarityRaw = card.rarity.rawValue
        self.zoneID = card.zoneID
        self.zoneName = card.zoneName
        self.mintedAt = card.mintedAt
        self.serial = card.serial
        self.statsData = (try? JSONEncoder().encode(card.stats)) ?? Data()
    }

    public var rarity: Rarity { Rarity(rawValue: rarityRaw) ?? .common }
    public var type: CardType { CardType(rawValue: typeRaw) ?? .gem }
    public var stats: MintStats {
        (try? JSONDecoder().decode(MintStats.self, from: statsData))
            ?? MintStats(distanceM: 0, steps: 0, xpEarned: 0)
    }

    public func toRunnerCard() -> RunnerCard {
        RunnerCard(id: id, cardID: cardID, name: name, type: type,
                   rarity: rarity, zoneID: zoneID, zoneName: zoneName,
                   mintedAt: mintedAt, serial: serial, stats: stats)
    }
}

@Model
public final class StoredProfile {
    @Attribute(.unique) public var id: UUID
    public var handle: String
    public var xp: Int
    public var level: Int
    public var streakCount: Int
    public var streakShields: Int
    public var streakLastDate: Date?
    /// Set names whose completion bonus was already awarded (docs/02).
    public var completedSetsRaw: String = ""
    public var authProviderRaw: String = "guest"
    /// Stable ID from the provider (Apple `user`, Google `sub`); nil for guests.
    public var externalUserID: String?

    public init(handle: String, authProviderRaw: String = "guest",
                externalUserID: String? = nil) {
        self.id = UUID()
        self.handle = handle
        self.xp = 0
        self.level = 1
        self.streakCount = 0
        self.streakShields = 0
        self.streakLastDate = nil
        self.completedSetsRaw = ""
        self.authProviderRaw = authProviderRaw
        self.externalUserID = externalUserID
    }

    public var completedSets: Set<String> {
        get { Set(completedSetsRaw.split(separator: "|").map(String.init)) }
        set { completedSetsRaw = newValue.sorted().joined(separator: "|") }
    }
}

public enum Persistence {
    public static let models: [any PersistentModel.Type] = [
        StoredRoute.self, StoredRun.self, StoredStashItem.self, StoredProfile.self,
        StoredRunnerCard.self,
    ]
}
