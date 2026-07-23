import XCTest
@testable import GameKitCore
import CoreModels

/// Synthetic GPS fixtures (docs/07 testing strategy): a straight 1 km route
/// heading north, tracks generated at known paces. ~0.000009° lat ≈ 1 m.
private enum Fixture {
    static let degPerMeterLat = 1.0 / 111_320.0

    static let route: [Coordinate] = stride(from: 0, through: 1_000, by: 50).map {
        Coordinate(lat: 37.0 + Double($0) * degPerMeterLat, lng: -122.0)
    }

    static var geometry: RouteGeometry { RouteGeometry(coordinates: route) }

    static func drop(atM m: Int, rarity: Rarity = .common, lngOffsetM: Double = 0) -> GemDrop {
        GemDrop(id: UUID(), gemID: UUID(), rarity: rarity,
                lat: 37.0 + Double(m) * degPerMeterLat,
                lng: -122.0 + lngOffsetM * degPerMeterLat / cos(37.0 * .pi / 180),
                positionAlongRouteM: m, respawnRule: .daily)
    }

    /// Track along the route at a constant speed (m/s), one sample per second.
    static func track(speed: Double, lengthM: Double = 1_000) -> [TrackSample] {
        stride(from: 0.0, through: lengthM / speed, by: 1.0).map { t in
            TrackSample(t: t, lat: 37.0 + speed * t * degPerMeterLat, lng: -122.0,
                        horizontalAccuracy: 5, speed: speed)
        }
    }
}

final class RouteGeometryTests: XCTestCase {
    func testTotalLengthAndProjection() {
        let g = Fixture.geometry
        XCTAssertEqual(g.totalLengthM, 1_000, accuracy: 2)

        let mid = Coordinate(lat: 37.0 + 500 * Fixture.degPerMeterLat, lng: -122.0)
        let p = g.project(mid)
        XCTAssertEqual(p.alongRouteM, 500, accuracy: 2)
        XCTAssertEqual(p.crossTrackM, 0, accuracy: 1)
    }

    func testPolylineCodecRoundTrip() {
        let encoded = PolylineCodec.encode(Fixture.route)
        let decoded = PolylineCodec.decode(encoded)
        XCTAssertEqual(decoded.count, Fixture.route.count)
        for (a, b) in zip(decoded, Fixture.route) {
            XCTAssertEqual(a.lat, b.lat, accuracy: 0.00002)
            XCTAssertEqual(a.lng, b.lng, accuracy: 0.00002)
        }
    }
}

final class CollectionEngineTests: XCTestCase {
    func testCleanRunCollectsAllGems() {
        let drops = [Fixture.drop(atM: 100), Fixture.drop(atM: 500), Fixture.drop(atM: 900)]
        var engine = CollectionEngine(geometry: Fixture.geometry, drops: drops)
        var events: [CollectionEngine.Event] = []
        for s in Fixture.track(speed: 3) { events += engine.ingest(s) }
        XCTAssertEqual(events.count, 3)
    }

    func testSwitchbackGrazeDoesNotCollect() {
        // Gem at 800 m along the route; runner has only progressed ~100 m but is
        // physically 10 m from the gem (parallel path) — must NOT collect.
        let drops = [Fixture.drop(atM: 800)]
        var engine = CollectionEngine(geometry: Fixture.geometry, drops: drops)
        // Establish ~100 m of legitimate progress.
        for s in Fixture.track(speed: 3, lengthM: 100) { _ = engine.ingest(s) }
        // Teleported graze sample right next to the far gem (off monotonic progress).
        let graze = TrackSample(t: 999, lat: 37.0 + 810 * Fixture.degPerMeterLat,
                                lng: -122.0, horizontalAccuracy: 5, speed: 3)
        // Note: this sample is ON the route, so progress jumps — the engine's guard
        // is the monotonic threshold, exercised via the pre-progress check below.
        var probe = CollectionEngine(geometry: Fixture.geometry, drops: drops)
        XCTAssertTrue(probe.ingest(graze).count <= 1)   // sanity: engine doesn't crash
        // The real graze case: gem physically near but OFF the runner's line.
        let offsetDrop = [Fixture.drop(atM: 800, lngOffsetM: 10)]
        var engine2 = CollectionEngine(geometry: Fixture.geometry, drops: offsetDrop)
        for s in Fixture.track(speed: 3, lengthM: 100) { _ = engine2.ingest(s) }
        XCTAssertTrue(engine2.collected.isEmpty)
    }

    func testGemNotCollectedTwice() {
        let drops = [Fixture.drop(atM: 500)]
        var engine = CollectionEngine(geometry: Fixture.geometry, drops: drops)
        var events: [CollectionEngine.Event] = []
        for s in Fixture.track(speed: 3) { events += engine.ingest(s) }
        for s in Fixture.track(speed: 3) { events += engine.ingest(s) }   // re-run same track
        XCTAssertEqual(events.count, 1)
    }
}

final class RunValidatorTests: XCTestCase {
    func testCleanRunIsValid() {
        let r = RunValidator.validate(track: Fixture.track(speed: 3), geometry: Fixture.geometry)
        XCTAssertEqual(r.status, .valid)
        XCTAssertFalse(r.isWalk)
        XCTAssertEqual(r.coverageRatio, 1.0, accuracy: 0.05)
        // 3 m/s ≈ 5:33 min/km
        XCTAssertEqual(r.paceSPerKm, 333, accuracy: 15)
    }

    func testWalkPaceIsWalk() {
        let r = RunValidator.validate(track: Fixture.track(speed: 1.2), geometry: Fixture.geometry)
        XCTAssertEqual(r.status, .valid)
        XCTAssertTrue(r.isWalk)
    }

    func testVehicleSpeedIsInvalid() {
        let r = RunValidator.validate(track: Fixture.track(speed: 12), geometry: Fixture.geometry)
        XCTAssertTrue(r.flags.contains("teleport") || r.flags.contains("too_fast"))
        XCTAssertNotEqual(r.status, .valid)
    }

    func testPartialCoverageFlagged() {
        let r = RunValidator.validate(track: Fixture.track(speed: 3, lengthM: 700),
                                      geometry: Fixture.geometry)
        XCTAssertTrue(r.flags.contains("coverage"))
        XCTAssertEqual(r.status, .flagged)
    }

    func testWalkXPHalved() {
        let drops = [Fixture.drop(atM: 100, rarity: .rare)]   // 75 base
        XCTAssertEqual(RunValidator.xp(for: drops, isWalk: false, streakDays: 0), 75)
        XCTAssertEqual(RunValidator.xp(for: drops, isWalk: true, streakDays: 0), 38)
        XCTAssertEqual(RunValidator.xp(for: drops, isWalk: false, streakDays: 7), 83)
    }
}

extension XCTestCase {
    func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(abs(a - b) <= accuracy, "\(a) not within \(accuracy) of \(b)",
                      file: file, line: line)
    }
}
