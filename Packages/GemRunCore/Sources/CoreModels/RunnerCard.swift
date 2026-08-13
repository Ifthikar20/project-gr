import Foundation

/// The five kinds of collectible a Runner Card can hold — the landing
/// page's vocabulary, verbatim. A separate enum on purpose: `Rarity` is
/// shared with gems and the wire formats, so cards bring their own axis
/// instead of growing that one.
public enum CardType: String, Codable, CaseIterable, Identifiable, Sendable {
    case gem, gear, creature, artifact, fact

    public var id: String { rawValue }

    /// Display noun, capitalized the way the card band prints it
    /// ("Legendary Gem · Harbor Loop zone").
    public var displayName: String { rawValue.capitalized }
}

/// The walk that earned a card, stamped onto it at mint time.
public struct MintStats: Codable, Equatable, Sendable {
    /// Metres credited inside the zone for this mint.
    public var distanceM: Int
    /// Steps counted during the session (0 when unavailable, e.g. map-only).
    public var steps: Int
    public var xpEarned: Int
    /// Average pace where a run provided one; nil for map-open walking.
    public var paceSPerKm: Int?
    public var mintedDuringRun: Bool

    public init(distanceM: Int, steps: Int, xpEarned: Int,
                paceSPerKm: Int? = nil, mintedDuringRun: Bool = false) {
        self.distanceM = distanceM
        self.steps = steps
        self.xpEarned = xpEarned
        self.paceSPerKm = paceSPerKm
        self.mintedDuringRun = mintedDuringRun
    }
}

/// One minted Runner Card: a catalog face (`cardID`) stamped with the zone,
/// the date, and the mile that earned it. Client-only for now — when
/// the API takes over minting, this type gains snake_case CodingKeys the
/// way the gem DTOs did, not before.
public struct RunnerCard: Codable, Identifiable, Equatable, Sendable {
    /// This mint. Every mint is its own card, even of the same face.
    public let id: UUID
    /// The catalog face this card shows (RunnerCardCatalog).
    public let cardID: UUID
    public let name: String
    public let type: CardType
    public let rarity: Rarity
    public let zoneID: UUID
    public let zoneName: String
    public let mintedAt: Date
    /// The nth card minted on this device — the "142 / 500" numerator.
    public let serial: Int
    public let stats: MintStats

    public init(id: UUID, cardID: UUID, name: String, type: CardType,
                rarity: Rarity, zoneID: UUID, zoneName: String,
                mintedAt: Date, serial: Int, stats: MintStats) {
        self.id = id
        self.cardID = cardID
        self.name = name
        self.type = type
        self.rarity = rarity
        self.zoneID = zoneID
        self.zoneName = zoneName
        self.mintedAt = mintedAt
        self.serial = serial
        self.stats = stats
    }
}
