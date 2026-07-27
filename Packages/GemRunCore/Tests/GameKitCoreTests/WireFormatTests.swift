import CoreModels
import XCTest

/// Backend wire-format fixtures — the EXACT JSON the Django API emits —
/// decoded with the same strategy HTTPGemRunAPI uses. Guards against
/// key-mapping regressions like `gem_id` → convertFromSnakeCase → `gemId`
/// never matching the acronym-cased property `gemID`, which silently
/// emptied the map of gems.
final class WireFormatTests: XCTestCase {
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }

    func testDropsResponseDecodes() throws {
        let json = """
        {"drops": [{"id": "11111111-1111-1111-1111-111111111111",
                    "gem_id": "00000000-0000-0000-0000-00000000000A",
                    "rarity": "rare", "lat": 37.7749, "lng": -122.4194,
                    "position_along_route_m": 0, "respawn_rule": "one_time",
                    "placed_by": "system", "fuzz_radius_m": null}]}
        """
        struct DropsResponse: Decodable { let drops: [GemDrop] }
        let decoded = try decoder.decode(DropsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.drops.count, 1)
        let drop = try XCTUnwrap(decoded.drops.first)
        XCTAssertEqual(drop.gemID.uuidString, "00000000-0000-0000-0000-00000000000A")
        XCTAssertEqual(drop.rarity, .rare)
        XCTAssertEqual(drop.respawnRule, .oneTime)
        XCTAssertEqual(drop.placedBy, .system)
        XCTAssertNil(drop.fuzzRadiusM)
    }

    func testRoutesEnvelopeDecodes() throws {
        // GET /v1/routes wraps the list: {"routes": [...]} — the client must
        // decode the envelope, not a bare array.
        let json = """
        {"routes": [{"id": "22222222-2222-2222-2222-222222222222",
                     "name": "R", "description": null, "polyline": "abc",
                     "distance_m": 2000, "elevation_gain_m": 20,
                     "difficulty": "easy", "status": "published",
                     "creator_handle": null, "run_count": 3,
                     "gem_drops": [], "elevation_profile": null}]}
        """
        struct RoutesResponse: Decodable { let routes: [Route] }
        let decoded = try decoder.decode(RoutesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.routes.count, 1)
    }

    func testRouteWithNestedDropsDecodes() throws {
        let json = """
        {"id": "22222222-2222-2222-2222-222222222222", "name": "First Light Loop",
         "description": null, "polyline": "abc", "distance_m": 2000,
         "elevation_gain_m": 20, "difficulty": "easy", "status": "published",
         "creator_handle": null, "run_count": 3,
         "gem_drops": [{"id": "33333333-3333-3333-3333-333333333333",
                        "gem_id": "00000000-0000-0000-0000-00000000000A",
                        "rarity": "common", "lat": 37.0, "lng": -122.0,
                        "position_along_route_m": 500, "respawn_rule": "daily",
                        "placed_by": "creator", "fuzz_radius_m": 150}],
         "elevation_profile": [0, 5, 10]}
        """
        let route = try decoder.decode(Route.self, from: Data(json.utf8))
        XCTAssertEqual(route.gemDrops.count, 1)
        XCTAssertEqual(route.gemDrops[0].fuzzRadiusM, 150)
        XCTAssertEqual(route.runCount, 3)
    }

    func testStashItemDecodes() throws {
        let json = """
        {"id": "44444444-4444-4444-4444-444444444444",
         "gem_id": "00000000-0000-0000-0000-00000000000A",
         "gem_drop_id": "33333333-3333-3333-3333-333333333333",
         "run_id": "00000000-0000-0000-0000-000000000000",
         "collected_at": "2026-07-23T10:00:00Z", "is_first_find": true}
        """
        let item = try decoder.decode(StashItem.self, from: Data(json.utf8))
        XCTAssertTrue(item.isFirstFind)
        XCTAssertEqual(item.gemDropID.uuidString,
                       "33333333-3333-3333-3333-333333333333")
    }

    func testCatalogGemDecodes() throws {
        let json = """
        {"id": "00000000-0000-0000-0000-00000000000A", "name": "Trail Quartz",
         "rarity": "common", "set_id": "00000000-0000-0000-0000-000000000001",
         "icon_ref": "gem.quartz"}
        """
        let gem = try decoder.decode(Gem.self, from: Data(json.utf8))
        XCTAssertEqual(gem.setID.uuidString, "00000000-0000-0000-0000-000000000001")
    }

    func testUserProfileDecodes() throws {
        let json = """
        {"id": "55555555-5555-5555-5555-555555555555", "handle": "runner",
         "avatar_url": null, "xp": 10, "level": 1,
         "streak_count": 0, "streak_shields": 0}
        """
        let profile = try decoder.decode(UserProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.handle, "runner")
        XCTAssertNil(profile.avatarURL)
    }

    func testGemDropEncodesBackToSnakeCase() throws {
        // publishRoute must keep emitting the backend's key spellings.
        let drop = GemDrop(id: UUID(), gemID: UUID(), rarity: .common,
                           lat: 37.0, lng: -122.0, positionAlongRouteM: 100,
                           respawnRule: .daily)
        let data = try encoder.encode(drop)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object.keys.contains("gem_id"))
        XCTAssertTrue(object.keys.contains("position_along_route_m"))
        XCTAssertFalse(object.keys.contains("gemID"))
    }
}
