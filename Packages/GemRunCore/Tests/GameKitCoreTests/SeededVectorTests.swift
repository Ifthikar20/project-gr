import XCTest
@testable import GameKitCore
import CoreModels

/// Cross-language pins: the SAME literals live in the Django suite's
/// SeededVectorTests (backend/api/tests.py). The server replays mints and
/// derives zone ids with a Python port of SplitMix64/StableSeed/CardMinter —
/// if either side drifts from its twin, one of the two suites goes red.
/// Never update one side alone.
final class SeededVectorTests: XCTestCase {
    func testSplitMix64Stream() {
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 16_294_208_416_658_607_535 as UInt64)
        XCTAssertEqual(rng.next(), 7_960_286_522_194_355_700 as UInt64)
        XCTAssertEqual(rng.next(), 487_617_019_471_545_679 as UInt64)
        var second = SplitMix64(seed: 12_345)
        XCTAssertEqual(second.next(), 2_454_886_589_211_414_944 as UInt64)
    }

    func testUnitDoubleDerivation() {
        // The u = next() >> 11 / 2^53 fold both minters roll rarity with.
        var rng = SplitMix64(seed: 0xDEAD_BEEF)
        XCTAssertEqual(Double(rng.next() >> 11) / Double(1 << 53),
                       0.29247624040798537, accuracy: 1e-16)
    }

    func testNextUUIDByteOrder() {
        var rng = SplitMix64(seed: 42)
        XCTAssertEqual(rng.nextUUID(),
                       UUID(uuidString: "BDD73226-2FEB-6E95-28EF-E333B266F103"))
    }

    func testStableSeedDaily() {
        XCTAssertEqual(StableSeed.daily(day: 20_500, lat: 37.0, lng: -122.0,
                                        salt: 0x5A6F_6E65),
                       19_661_705_057 as UInt64)
    }

    func testStableZoneID() {
        // The id mile progress keys off — frozen formula, both sides.
        XCTAssertEqual(ZoneSelector.stableZoneID(
                           day: 20_500,
                           center: Coordinate(lat: 37.0, lng: -122.0)),
                       UUID(uuidString: "2E502634-6BA0-8766-2249-2944CA65C59F"))
    }

    func testMintReplaysTheServerCards() {
        let zone = RunnerZone(id: UUID(), name: "Vector Zone", lat: 37,
                              lng: -122, radiusM: 400, day: 20_500,
                              sourceRaw: "test")
        let stats = MintStats(distanceM: 1_609, steps: 0, xpEarned: 0)

        let otter = CardMinter.mint(seed: 12_345, zone: zone, at: Date(),
                                    serial: 1, stats: stats)
        XCTAssertEqual(otter.id,
                       UUID(uuidString: "2D160E7E-5C3F-42CA-81C2-E6DC980D78EB"))
        XCTAssertEqual(otter.name, "Towpath Otter")
        XCTAssertEqual(otter.type, .creature)
        XCTAssertEqual(otter.rarity, .uncommon)
        XCTAssertEqual(otter.stats.xpEarned, 40)

        let coral = CardMinter.mint(seed: 900, zone: zone, at: Date(),
                                    serial: 2, stats: stats)
        XCTAssertEqual(coral.cardID,
                       UUID(uuidString: "00000000-0000-0000-0000-0000000000C5"))
        XCTAssertEqual(coral.name, "Fossil Coral")
        XCTAssertEqual(coral.rarity, .uncommon)
        XCTAssertEqual(coral.stats.xpEarned, 35)

        let fact = CardMinter.mint(seed: 7, zone: zone, at: Date(),
                                   serial: 3, stats: stats)
        XCTAssertEqual(fact.cardID,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000078"))
        XCTAssertEqual(fact.name, "Left, Right, Repeat")
        XCTAssertEqual(fact.type, .fact)
        XCTAssertEqual(fact.stats.xpEarned, 15)
    }
}
