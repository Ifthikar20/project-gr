import Foundation

/// Local gem catalog (docs/05 Gem/GemSet). Server-served in Phase F+; fixed
/// UUIDs keep local stash data stable across launches.
public enum GemCatalog {
    public struct Entry: Sendable {
        public let gem: Gem
        public let setName: String
        /// Real, short facts about the material — the gem info card cycles
        /// through them so the popup isn't the same line every time. Facts
        /// describe the real-world gem behind the name (a "Neon Ruby" gets
        /// ruby facts). Never empty for catalog entries.
        public var facts: [String] = []
        /// Lead fact — the legacy one-liner surface (run-card back).
        public var blurb: String { facts.first ?? "" }
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
                       setID: trailblazerSet, iconRef: "gem.quartz"), setName: "Trailblazer",
              facts: [
                "Quartz is one of the most common minerals in Earth's crust — most beach sand is tiny quartz grains.",
                "Quartz crystals vibrate at an exact frequency under voltage — that's how quartz watches keep time.",
                "Ancient Greeks called clear quartz \"krystallos,\" believing it was ice frozen too hard to ever melt.",
              ]),
        Entry(gem: Gem(id: uuid(11), name: "Moss Emerald", rarity: .uncommon,
                       setID: trailblazerSet, iconRef: "gem.emerald"), setName: "Trailblazer",
              facts: [
                "Emerald is the green form of the mineral beryl, tinted by traces of chromium or vanadium.",
                "Most emeralds hold tiny internal gardens of inclusions — jewelers call them the \"jardin.\"",
                "Egypt mined emeralds over 2,000 years ago; Cleopatra famously claimed the mines as her own.",
              ]),
        Entry(gem: Gem(id: uuid(12), name: "Ridge Sapphire", rarity: .rare,
                       setID: trailblazerSet, iconRef: "gem.sapphire"), setName: "Trailblazer",
              facts: [
                "Sapphire is corundum — after diamond, one of the hardest natural gem materials on Earth.",
                "Sapphires come in every color except red: a red corundum is called a ruby instead.",
                "Star sapphires shine with a six-rayed star, drawn by needle-thin inclusions inside the stone.",
              ]),
        Entry(gem: Gem(id: uuid(13), name: "Summit Amethyst", rarity: .epic,
                       setID: trailblazerSet, iconRef: "gem.amethyst"), setName: "Trailblazer",
              facts: [
                "Amethyst is quartz turned violet by traces of iron and natural radiation underground.",
                "The Greeks named it \"amethystos\" — \"not drunk\" — believing it protected against intoxication.",
                "Brazilian geodes can hide amethyst crystal caves taller than a person.",
              ]),
        Entry(gem: Gem(id: uuid(14), name: "First Light Ember", rarity: .legendary,
                       setID: trailblazerSet, iconRef: "gem.ember"), setName: "Trailblazer",
              facts: [
                "Its real-world cousin is fire opal — a Mexican gem that glows orange like a caught flame.",
                "Opal never forms crystals: it's hardened silica gel, and can hold up to a tenth of its weight in water.",
                "Aztec fire opals were treasured centuries before Europeans ever saw one.",
              ]),
        Entry(gem: Gem(id: uuid(20), name: "Harbor Quartz", rarity: .common,
                       setID: harborSet, iconRef: "gem.quartz"), setName: "Harbor Lights",
              facts: [
                "Quartz rates 7 on the Mohs hardness scale — hard enough to scratch window glass.",
                "Pure quartz is colorless; stray atoms tint it purple, pink, smoky, or golden.",
                "Early radios relied on quartz crystals to hold their broadcast frequency steady.",
              ]),
        Entry(gem: Gem(id: uuid(21), name: "Tide Emerald", rarity: .uncommon,
                       setID: harborSet, iconRef: "gem.emerald"), setName: "Harbor Lights",
              facts: [
                "Colombia produces more fine emeralds than anywhere else on Earth.",
                "Emeralds have been gently oiled to improve clarity for centuries — an accepted jeweler's practice.",
                "Aquamarine is emerald's sibling: the very same beryl mineral, colored ocean blue.",
              ]),
        Entry(gem: Gem(id: uuid(22), name: "Deepwater Sapphire", rarity: .rare,
                       setID: harborSet, iconRef: "gem.sapphire"), setName: "Harbor Lights",
              facts: [
                "Many scratchproof watch faces are synthetic sapphire — the same crystal as the gem.",
                "Kashmir's \"cornflower blue\" sapphires are among the most valuable gems ever auctioned.",
                "The padparadscha, a rare pink-orange sapphire, is named after the lotus blossom.",
              ]),
        Entry(gem: Gem(id: uuid(30), name: "Streetlight Quartz", rarity: .common,
                       setID: cityLightsSet, iconRef: "gem.quartz"), setName: "City Lights",
              facts: [
                "Quartz is piezoelectric: squeeze it and it makes a tiny voltage — tap it and it can spark.",
                "Amethyst and citrine are both just quartz wearing different trace elements.",
                "Some of the world's largest natural crystals ever found are quartz.",
              ]),
        Entry(gem: Gem(id: uuid(31), name: "Neon Ruby", rarity: .uncommon,
                       setID: cityLightsSet, iconRef: "gem.ruby"), setName: "City Lights",
              facts: [
                "Ruby is corundum made red by chromium — the same element that turns emeralds green.",
                "Fine rubies can sell for more per carat than diamonds.",
                "The first working laser, built in 1960, had a synthetic ruby crystal at its heart.",
              ]),
        Entry(gem: Gem(id: uuid(32), name: "Skyline Topaz", rarity: .rare,
                       setID: cityLightsSet, iconRef: "gem.topaz"), setName: "City Lights",
              facts: [
                "Topaz grows some of the largest gem crystals on Earth — museum pieces weigh kilograms.",
                "Pure topaz is colorless; the rare imperial topaz glows orange-pink.",
                "Most blue topaz in shops started out colorless — its color comes from careful irradiation.",
              ]),
        Entry(gem: Gem(id: uuid(33), name: "Midnight Amethyst", rarity: .epic,
                       setID: cityLightsSet, iconRef: "gem.amethyst"), setName: "City Lights",
              facts: [
                "Amethyst was once as precious as ruby — until huge Brazilian finds made it plentiful.",
                "Heat an amethyst and it turns golden: much commercial citrine begins life purple.",
                "Amethyst is February's birthstone.",
              ]),
        // Ancient Relics — organic and rock gemstone materials.
        Entry(gem: Gem(id: uuid(40), name: "Bone", rarity: .common,
                       setID: relicsSet, iconRef: "gem.bone"), setName: "Ancient Relics",
              facts: [
                "Polished bone — one of humanity's oldest ornament materials.",
                "Ice Age people carved bone into beads, needles, and even flutes tens of thousands of years ago.",
                "Under a lens, worked bone shows the tiny channels that once carried blood.",
              ]),
        Entry(gem: Gem(id: uuid(41), name: "Copal", rarity: .common,
                       setID: relicsSet, iconRef: "gem.copal"), setName: "Ancient Relics",
              facts: [
                "Young tree resin: amber in the making, only a few thousand years old.",
                "Copal is still burned as incense in Mexico and Central America — a Maya and Aztec tradition.",
                "Jewelers tell copal from amber with a solvent drop: it softens young copal, not true amber.",
              ]),
        Entry(gem: Gem(id: uuid(42), name: "Sponge Coral", rarity: .common,
                       setID: relicsSet, iconRef: "gem.spongecoral"), setName: "Ancient Relics",
              facts: [
                "Porous coral with a sponge-like pattern in warm orange-red tones.",
                "Corals are animals, not plants — colonies of tiny polyps building limestone homes.",
                "Polishing reveals its lacy web of channels, no two pieces alike.",
              ]),
        Entry(gem: Gem(id: uuid(43), name: "Mother-of-Pearl", rarity: .common,
                       setID: relicsSet, iconRef: "gem.motherofpearl"), setName: "Ancient Relics",
              facts: [
                "The iridescent inner shell layer built by oysters and abalone.",
                "Its shimmer is light bending through thousands of stacked mineral layers thinner than hair.",
                "Buttons, watch dials, and inlaid guitars have shown off mother-of-pearl for centuries.",
              ]),
        Entry(gem: Gem(id: uuid(44), name: "Amber", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.amber"), setName: "Ancient Relics",
              facts: [
                "Fossilized tree resin, millions of years old — sometimes holding ancient insects.",
                "Rubbed amber crackles with static — the Greek word for it, \"elektron,\" gave us \"electricity.\"",
                "Baltic amber washes ashore after storms; traders once carried it across Europe on \"Amber Roads.\"",
              ]),
        Entry(gem: Gem(id: uuid(45), name: "Ammonite", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.ammonite"), setName: "Ancient Relics",
              facts: [
                "A spiral fossil of a sea creature that swam over 66 million years ago.",
                "Ammonites grew their shells in near-perfect logarithmic spirals.",
                "They vanished in the same extinction that ended the dinosaurs.",
              ]),
        Entry(gem: Gem(id: uuid(46), name: "Jet", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.jet"), setName: "Ancient Relics",
              facts: [
                "A deep-black gem formed from driftwood fossilized under pressure.",
                "Whitby jet from England became famous as Queen Victoria's mourning jewelry.",
                "Jet is warm to the touch and so light it was once nicknamed \"black amber.\"",
              ]),
        Entry(gem: Gem(id: uuid(47), name: "Fossil Coral", rarity: .uncommon,
                       setID: relicsSet, iconRef: "gem.fossilcoral"), setName: "Ancient Relics",
              facts: [
                "Ancient coral turned to agate, its flower-like pattern frozen in stone.",
                "Each tiny \"bloom\" in the stone is one coral polyp's fossilized home.",
                "Over millions of years, silica replaced the living coral almost cell by cell.",
              ]),
        Entry(gem: Gem(id: uuid(48), name: "Pearl", rarity: .rare,
                       setID: relicsSet, iconRef: "gem.pearl"), setName: "Ancient Relics",
              facts: [
                "The only gem grown inside a living creature, layer by layer.",
                "A pearl begins as an irritant that the mollusk wraps in thousands of layers of nacre.",
                "Natural pearls are so rare that divers once opened thousands of oysters to find a single one.",
              ]),
        Entry(gem: Gem(id: uuid(49), name: "Red Coral", rarity: .rare,
                       setID: relicsSet, iconRef: "gem.redcoral"), setName: "Ancient Relics",
              facts: [
                "Precious red coral skeleton, polished for jewelry since antiquity.",
                "Mediterranean red coral grows only a few millimeters a year.",
                "Romans hung red coral charms on children for protection.",
              ]),
        Entry(gem: Gem(id: uuid(50), name: "Tektite", rarity: .rare,
                       setID: relicsSet, iconRef: "gem.tektite"), setName: "Ancient Relics",
              facts: [
                "Natural glass forged when meteorite impacts hurled molten earth skyward.",
                "Many tektites are aerodynamically shaped — they hardened while flying through the air.",
                "Moldavite, a green tektite from the Czech Republic, formed in an impact about 15 million years ago.",
              ]),
        Entry(gem: Gem(id: uuid(51), name: "Ammolite", rarity: .epic,
                       setID: relicsSet, iconRef: "gem.ammolite"), setName: "Ancient Relics",
              facts: [
                "A rainbow-iridescent gem formed from fossilized ammonite shells.",
                "Nearly all gem-grade ammolite comes from one place: southern Alberta, Canada.",
                "It was only recognized as an official gemstone in 1981 — one of the youngest gems there is.",
              ]),
        Entry(gem: Gem(id: uuid(52), name: "Dinosaur Bone", rarity: .epic,
                       setID: relicsSet, iconRef: "gem.dinobone"), setName: "Ancient Relics",
              facts: [
                "Agatized dinosaur bone — fossil bone whose cells filled with colorful quartz.",
                "Minerals replaced the original bone over tens of millions of years.",
                "Polished slices show the honeycomb of real bone cells, preserved in stone.",
              ]),
        Entry(gem: Gem(id: uuid(53), name: "Ivory (historical)", rarity: .epic,
                       setID: relicsSet, iconRef: "gem.ivory"), setName: "Ancient Relics",
              facts: [
                "A gem material of the past — prized historically, protected today.",
                "Piano keys and billiard balls were once ivory; early plastics were invented partly to replace it.",
                "International ivory trade is banned — antique pieces now live on in museums.",
              ]),
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
