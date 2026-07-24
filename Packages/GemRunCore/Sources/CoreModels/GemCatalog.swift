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
    public static let cityLightsSet = uuid(3)

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
        Entry(gem: Gem(id: uuid(30), name: "Streetlight Quartz", rarity: .common,
                       setID: cityLightsSet, iconRef: "gem.quartz"), setName: "City Lights"),
        Entry(gem: Gem(id: uuid(31), name: "Neon Ruby", rarity: .uncommon,
                       setID: cityLightsSet, iconRef: "gem.ruby"), setName: "City Lights"),
        Entry(gem: Gem(id: uuid(32), name: "Skyline Topaz", rarity: .rare,
                       setID: cityLightsSet, iconRef: "gem.topaz"), setName: "City Lights"),
        Entry(gem: Gem(id: uuid(33), name: "Midnight Amethyst", rarity: .epic,
                       setID: cityLightsSet, iconRef: "gem.amethyst"), setName: "City Lights"),
    ]

    public static func entry(forGemID id: UUID) -> Entry? {
        entries.first { $0.gem.id == id }
    }

    /// Any catalog gem of the given rarity (used when placing drops).
    public static func gem(of rarity: Rarity) -> Gem {
        entries.first { $0.gem.rarity == rarity }!.gem
    }

    /// A random gem of the given rarity — used by placement so we don't drop
    /// the same emerald every time when multiple gems share a rarity.
    public static func randomGem(of rarity: Rarity) -> Gem {
        let choices = entries.filter { $0.gem.rarity == rarity }.map(\.gem)
        return choices.randomElement() ?? gem(of: rarity)
    }
}
