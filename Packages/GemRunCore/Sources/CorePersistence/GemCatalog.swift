import CoreModels
import Foundation

/// Local gem catalog (docs/05 Gem/GemSet). Server-served in Phase F+; fixed
/// UUIDs keep local stash data stable across launches.
public enum GemCatalog {
    public struct Entry: Sendable {
        public let gem: Gem
        public let setName: String
    }

    private static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    public static let trailblazerSet = uuid(1)
    public static let harborSet = uuid(2)

    public static let entries: [Entry] = [
        Entry(gem: Gem(id: uuid(10), name: "Trail Quartz", rarity: .common,
                       setID: trailblazerSet, iconRef: "gem.quartz"), setName: "Trailblazer"),
        Entry(gem: Gem(id: uuid(11), name: "Moss Emerald", rarity: .uncommon,
                       setID: trailblazerSet, iconRef: "gem.emerald"), setName: "Trailblazer"),
        Entry(gem: Gem(id: uuid(12), name: "Ridge Sapphire", rarity: .rare,
                       setID: trailblazerSet, iconRef: "gem.sapphire"), setName: "Trailblazer"),
        Entry(gem: Gem(id: uuid(13), name: "Summit Amethyst", rarity: .epic,
                       setID: trailblazerSet, iconRef: "gem.amethyst"), setName: "Trailblazer"),
        Entry(gem: Gem(id: uuid(14), name: "First Light Ember", rarity: .legendary,
                       setID: trailblazerSet, iconRef: "gem.ember"), setName: "Trailblazer"),
        Entry(gem: Gem(id: uuid(20), name: "Harbor Quartz", rarity: .common,
                       setID: harborSet, iconRef: "gem.quartz"), setName: "Harbor Lights"),
        Entry(gem: Gem(id: uuid(21), name: "Tide Emerald", rarity: .uncommon,
                       setID: harborSet, iconRef: "gem.emerald"), setName: "Harbor Lights"),
        Entry(gem: Gem(id: uuid(22), name: "Deepwater Sapphire", rarity: .rare,
                       setID: harborSet, iconRef: "gem.sapphire"), setName: "Harbor Lights"),
    ]

    public static func entry(forGemID id: UUID) -> Entry? {
        entries.first { $0.gem.id == id }
    }

    /// Any catalog gem of the given rarity (used when placing drops).
    public static func gem(of rarity: Rarity) -> Gem {
        entries.first { $0.gem.rarity == rarity }!.gem
    }
}
