import XCTest
@testable import GameKitCore
import CoreModels

/// Fixture tracks against a synthetic zone — the same metres-east/north
/// coordinate trick as the selector tests. The zone is 500 m so a single
/// straight pass through the middle covers ~1 km.
final class ZoneProgressTrackerTests: XCTestCase {
    private func coord(_ xM: Double, _ yM: Double) -> Coordinate {
        Coordinate(lat: 37.0 + yM / 111_320.0,
                   lng: -122.0 + xM / (111_320.0 * cos(37.0 * .pi / 180)))
    }

    private func zone(cx: Double = 0, cy: Double = 0, radius: Double = 500,
                      day: Int = 20_500) -> RunnerZone {
        let center = coord(cx, cy)
        return RunnerZone(id: ZoneSelector.stableZoneID(day: day, center: center),
                          name: "Test Zone", lat: center.lat, lng: center.lng,
                          radiusM: radius, day: day, sourceRaw: "test")
    }

    private func fix(_ xM: Double, _ yM: Double, t: TimeInterval,
                     accuracy: Double = 10) -> ZoneFix {
        let c = coord(xM, yM)
        return ZoneFix(t: t, lat: c.lat, lng: c.lng, accuracyM: accuracy)
    }

    /// Walk straight through the zone: x from −520 m to +520 m in 13 m steps
    /// every 10 s (1.3 m/s). Full-inside segments credit 988 m, the two rim
    /// straddles credit 6.5 m each → 1001 m total.
    private func walkThrough(_ tracker: inout ZoneProgressTracker,
                             source: ZoneProgressTracker.Source = .map,
                             stepS: TimeInterval = 10) -> [ZoneProgressTracker.Event] {
        var events: [ZoneProgressTracker.Event] = []
        for i in 0...80 {
            let f = fix(-520 + 13 * Double(i), 0, t: 1_000 + stepS * Double(i))
            events.append(contentsOf: tracker.ingest(f, source: source))
        }
        return events
    }

    private func mintCount(_ events: [ZoneProgressTracker.Event]) -> Int {
        events.filter { if case .minted = $0 { true } else { false } }.count
    }

    func testCrossingTheMintThresholdMintsExactlyOnce() {
        var tracker = ZoneProgressTracker(zones: [zone()], mintDistanceM: 950)
        let events = walkThrough(&tracker)
        XCTAssertEqual(mintCount(events), 1)
        // 1001 m credited − 950 minted → ~51 m of overflow carried.
        XCTAssertEqual(tracker.progressM[zone().id] ?? 0, 51, accuracy: 3)
    }

    func testBadAccuracyCreditsNothing() {
        var tracker = ZoneProgressTracker(zones: [zone()], mintDistanceM: 950)
        for i in 0...80 {
            let f = fix(-520 + 13 * Double(i), 0, t: 1_000 + 10 * Double(i),
                        accuracy: 60)
            XCTAssertTrue(tracker.ingest(f, source: .map).isEmpty)
        }
        XCTAssertEqual(tracker.progressM[zone().id] ?? 0, 0)
    }

    func testAccuracyBlipDoesNotBreakTheChain() {
        var tracker = ZoneProgressTracker(zones: [zone()])
        _ = tracker.ingest(fix(0, 0, t: 1_000), source: .map)
        // A 70 m-accuracy fix mid-walk is ignored entirely…
        _ = tracker.ingest(fix(7, 0, t: 1_005, accuracy: 70), source: .map)
        // …and the next good fix still forms a segment from the last good one.
        let events = tracker.ingest(fix(14, 0, t: 1_010), source: .map)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tracker.progressM[zone().id] ?? 0, 14, accuracy: 0.5)
    }

    func testTeleportIsDroppedAndDoesNotPoisonTheNextSegment() {
        var tracker = ZoneProgressTracker(zones: [zone()])
        _ = tracker.ingest(fix(0, 0, t: 1_000), source: .map)
        _ = tracker.ingest(fix(14, 0, t: 1_010), source: .map)       // +14
        // 200 m in 2 s — impossible; nothing credited.
        XCTAssertTrue(tracker.ingest(fix(214, 0, t: 1_012), source: .map).isEmpty)
        // Walking on from the new anchor credits normally again.
        let events = tracker.ingest(fix(228, 0, t: 1_022), source: .map)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tracker.progressM[zone().id] ?? 0, 28, accuracy: 1)
    }

    func testRunPaceCountsForRunsButNotOnTheMap() {
        // 10 m every 2 s = 5 m/s: a real runner, but never map browsing.
        var mapTracker = ZoneProgressTracker(zones: [zone()])
        var runTracker = ZoneProgressTracker(zones: [zone()])
        for i in 0...10 {
            let f = fix(Double(i) * 10, 0, t: 1_000 + Double(i) * 2)
            _ = mapTracker.ingest(f, source: .map)
            _ = runTracker.ingest(f, source: .run)
        }
        XCTAssertEqual(mapTracker.progressM[zone().id] ?? 0, 0)
        XCTAssertEqual(runTracker.progressM[zone().id] ?? 0, 100, accuracy: 1)
    }

    func testLongGapBreaksTheChain() {
        var tracker = ZoneProgressTracker(zones: [zone()])
        _ = tracker.ingest(fix(0, 0, t: 1_000), source: .map)
        // 200 s later and 100 m away (backgrounded walk): no credit across
        // the hole, chain restarts here.
        XCTAssertTrue(tracker.ingest(fix(100, 0, t: 1_200), source: .map).isEmpty)
        let events = tracker.ingest(fix(114, 0, t: 1_210), source: .map)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tracker.progressM[zone().id] ?? 0, 14, accuracy: 0.5)
    }

    func testJitterAccumulatesIntoARealSegment() {
        var tracker = ZoneProgressTracker(zones: [zone()])
        _ = tracker.ingest(fix(0, 0, t: 1_000), source: .map)
        // 2 m wobbles hold the anchor instead of advancing it…
        XCTAssertTrue(tracker.ingest(fix(2, 0, t: 1_010), source: .map).isEmpty)
        XCTAssertTrue(tracker.ingest(fix(1, 1, t: 1_020), source: .map).isEmpty)
        // …so slow honest drift still lands one real segment from the anchor.
        let events = tracker.ingest(fix(15, 0, t: 1_030), source: .map)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tracker.progressM[zone().id] ?? 0, 15, accuracy: 0.5)
    }

    func testRimStraddleCreditsHalf() {
        var tracker = ZoneProgressTracker(zones: [zone()])
        _ = tracker.ingest(fix(490, 0, t: 1_000), source: .map)     // inside
        let events = tracker.ingest(fix(510, 0, t: 1_010), source: .map) // outside
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tracker.progressM[zone().id] ?? 0, 10, accuracy: 0.5)
    }

    func testTwoZonesAccrueIndependently() {
        let near = zone()
        let far = zone(cx: 2_000, day: 20_501)
        var tracker = ZoneProgressTracker(zones: [near, far])
        _ = walkThrough(&tracker)
        XCTAssertGreaterThan(tracker.progressM[near.id] ?? 0, 900)
        XCTAssertEqual(tracker.progressM[far.id] ?? 0, 0)
    }

    func testResumesFromPersistedProgress() {
        let z = zone()
        var tracker = ZoneProgressTracker(zones: [z],
                                          initialProgressM: [z.id: 960],
                                          mintDistanceM: 1_000)
        _ = tracker.ingest(fix(0, 0, t: 1_000), source: .map)
        let events = tracker.ingest(fix(50, 0, t: 1_030), source: .map)
        XCTAssertEqual(mintCount(events), 1)
        XCTAssertEqual(tracker.progressM[z.id] ?? 0, 10, accuracy: 0.5)
    }

    // MARK: - Polygon zones

    /// The L-shape from PolygonTests: a 200 m-wide bottom strip (y 0–100)
    /// plus the left column (x 0–100, y 100–200); the top-right quadrant
    /// is the notch — outside the zone.
    private func polygonZone(day: Int = 20_500) -> RunnerZone {
        let ring = [coord(0, 0), coord(200, 0), coord(200, 100),
                    coord(100, 100), coord(100, 200), coord(0, 200),
                    coord(0, 0)]
        let center = coord(66, 66)
        return RunnerZone(id: ZoneSelector.stableZoneID(day: day, center: center),
                          name: "L Park", lat: center.lat, lng: center.lng,
                          radiusM: 500, ring: ring, day: day, sourceRaw: "test")
    }

    func testPolygonZoneCreditsInsideTheRingOnly() {
        let z = polygonZone()
        var tracker = ZoneProgressTracker(zones: [z])
        // Inside the bottom arm: full credit. (The 500 m radiusM would
        // credit the notch too — the ring must win.)
        _ = tracker.ingest(fix(20, 20, t: 1_000), source: .map)
        var events = tracker.ingest(fix(80, 20, t: 1_040), source: .map)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tracker.progressM[z.id] ?? 0, 60, accuracy: 1)
        // Relocate into the notch across a chain-breaking gap, then walk
        // through it: entirely outside the L → nothing accrues.
        _ = tracker.ingest(fix(150, 150, t: 1_300), source: .map)
        events = tracker.ingest(fix(180, 150, t: 1_320), source: .map)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(tracker.progressM[z.id] ?? 0, 60, accuracy: 1)
    }

    func testPolygonRimStraddleCreditsHalf() {
        let z = polygonZone()
        var tracker = ZoneProgressTracker(zones: [z])
        // Left column → into the notch: one endpoint in, one out → half.
        _ = tracker.ingest(fix(80, 150, t: 1_000), source: .map)
        let events = tracker.ingest(fix(120, 150, t: 1_020), source: .map)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tracker.progressM[z.id] ?? 0, 20, accuracy: 0.5)
    }

    func testDailyMintCapSilencesTheZone() {
        let z = zone()
        var tracker = ZoneProgressTracker(zones: [z],
                                          mintCounts: [z.id: 2],
                                          mintDistanceM: 100)
        let events = walkThrough(&tracker)
        // 1001 m at a 100 m threshold would mean many mints — but the zone
        // entered the day two deep and caps at three.
        XCTAssertEqual(mintCount(events), 1)
        XCTAssertEqual(tracker.mintCounts[z.id], 3)
        // Once capped, the zone goes quiet entirely.
        XCTAssertEqual(tracker.progressM[z.id] ?? 0, 0, accuracy: 100)
    }
}

final class CardMinterTests: XCTestCase {
    private let zone = RunnerZone(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 9)),
        name: "Harbor Loop", lat: 37, lng: -122, radiusM: 400,
        day: 20_500, sourceRaw: "test")

    private let stats = MintStats(distanceM: 1_000, steps: 1_300, xpEarned: 0)

    func testOddsSumToOne() {
        XCTAssertEqual(MintOdds.legendary + MintOdds.epic + MintOdds.rare
                        + MintOdds.uncommon + MintOdds.common, 1.0,
                       accuracy: 1e-12)
    }

    func testSameSeedMintsTheIdenticalCard() {
        let a = CardMinter.mint(seed: 12_345, zone: zone,
                                at: Date(timeIntervalSince1970: 1_755_000_000),
                                serial: 7, stats: stats)
        let b = CardMinter.mint(seed: 12_345, zone: zone,
                                at: Date(timeIntervalSince1970: 1_755_000_000),
                                serial: 7, stats: stats)
        XCTAssertEqual(a, b)
    }

    func testStampsZoneSerialAndXP() {
        let card = CardMinter.mint(seed: 99, zone: zone, at: Date(),
                                   serial: 42, stats: stats)
        XCTAssertEqual(card.zoneID, zone.id)
        XCTAssertEqual(card.zoneName, "Harbor Loop")
        XCTAssertEqual(card.serial, 42)
        XCTAssertEqual(card.stats.distanceM, 1_000)
        let face = RunnerCardCatalog.entry(forCardID: card.cardID)
        XCTAssertNotNil(face)
        XCTAssertEqual(card.stats.xpEarned, face?.xp)
        XCTAssertEqual(card.name, face?.name)
    }

    func testRarityFrequenciesTrackThePublishedOdds() {
        var counts: [Rarity: Int] = [:]
        var typesSeen = Set<CardType>()
        let n = 100_000
        for seed in 0..<n {
            let card = CardMinter.mint(seed: UInt64(seed), zone: zone,
                                       at: Date(timeIntervalSince1970: 0),
                                       serial: seed, stats: stats)
            counts[card.rarity, default: 0] += 1
            typesSeen.insert(card.type)
        }
        let total = Double(n)
        // Generous bands — this guards the roll table, not statistics.
        XCTAssertEqual(Double(counts[.common] ?? 0) / total,
                       MintOdds.common, accuracy: 0.02)
        XCTAssertEqual(Double(counts[.uncommon] ?? 0) / total,
                       MintOdds.uncommon, accuracy: 0.02)
        XCTAssertEqual(Double(counts[.rare] ?? 0) / total,
                       MintOdds.rare, accuracy: 0.01)
        XCTAssertEqual(Double(counts[.epic] ?? 0) / total,
                       MintOdds.epic, accuracy: 0.008)
        XCTAssertEqual(Double(counts[.legendary] ?? 0) / total,
                       MintOdds.legendary, accuracy: 0.003)
        XCTAssertEqual(typesSeen, Set(CardType.allCases))
    }

    func testEmptyComboDegradesDownTheLadder() {
        let onlyCommonGear = [RunnerCardCatalog.Entry(
            cardID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 8)),
            name: "Loaner Laces", type: .gear, rarity: .common, xp: 5,
            stage: 1, abilityName: "Spare", abilityValue: "+0",
            abilityText: "Better than nothing.", foundMostWhere: "Anywhere",
            foundMostPct: 100, flavor: "Borrowed.", dropNote: "always")]
        for seed in 0..<50 {
            let card = CardMinter.mint(seed: UInt64(seed), zone: zone,
                                       at: Date(timeIntervalSince1970: 0),
                                       serial: 1, stats: stats,
                                       catalog: onlyCommonGear)
            XCTAssertEqual(card.name, "Loaner Laces")
        }
    }
}
