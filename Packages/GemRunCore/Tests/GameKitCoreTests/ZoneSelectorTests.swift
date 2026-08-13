import XCTest
@testable import GameKitCore
import CoreModels

/// Synthetic-map fixtures at 37°N, in metres east/north of a fixed origin —
/// the EngineTests style, applied to zone selection.
private func coord(_ xM: Double, _ yM: Double) -> Coordinate {
    Coordinate(lat: 37.0 + yM / 111_320.0,
               lng: -122.0 + xM / (111_320.0 * cos(37.0 * .pi / 180)))
}

private func squareRing(cx: Double, cy: Double, half: Double) -> [Coordinate] {
    [coord(cx - half, cy - half), coord(cx + half, cy - half),
     coord(cx + half, cy + half), coord(cx - half, cy + half),
     coord(cx - half, cy - half)]
}

private let user = coord(0, 0)

final class ZoneSelectorTests: XCTestCase {
    /// One big park with a real trail through it — the canonical happy path.
    private func parkWithTrail() -> ZonePlacementData {
        ZonePlacementData(
            parks: [.init(name: "Harbor Park", ring: squareRing(cx: 0, cy: 0, half: 400))],
            trails: [[coord(-300, 10), coord(300, 10)]])
    }

    func testSameDaySamePlaceSameZones() {
        let a = ZoneSelector.select(data: parkWithTrail(), around: user,
                                    day: 20_500, source: "test")
        let b = ZoneSelector.select(data: parkWithTrail(), around: user,
                                    day: 20_500, source: "test")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].name, "Harbor Park")
    }

    func testZoneIDIsStableWithinADayAndRotatesAcrossDays() {
        let center = coord(120, -80)
        XCTAssertEqual(ZoneSelector.stableZoneID(day: 20_500, center: center),
                       ZoneSelector.stableZoneID(day: 20_500, center: center))
        XCTAssertNotEqual(ZoneSelector.stableZoneID(day: 20_500, center: center),
                          ZoneSelector.stableZoneID(day: 20_501, center: center))
    }

    func testSelectionVariesAcrossDays() {
        // Eight equal parks in a wide ring; only some fit each day, so the
        // seeded pick must produce at least two distinct line-ups over
        // three weeks. Deterministic — the seeds are fixed by (day, cell).
        var parks: [ZonePlacementData.Park] = []
        var trails: [[Coordinate]] = []
        for k in 0..<8 {
            let theta = Double(k) / 8 * 2 * .pi
            let cx = 1_800 * cos(theta)
            let cy = 1_800 * sin(theta)
            parks.append(.init(name: "Park \(k)",
                               ring: squareRing(cx: cx, cy: cy, half: 300)))
            trails.append([coord(cx - 250, cy), coord(cx + 250, cy)])
        }
        let data = ZonePlacementData(parks: parks, trails: trails)
        var lineups = Set<String>()
        for day in 20_500..<20_521 {
            let names = ZoneSelector.select(data: data, around: user,
                                            day: day, source: "test")
                .map(\.name).sorted().joined(separator: "|")
            lineups.insert(names)
        }
        XCTAssertGreaterThanOrEqual(lineups.count, 2)
    }

    func testNoGoRingAtPerimeterVetoesTheAnchor() {
        var data = parkWithTrail()
        // The park alone yields radius ≈ min(max(√(640000/π)·1.1, 350), 500)
        // ≈ 496 m; probes sit at 0.8 × r ≈ 397 m. A golf course square over
        // the eastern probe must drop the candidate — fail closed.
        data.noGoRings = [squareRing(cx: 397, cy: 0, half: 60)]
        XCTAssertEqual(ZoneSelector.select(data: data, around: user,
                                           day: 20_500, source: "test"), [])
    }

    func testNoGoAtCenterVetoes() {
        var data = parkWithTrail()
        data.noGoRings = [squareRing(cx: 0, cy: 0, half: 50)]
        XCTAssertEqual(ZoneSelector.select(data: data, around: user,
                                           day: 20_500, source: "test"), [])
    }

    func testTrailGateDropsTheTraillessPark() {
        // Trails exist in the data, so the gate applies: the park without a
        // single trail metre inside its circle never becomes a zone.
        let data = ZonePlacementData(
            parks: [.init(name: "Trailed", ring: squareRing(cx: 0, cy: 0, half: 400)),
                    .init(name: "Trailless", ring: squareRing(cx: 1_900, cy: 0, half: 400))],
            trails: [[coord(-300, 10), coord(300, 10)]])
        let zones = ZoneSelector.select(data: data, around: user,
                                        day: 20_500, source: "test")
        XCTAssertEqual(zones.map(\.name), ["Trailed"])
    }

    func testParkOnlyScoringWhenProviderHasNoTrails() {
        // The MKLocalSearch fallback supplies no trail geometry at all —
        // park pedigree carries the argument and zones still come back.
        let data = ZonePlacementData(
            parks: [.init(name: "Apple Park", ring: squareRing(cx: 0, cy: 0, half: 400))])
        XCTAssertEqual(ZoneSelector.select(data: data, around: user,
                                           day: 20_500, source: "test").count, 1)
    }

    func testOverlappingCandidatesCollapseToOne() {
        let data = ZonePlacementData(
            parks: [.init(name: "West Green", ring: squareRing(cx: 0, cy: 0, half: 400)),
                    .init(name: "East Green", ring: squareRing(cx: 300, cy: 0, half: 400))])
        // 300 m apart with ~496 m radii — separation needs ≥ 1.2 × (r₁+r₂).
        XCTAssertEqual(ZoneSelector.select(data: data, around: user,
                                           day: 20_500, source: "test").count, 1)
    }

    func testRadiusClampsToTheZoneBand() {
        let small = ZonePlacementData(
            parks: [.init(name: "Pocket Park", ring: squareRing(cx: 0, cy: 0, half: 100))])
        let smallZones = ZoneSelector.select(data: small, around: user,
                                             day: 20_500, source: "test")
        XCTAssertEqual(smallZones.first?.radiusM, ZoneRules.minZoneRadiusM)

        let huge = ZonePlacementData(
            parks: [.init(name: "Forest", ring: squareRing(cx: 0, cy: 0, half: 500))])
        let hugeZones = ZoneSelector.select(data: huge, around: user,
                                            day: 20_500, source: "test")
        XCTAssertEqual(hugeZones.first?.radiusM, ZoneRules.maxZoneRadiusM)
    }

    func testTinyParksAndFarParksAreIgnored() {
        let data = ZonePlacementData(
            parks: [.init(name: "Lawn", ring: squareRing(cx: 0, cy: 0, half: 40)),
                    .init(name: "Far Meadow", ring: squareRing(cx: 4_000, cy: 0, half: 400))])
        XCTAssertEqual(ZoneSelector.select(data: data, around: user,
                                           day: 20_500, source: "test"), [])
    }

    func testAnsweredEmptyStaysEmpty() {
        XCTAssertEqual(ZoneSelector.select(data: ZonePlacementData(),
                                           around: user, day: 20_500,
                                           source: "test"), [])
    }
}

final class PolygonTests: XCTestCase {
    func testPointInConcaveRing() {
        // L-shape: the notch (top-right quadrant) is outside.
        let ring = [coord(0, 0), coord(200, 0), coord(200, 100),
                    coord(100, 100), coord(100, 200), coord(0, 200), coord(0, 0)]
        let polygons = NoGoPolygons(rings: [ring])
        let inside = coord(50, 150)
        let notch = coord(150, 150)
        XCTAssertTrue(polygons.contains(lat: inside.lat, lng: inside.lng))
        XCTAssertFalse(polygons.contains(lat: notch.lat, lng: notch.lng))
    }

    func testBBoxPrefilterRejectsFarPoints() {
        let polygons = NoGoPolygons(rings: [squareRing(cx: 0, cy: 0, half: 100)])
        let far = coord(5_000, 5_000)
        XCTAssertFalse(polygons.contains(lat: far.lat, lng: far.lng))
    }

    func testDegenerateRingsAreDropped() {
        let polygons = NoGoPolygons(rings: [[coord(0, 0), coord(10, 0), coord(0, 10)]])
        XCTAssertTrue(polygons.isEmpty)
        XCTAssertFalse(polygons.contains(lat: user.lat, lng: user.lng))
    }

    func testShoelaceAreaOfKnownSquare() {
        let area = RingMath.areaM2(squareRing(cx: 0, cy: 0, half: 100))
        XCTAssertEqual(area, 40_000, accuracy: 40_000 * 0.02)
    }

    func testCentroidOfClosedRing() {
        let centroid = RingMath.centroid(squareRing(cx: 300, cy: -200, half: 150))
        let expected = coord(300, -200)
        XCTAssertEqual(centroid.lat, expected.lat, accuracy: 1e-6)
        XCTAssertEqual(centroid.lng, expected.lng, accuracy: 1e-6)
    }
}

final class OverpassZoneParserTests: XCTestCase {
    private func element(type: String = "way", tags: [String: String],
                         points: [(Double, Double)]) -> String {
        let geometry = points
            .map { "{\"lat\": \($0.0), \"lon\": \($0.1)}" }
            .joined(separator: ", ")
        let tagPairs = tags
            .map { "\"\($0.key)\": \"\($0.value)\"" }
            .joined(separator: ", ")
        return "{\"type\": \"\(type)\", \"tags\": {\(tagPairs)}, \"geometry\": [\(geometry)]}"
    }

    func testClassifiesParksTrailsAndNoGoRings() throws {
        let square: [(Double, Double)] = [(37.0, -122.0), (37.001, -122.0),
                                          (37.001, -122.001), (37.0, -122.001),
                                          (37.0, -122.0)]
        let openLine: [(Double, Double)] = [(37.0, -122.0), (37.002, -122.002)]
        let json = """
        {"version": 0.6, "elements": [
        \(element(tags: ["leisure": "park", "name": "Riverside Park"], points: square)),
        \(element(tags: ["highway": "footway"], points: openLine)),
        \(element(tags: ["leisure": "golf_course"], points: square)),
        \(element(tags: ["leisure": "park", "access": "private"], points: square)),
        \(element(tags: ["highway": "footway", "footway": "access_aisle"], points: openLine)),
        \(element(tags: ["highway": "path", "foot": "private"], points: openLine)),
        \(element(tags: ["landuse": "recreation_ground"], points: square)),
        \(element(tags: ["amenity": "school"], points: square)),
        \(element(tags: ["highway": "footway"], points: [(37.0, -122.0)]))
        ]}
        """
        let data = try OverpassZoneParser.placementData(fromJSON: Data(json.utf8))
        XCTAssertEqual(data.parks.count, 2)   // Riverside Park + recreation ground
        XCTAssertEqual(data.parks.first?.name, "Riverside Park")
        XCTAssertEqual(data.trails.count, 1)  // the one clean footway
        XCTAssertEqual(data.noGoRings.count, 3)  // golf, private park, school
    }

    func testQueryCarriesTheContract() {
        let query = OverpassZoneParser.query(lat: 37.0, lng: -122.0,
                                             radiusM: 2_500, timeoutS: 15)
        XCTAssertTrue(query.contains("[out:json][timeout:15]"))
        XCTAssertTrue(query.contains("(around:2500,37.000000,-122.000000)"))
        XCTAssertTrue(query.contains("footway|pedestrian|path"))
        XCTAssertTrue(query.contains("park|nature_reserve|garden"))
        XCTAssertTrue(query.contains("golf_course"))
        XCTAssertTrue(query.contains("school|kindergarten|college|university"))
        XCTAssertTrue(query.contains("military|industrial|railway"))
        XCTAssertTrue(query.contains("aerodrome"))
        XCTAssertTrue(query.contains("out geom 1200"))
    }
}
