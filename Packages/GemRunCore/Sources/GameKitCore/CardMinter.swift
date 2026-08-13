import CoreModels
import Foundation

/// The published pull odds — the numbers on the landing page's rarity
/// ladder, and the single source the minter, the docs, and any future
/// server implementation share.
public enum MintOdds {
    public static let legendary = 1.0 / 900
    public static let epic = 1.0 / 60
    public static let rare = 1.0 / 12
    public static let uncommon = 1.0 / 4
    public static var common: Double { 1 - legendary - epic - rare - uncommon }

    static func roll(_ u: Double) -> Rarity {
        if u < legendary { return .legendary }
        if u < legendary + epic { return .epic }
        if u < legendary + epic + rare { return .rare }
        if u < legendary + epic + rare + uncommon { return .uncommon }
        return .common
    }
}

/// Turns a completed mile into a Runner Card: seeded rarity roll at
/// the published odds, uniform type roll, uniform face pick within the
/// combo, and the walk's stats stamped on. Pure — the same seed always
/// mints the same card, which is what makes the odds testable.
public enum CardMinter {
    public static func mint(seed: UInt64, zone: RunnerZone, at date: Date,
                            serial: Int, stats: MintStats,
                            catalog: [RunnerCardCatalog.Entry]
                                = RunnerCardCatalog.entries) -> RunnerCard {
        var rng = SplitMix64(seed: seed)
        let u = Double(rng.next() >> 11) / Double(1 << 53)
        let rarity = MintOdds.roll(u)
        let type = CardType.allCases[Int(rng.next() % UInt64(CardType.allCases.count))]
        let face = pick(type: type, rarity: rarity, from: catalog, rng: &rng)
        var stamped = stats
        stamped.xpEarned = face?.xp ?? 10
        return RunnerCard(
            id: rng.nextUUID(),
            cardID: face?.cardID ?? UUID(uuid: UUID_NULL),
            name: face?.name ?? "Blank Card",
            type: face?.type ?? type,
            rarity: face?.rarity ?? rarity,
            zoneID: zone.id, zoneName: zone.name,
            mintedAt: date, serial: serial, stats: stamped)
    }

    /// A face for the rolled combo; an empty combo degrades to the nearest
    /// lower rarity in-type (the catalog test makes this unreachable for
    /// the shipped catalog), then to anything at all.
    static func pick(type: CardType, rarity: Rarity,
                     from catalog: [RunnerCardCatalog.Entry],
                     rng: inout SplitMix64) -> RunnerCardCatalog.Entry? {
        var current: Rarity? = rarity
        while let r = current {
            let pool = catalog.filter { $0.type == type && $0.rarity == r }
            if !pool.isEmpty {
                return pool[Int(rng.next() % UInt64(pool.count))]
            }
            current = lower(r)
        }
        return catalog.first
    }

    static func lower(_ rarity: Rarity) -> Rarity? {
        switch rarity {
        case .legendary: .epic
        case .epic: .rare
        case .rare: .uncommon
        case .uncommon: .common
        case .common: nil
        }
    }
}
