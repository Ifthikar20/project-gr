import XCTest
@testable import GameKitCore
import CoreModels

/// The card catalog's structural promises: full 5 × 5 coverage (the minter
/// picks uniformly within a combo, so an empty combo would be a trap),
/// stable unique UUIDs disjoint from the gem catalog the backend mirrors,
/// and resolvable gem references.
final class RunnerCardCatalogTests: XCTestCase {
    func testEveryTypeRarityComboHasAFace() {
        for type in CardType.allCases {
            for rarity in Rarity.allCases {
                XCTAssertFalse(
                    RunnerCardCatalog.entries(type: type, rarity: rarity).isEmpty,
                    "no card face for \(type.rawValue) × \(rarity.rawValue)")
            }
        }
    }

    func testCardIDsAreUnique() {
        let ids = RunnerCardCatalog.entries.map(\.cardID)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate cardIDs in catalog")
    }

    func testCardIDsNeverCollideWithGemCatalog() {
        let gemIDs = Set(GemCatalog.entries.map(\.gem.id))
            .union([GemCatalog.trailblazerSet, GemCatalog.harborSet,
                    GemCatalog.cityLightsSet, GemCatalog.relicsSet])
        for entry in RunnerCardCatalog.entries {
            XCTAssertFalse(gemIDs.contains(entry.cardID),
                           "\(entry.name) reuses a gem/set UUID as its cardID")
        }
    }

    func testGemReferencesResolve() {
        for entry in RunnerCardCatalog.entries {
            guard let gemID = entry.gemID else { continue }
            XCTAssertNotNil(GemCatalog.entry(forGemID: gemID),
                            "\(entry.name) references a gem missing from GemCatalog")
        }
    }

    func testEveryCatalogGemHasACardFace() {
        let referenced = Set(RunnerCardCatalog.entries.compactMap(\.gemID))
        for entry in GemCatalog.entries {
            XCTAssertTrue(referenced.contains(entry.gem.id),
                          "\(entry.gem.name) never appears as a gem-type card face")
        }
    }

    func testRunnerCardRoundTripsThroughJSON() throws {
        let card = RunnerCard(
            id: UUID(), cardID: RunnerCardCatalog.entries[0].cardID,
            name: "Harbor Sapphire", type: .gem, rarity: .legendary,
            zoneID: UUID(), zoneName: "Harbor Loop",
            mintedAt: Date(timeIntervalSince1970: 1_755_000_000),
            serial: 142,
            stats: MintStats(distanceM: 1_000, steps: 1_380, xpEarned: 240,
                             paceSPerKm: 324, mintedDuringRun: true))
        let data = try JSONEncoder().encode(card)
        let back = try JSONDecoder().decode(RunnerCard.self, from: data)
        XCTAssertEqual(card, back)
    }
}
