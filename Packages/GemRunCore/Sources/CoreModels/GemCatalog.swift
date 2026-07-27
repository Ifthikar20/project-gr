import Foundation

/// Local gem catalog (docs/05 Gem/GemSet). Server-served in Phase F+; fixed
/// UUIDs keep local stash data stable across launches.
public enum GemCatalog {
    public struct Entry: Sendable {
        public let gem: Gem
        public let setName: String
        /// One-liner for the gem info card: what this material actually is.
        public var blurb: String = ""
    }

    private static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    public static let trailblazerSet = uuid(1)
    public static let harborSet = uuid(2)
    public static let cityLightsSet = uuid(3)
    public static let relicsSet = uuid(4)

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
        // Ancient Relics — organic and rock gemstone materials.
        Entry(gem: Gem(id: uuid(40), name: "Bone", rarity: .common,
                       setID: relicsSet, iconRef: "gem.bone"), setName: "Ancient Relics",
              blurb: "Polished bone — one of humanity's oldest ornament materials."),
        Entry(gem: Gem(id: uuid(41), name: "Copal", rarity: .common,
                       setID: relicsSet, iconRef: "gem.copal"), setName: "Ancient Relics",
              blurb: "Young tree resin: amber in the making, only a few thousand years old."),
        Entry(gem: Gem(id: uuid(42), name: "Sponge Coral", rarity: .common,
                       setID: relicsSet, iconRef: "gem.spongecoral"), setName: "Ancient Relics",
              blurb: "Porous coral with a sponge-like pattern in warm orange-red tones."),
        Entry(gem: Gem(id: uuid(43), name: "Mother-of-Pearl", rarity: .common,
                       setID: relicsSet, iconRef: "gem.motherofpearl"), setName: "Ancient Relics",
              blurb: "The iridescent inner shell layer built by oysters and abalone."),
        Entry(gem: Gem(id: uuid(44), name: "Amber", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.amber"), setName: "Ancient Relics",
              blurb: "Fossilized tree resin, millions of years old — sometimes holding ancient insects."),
        Entry(gem: Gem(id: uuid(45), name: "Ammonite", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.ammonite"), setName: "Ancient Relics",
              blurb: "A spiral fossil of a sea creature that swam over 66 million years ago."),
        Entry(gem: Gem(id: uuid(46), name: "Jet", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.jet"), setName: "Ancient Relics",
              blurb: "A deep-black gem formed from driftwood fossilized under pressure."),
        Entry(gem: Gem(id: uuid(47), name: "Fossil Coral", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.fossilcoral"), setName: "Ancient Relics",
              blurb: "Ancient coral turned to agate, its flower-like pattern frozen in stone."),
        Entry(gem: Gem(id: uuid(48), name: "Pearl", rarity: .rare,
                       setID: relicsSet, iconRef: "gem.pearl"), setName: "Ancient Relics",
              blurb: "The only gem grown inside a living creature, layer by layer."),
        Entry(gem: Gem(id: uuid(49), name: "Red Coral", rarity: .rare,
                       setID: relicsSet, iconRef: "gem.redcoral"), setName: "Ancient Relics",
              blurb: "Precious red coral skeleton, polished for jewelry since antiquity."),
        Entry(gem: Gem(id: uuid(50), name: "Tektite", rarity: .rare,
                       setID: relicsSet, iconRef: "gem.tektite"), setName: "Ancient Relics",
              blurb: "Natural glass forged when meteorite impacts hurled molten earth skyward."),
        Entry(gem: Gem(id: uuid(51), name: "Ammolite", rarity: .epic,
                       setID: relicsSet, iconRef: "gem.ammolite"), setName: "Ancient Relics",
              blurb: "A rainbow-iridescent gem formed from fossilized ammonite shells."),
        Entry(gem: Gem(id: uuid(52), name: "Dinosaur Bone", rarity: .epic,
                       setID: relicsSet, iconRef: "gem.dinobone"), setName: "Ancient Relics",
              blurb: "Agatized dinosaur bone — fossil bone whose cells filled with colorful quartz."),
        Entry(gem: Gem(id: uuid(53), name: "Ivory (historical)", rarity: .epic,
                       setID: relicsSet, iconRef: "gem.ivory"), setName: "Ancient Relics",
              blurb: "A gem material of the past — prized historically, protected today."),
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
