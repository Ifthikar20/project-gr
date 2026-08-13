import Foundation

/// The card faces a mint can produce (landing-page set, verbatim where the
/// page names them). Fixed UUIDs keep binder data stable across launches,
/// exactly like GemCatalog — and in a disjoint numeric range (100+) so a
/// card face can never collide with a gem or set id the backend mirrors.
/// Server-served later; the minter only ever reads `entries`.
public enum RunnerCardCatalog {
    public struct Entry: Identifiable, Sendable {
        public let cardID: UUID
        public let name: String
        public let type: CardType
        public let rarity: Rarity
        public let xp: Int
        /// Evolution-style pill on the card top ("Stage 2").
        public let stage: Int
        public let abilityName: String
        public let abilityValue: String
        public let abilityText: String
        /// Habitat telemetry — "found most" row.
        public let foundMostWhere: String
        public let foundMostPct: Int
        public let flavor: String
        /// Footer drop condition ("1 in 900 runs", "after a PB").
        public let dropNote: String
        public let printRun: Int
        /// Asset name for the art slot; gem faces reuse gem art.
        public let artRef: String?
        /// Set for gem-type faces backed by a GemCatalog gem — a reference,
        /// never a reuse of the gem's UUID as cardID.
        public let gemID: UUID?

        public var id: UUID { cardID }

        public init(cardID: UUID, name: String, type: CardType, rarity: Rarity,
                    xp: Int, stage: Int, abilityName: String, abilityValue: String,
                    abilityText: String, foundMostWhere: String, foundMostPct: Int,
                    flavor: String, dropNote: String, printRun: Int = 500,
                    artRef: String? = nil, gemID: UUID? = nil) {
            self.cardID = cardID
            self.name = name
            self.type = type
            self.rarity = rarity
            self.xp = xp
            self.stage = stage
            self.abilityName = abilityName
            self.abilityValue = abilityValue
            self.abilityText = abilityText
            self.foundMostWhere = foundMostWhere
            self.foundMostPct = foundMostPct
            self.flavor = flavor
            self.dropNote = dropNote
            self.printRun = printRun
            self.artRef = artRef
            self.gemID = gemID
        }
    }

    private static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    // MARK: - Named faces (the landing page's 13, then the fillers that
    // complete every type × rarity combination — the minter requires each
    // combo to be non-empty, and a test enforces it).

    static let named: [Entry] = [
        // The five gallery cards.
        Entry(cardID: uuid(100), name: "Harbor Sapphire", type: .gem,
              rarity: .legendary, xp: 240, stage: 2,
              abilityName: "Shard Rush", abilityValue: "2×",
              abilityText: "Play before a run — every zone XP pickup counts double for the next 24 hours.",
              foundMostWhere: "Waterfront zones", foundMostPct: 78,
              flavor: "Cut from harbor light. A stone this clear surfaces about once a season — almost always at dawn.",
              dropNote: "1 in 900 runs", artRef: "gem.sapphire",
              gemID: GemCatalog.entries.first { $0.gem.name == "Deepwater Sapphire" }?.gem.id),
        Entry(cardID: uuid(101), name: "Golden Shoes", type: .gear,
              rarity: .legendary, xp: 300, stage: 3,
              abilityName: "Winged Pace", abilityValue: "−0:15",
              abilityText: "Trims 15 s/km off your pace target and doubles streak credit.",
              foundMostWhere: "Stadium & track", foundMostPct: 8,
              flavor: "Laced by whoever outran their best. They only fit on days you mean it.",
              dropNote: "after a PB"),
        Entry(cardID: uuid(102), name: "Harbor Fox", type: .creature,
              rarity: .rare, xp: 90, stage: 1,
              abilityName: "Trail Guide", abilityValue: "+1",
              abilityText: "Reveals one hidden zone on every dawn run.",
              foundMostWhere: "Park & greenway", foundMostPct: 41,
              flavor: "Keeps to the hedge line at first light. Follows runners it approves of.",
              dropNote: "dawn runs"),
        Entry(cardID: uuid(103), name: "The Unmarked Obelisk", type: .artifact,
              rarity: .epic, xp: 160, stage: 3,
              abilityName: "First Sighting", abilityValue: "+5%",
              abilityText: "Your handle is engraved on the first find — and +5% XP on every run after.",
              foundMostWhere: "Old quarry", foundMostPct: 12,
              flavor: "No plaque, no record, no reason to be there. And yet.",
              dropNote: "one known copy"),
        Entry(cardID: uuid(104), name: "Runner's High", type: .fact,
              rarity: .rare, xp: 60, stage: 1,
              abilityName: "Deck Piece", abilityValue: "4 / 12",
              abilityText: "Complete all 12 fact cards to earn the set badge.",
              foundMostWhere: "Riverside", foundMostPct: 64,
              flavor: "About thirty minutes in, the brain pays you back in its own currency.",
              dropNote: "morning runs"),

        // The binder wall minis.
        Entry(cardID: uuid(105), name: "Trail Boots", type: .gear,
              rarity: .common, xp: 20, stage: 1,
              abilityName: "Broken In", abilityValue: "+1",
              abilityText: "Adds one bonus XP per kilometre walked today.",
              foundMostWhere: "Park & greenway", foundMostPct: 66,
              flavor: "Mud outside, miles inside.",
              dropNote: "most walks"),
        Entry(cardID: uuid(106), name: "Night Heron", type: .creature,
              rarity: .epic, xp: 180, stage: 2,
              abilityName: "Still Water", abilityValue: "+20%",
              abilityText: "Night-zone distance counts 20% faster while it's in your collection.",
              foundMostWhere: "Riverside", foundMostPct: 22,
              flavor: "Stands where the streetlight meets the water. Never blinks first.",
              dropNote: "after dark"),
        Entry(cardID: uuid(107), name: "Rose Quartz", type: .gem,
              rarity: .uncommon, xp: 40, stage: 1,
              abilityName: "Facet Focus", abilityValue: "+10%",
              abilityText: "Zone distance counts 10% faster for the rest of the day.",
              foundMostWhere: "Park & greenway", foundMostPct: 47,
              flavor: "The soft pink of a sky you only see from the trail.",
              dropNote: "1 in 4 runs", artRef: "gem.quartz"),
        Entry(cardID: uuid(108), name: "Ghost Koi", type: .creature,
              rarity: .legendary, xp: 260, stage: 3,
              abilityName: "Undercurrent", abilityValue: "2×",
              abilityText: "Doubles zone XP on rainy-day walks.",
              foundMostWhere: "Waterfront zones", foundMostPct: 6,
              flavor: "Seen twice, photographed never. The pond keeps its own ledger.",
              dropNote: "1 in 900 runs"),
        Entry(cardID: uuid(109), name: "Storm Shell", type: .gear,
              rarity: .rare, xp: 70, stage: 2,
              abilityName: "Weatherproof", abilityValue: "+15%",
              abilityText: "Rain and wind days credit 15% more zone distance.",
              foundMostWhere: "City streets", foundMostPct: 33,
              flavor: "Built for the forecast everyone else cancels on.",
              dropNote: "rainy runs"),
        Entry(cardID: uuid(110), name: "Second Wind", type: .fact,
              rarity: .uncommon, xp: 35, stage: 1,
              abilityName: "Deck Piece", abilityValue: "7 / 12",
              abilityText: "Complete all 12 fact cards to earn the set badge.",
              foundMostWhere: "Stadium & track", foundMostPct: 51,
              flavor: "The second wind is real; the trick is running slow enough to meet it.",
              dropNote: "long runs"),
        Entry(cardID: uuid(111), name: "Old Tram Token", type: .artifact,
              rarity: .epic, xp: 150, stage: 2,
              abilityName: "Fare Paid", abilityValue: "+5%",
              abilityText: "City-zone XP up 5% while it's in your collection.",
              foundMostWhere: "Old town", foundMostPct: 18,
              flavor: "Good for one ride on a line that stopped running in 1968.",
              dropNote: "1 in 60 runs"),
        Entry(cardID: uuid(112), name: "City Sparrow", type: .creature,
              rarity: .common, xp: 15, stage: 1,
              abilityName: "Commuter", abilityValue: "+1",
              abilityText: "One bonus XP for every zone entered today.",
              foundMostWhere: "City streets", foundMostPct: 71,
              flavor: "Owns the block. Rents it out to pigeons.",
              dropNote: "most walks"),

        // Fillers to complete the 5 × 5 grid, written in the wall's register.
        Entry(cardID: uuid(113), name: "Dawn Visor", type: .gear,
              rarity: .uncommon, xp: 40, stage: 1,
              abilityName: "Sunrise Start", abilityValue: "+10%",
              abilityText: "Zone distance before 8 am counts 10% faster.",
              foundMostWhere: "Riverside", foundMostPct: 38,
              flavor: "The brim that turns a squint into a stride.",
              dropNote: "1 in 4 runs"),
        Entry(cardID: uuid(114), name: "Aurora Windbreaker", type: .gear,
              rarity: .epic, xp: 160, stage: 2,
              abilityName: "Tailwind", abilityValue: "+20%",
              abilityText: "Every third kilometre today credits 20% extra.",
              foundMostWhere: "Stadium & track", foundMostPct: 14,
              flavor: "Sewn from the kind of morning you tell people about.",
              dropNote: "1 in 60 runs"),
        Entry(cardID: uuid(115), name: "Towpath Otter", type: .creature,
              rarity: .uncommon, xp: 40, stage: 1,
              abilityName: "Slipstream", abilityValue: "+10%",
              abilityText: "Waterside zones credit 10% more distance.",
              foundMostWhere: "Riverside", foundMostPct: 44,
              flavor: "Swims the towpath faster than you run it. Doesn't gloat much.",
              dropNote: "1 in 4 runs"),
        Entry(cardID: uuid(116), name: "Bottle Cap, 1971", type: .artifact,
              rarity: .common, xp: 15, stage: 1,
              abilityName: "Pocket Luck", abilityValue: "+1",
              abilityText: "One bonus XP on your next mint.",
              foundMostWhere: "Old town", foundMostPct: 59,
              flavor: "A soda brand nobody remembers, pressed flat by fifty years of feet.",
              dropNote: "most walks"),
        Entry(cardID: uuid(117), name: "Faded Mile Marker", type: .artifact,
              rarity: .uncommon, xp: 35, stage: 1,
              abilityName: "Waymark", abilityValue: "+5%",
              abilityText: "Zone progress shows 5% early — the map rounds in your favor.",
              foundMostWhere: "Park & greenway", foundMostPct: 42,
              flavor: "MILE 3 — or 8. The paint gave up before the road did.",
              dropNote: "1 in 4 runs"),
        Entry(cardID: uuid(118), name: "Brass Compass Rose", type: .artifact,
              rarity: .rare, xp: 80, stage: 2,
              abilityName: "True North", abilityValue: "+1",
              abilityText: "Reveals one extra zone tomorrow morning.",
              foundMostWhere: "Waterfront zones", foundMostPct: 27,
              flavor: "Points north. Pointed north before this city had streets.",
              dropNote: "1 in 12 runs"),
        Entry(cardID: uuid(119), name: "The First Bib", type: .artifact,
              rarity: .legendary, xp: 260, stage: 3,
              abilityName: "Number One", abilityValue: "+10%",
              abilityText: "Your handle joins the founders' list; +10% XP forever.",
              foundMostWhere: "Stadium & track", foundMostPct: 3,
              flavor: "Race number 001, safety pins still bent the way she left them.",
              dropNote: "one known copy"),
        Entry(cardID: uuid(120), name: "Left, Right, Repeat", type: .fact,
              rarity: .common, xp: 15, stage: 1,
              abilityName: "Deck Piece", abilityValue: "1 / 12",
              abilityText: "Complete all 12 fact cards to earn the set badge.",
              foundMostWhere: "Park & greenway", foundMostPct: 74,
              flavor: "A marathon is the world's most honest to-do list: one step, about forty-two thousand times.",
              dropNote: "most walks"),
        Entry(cardID: uuid(121), name: "The Wall at 30K", type: .fact,
              rarity: .epic, xp: 150, stage: 2,
              abilityName: "Deck Piece", abilityValue: "11 / 12",
              abilityText: "Complete all 12 fact cards to earn the set badge.",
              foundMostWhere: "Stadium & track", foundMostPct: 9,
              flavor: "Glycogen runs out near kilometre thirty; everything after runs on stubbornness.",
              dropNote: "1 in 60 runs"),
        Entry(cardID: uuid(122), name: "The First Marathon", type: .fact,
              rarity: .legendary, xp: 240, stage: 3,
              abilityName: "Deck Piece", abilityValue: "12 / 12",
              abilityText: "Complete all 12 fact cards to earn the set badge.",
              foundMostWhere: "Old town", foundMostPct: 4,
              flavor: "Pheidippides ran from Marathon to Athens, delivered the news, and set a distance we've argued with ever since.",
              dropNote: "1 in 900 runs"),
    ]

    // MARK: - Gem faces derived from the gem catalog

    /// Every catalog gem becomes a gem-type card face: same name and art,
    /// its lead fact as the flavor line, and a cardID derived from the
    /// gem's own last UUID byte shifted into the card range (150+) so the
    /// mapping survives any reordering of either catalog.
    static let gemFaces: [Entry] = GemCatalog.entries.map { entry in
        let gem = entry.gem
        let byte = gem.id.uuid.15
        return Entry(cardID: uuid(150 &+ byte), name: gem.name, type: .gem,
                     rarity: gem.rarity,
                     xp: baseXP(for: gem.rarity),
                     stage: stage(for: gem.rarity),
                     abilityName: gemAbility(for: gem.rarity).0,
                     abilityValue: gemAbility(for: gem.rarity).1,
                     abilityText: gemAbility(for: gem.rarity).2,
                     foundMostWhere: habitat(forSet: entry.setName).0,
                     foundMostPct: habitat(forSet: entry.setName).1,
                     flavor: entry.facts.first ?? "",
                     dropNote: dropNote(for: gem.rarity),
                     artRef: gem.iconRef, gemID: gem.id)
    }

    public static let entries: [Entry] = named + gemFaces

    // MARK: - Lookups

    public static func entry(forCardID id: UUID) -> Entry? {
        entries.first { $0.cardID == id }
    }

    public static func entries(type: CardType, rarity: Rarity) -> [Entry] {
        entries.filter { $0.type == type && $0.rarity == rarity }
    }

    // MARK: - Derivation tables

    static func baseXP(for rarity: Rarity) -> Int {
        switch rarity {
        case .common: 15
        case .uncommon: 35
        case .rare: 80
        case .epic: 160
        case .legendary: 260
        }
    }

    static func stage(for rarity: Rarity) -> Int {
        switch rarity {
        case .common, .uncommon: 1
        case .rare, .epic: 2
        case .legendary: 3
        }
    }

    private static func gemAbility(for rarity: Rarity) -> (String, String, String) {
        switch rarity {
        case .common:
            ("Glimmer", "+5", "Adds 5 bonus XP to the zone walk that minted it.")
        case .uncommon:
            ("Facet Focus", "+10%", "Zone distance counts 10% faster for the rest of the day.")
        case .rare:
            ("Deep Cut", "+15%", "Raises zone XP pickups 15% until midnight.")
        case .epic:
            ("Geode Bloom", "2×", "Doubles the next mint's XP if it lands in the same zone.")
        case .legendary:
            ("Shard Rush", "2×", "Play before a run — every zone XP pickup counts double for the next 24 hours.")
        }
    }

    private static func habitat(forSet setName: String) -> (String, Int) {
        switch setName {
        case "Trailblazer": ("Park & greenway", 52)
        case "Harbor Lights": ("Waterfront zones", 64)
        case "City Lights": ("City streets", 58)
        case "Ancient Relics": ("Old town", 37)
        default: ("Park & greenway", 50)
        }
    }

    private static func dropNote(for rarity: Rarity) -> String {
        switch rarity {
        case .common: "most walks"
        case .uncommon: "1 in 4 runs"
        case .rare: "1 in 12 runs"
        case .epic: "1 in 60 runs"
        case .legendary: "1 in 900 runs"
        }
    }
}
