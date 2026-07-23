"""End-to-end API tests using the same fixture vectors as the Swift
GameKitCoreTests: a straight 1 km route heading north, tracks at known paces.
"""
import json
import uuid

from django.test import Client, TestCase

from . import catalog
from .geometry import RouteGeometry, polyline_decode, polyline_encode

DEG_PER_M_LAT = 1.0 / 111_320.0


def fixture_coords(length_m=1000, step=50):
    return [(37.0 + m * DEG_PER_M_LAT, -122.0) for m in range(0, length_m + 1, step)]


def track(speed, length_m=1000):
    """One sample per second along the route at a constant speed (m/s)."""
    samples = []
    t = 0.0
    while speed * t <= length_m:
        samples.append({"t": t, "lat": 37.0 + speed * t * DEG_PER_M_LAT,
                        "lng": -122.0, "horizontal_accuracy": 5.0, "speed": speed})
        t += 1.0
    return samples


class ApiTests(TestCase):
    def setUp(self):
        self.client = Client()
        response = self.post("/v1/auth/apple", {"handle": "tester"})
        self.assertEqual(response.status_code, 200)
        self.token = response.json()["token"]

    def post(self, path, payload, auth=False):
        headers = {"HTTP_AUTHORIZATION": f"Bearer {self.token}"} if auth else {}
        return self.client.post(path, data=json.dumps(payload),
                                content_type="application/json", **headers)

    def publish_route(self, gems=None, length_m=1000):
        coords = fixture_coords(length_m)
        payload = {"name": "Test Route", "polyline": polyline_encode(coords),
                   "distance_m": length_m, "elevation_gain_m": 0,
                   "difficulty": "easy", "status": "published", "run_count": 0,
                   "gem_drops": gems or []}
        return self.post("/v1/routes", payload, auth=True)

    def gem(self, rarity, position_m):
        geom = RouteGeometry(fixture_coords())
        lat, lng = geom.coordinate_at(position_m)
        return {"id": str(uuid.uuid4()), "gem_id": str(catalog.gem_of(rarity)["id"]),
                "rarity": rarity, "lat": lat, "lng": lng,
                "position_along_route_m": position_m,
                "respawn_rule": "daily" if rarity in ("common", "uncommon") else "once_per_user"}

    def complete(self, route_id, samples, claimed, key=None):
        return self.post(f"/v1/runs/{route_id}/complete", {
            "idempotency_key": key or str(uuid.uuid4()),
            "started_at": "2026-07-23T10:00:00Z", "ended_at": "2026-07-23T10:30:00Z",
            "track": samples, "claimed_collections": claimed,
            "client_flags": [], "client_streak_days": 0}, auth=True)

    # ------------------------------------------------------------- tests

    def test_polyline_roundtrip(self):
        coords = fixture_coords()
        decoded = polyline_decode(polyline_encode(coords))
        self.assertEqual(len(decoded), len(coords))
        for (alat, alng), (blat, blng) in zip(decoded, coords):
            self.assertAlmostEqual(alat, blat, places=4)
            self.assertAlmostEqual(alng, blng, places=4)

    def test_publish_and_geo_query(self):
        self.assertEqual(self.publish_route().status_code, 200)
        response = self.client.get("/v1/routes", {"lat": 37.0, "lng": -122.0,
                                                  "radius_m": 5000})
        self.assertEqual(len(response.json()["routes"]), 1)

    def test_budget_rejects_epic_on_short_route(self):
        response = self.publish_route(gems=[self.gem("epic", 600)])
        self.assertEqual(response.status_code, 422)

    def test_rare_gems_fuzzed_until_collected(self):
        route = self.publish_route(gems=[self.gem("rare", 600)]).json()
        drop = route["gem_drops"][0]
        self.assertEqual(drop["fuzz_radius_m"], 150)

    def test_clean_run_awards_and_ranks(self):
        gem = self.gem("common", 500)
        route = self.publish_route(gems=[gem]).json()
        verdict = self.complete(route["id"], track(3.0), [gem["id"]]).json()
        self.assertEqual(verdict["status"], "valid")
        self.assertEqual(len(verdict["awarded_drops"]), 1)
        self.assertEqual(verdict["revoked"], [])
        self.assertEqual(verdict["xp_earned"], 10)
        self.assertEqual(verdict["leaderboard_rank"], 1)

    def test_daily_respawn_dedupe(self):
        gem = self.gem("common", 500)
        route = self.publish_route(gems=[gem]).json()
        first = self.complete(route["id"], track(3.0), [gem["id"]]).json()
        self.assertEqual(len(first["awarded_drops"]), 1)
        second = self.complete(route["id"], track(3.0), [gem["id"]]).json()
        self.assertEqual(second["awarded_drops"], [])
        self.assertEqual(len(second["revoked"]), 1)

    def test_idempotent_completion(self):
        gem = self.gem("common", 500)
        route = self.publish_route(gems=[gem]).json()
        key = str(uuid.uuid4())
        first = self.complete(route["id"], track(3.0), [gem["id"]], key=key).json()
        again = self.complete(route["id"], track(3.0), [gem["id"]], key=key).json()
        self.assertEqual(first, again)
        stash = self.client.get("/v1/stash",
                                HTTP_AUTHORIZATION=f"Bearer {self.token}").json()
        self.assertEqual(len(stash["items"]), 1)

    def test_claim_without_track_support_is_revoked(self):
        gem = self.gem("common", 900)
        route = self.publish_route(gems=[gem]).json()
        # Track covers only the first 300 m — the claim can't be replayed.
        verdict = self.complete(route["id"], track(3.0, length_m=300), [gem["id"]]).json()
        self.assertNotEqual(verdict["status"], "valid")   # coverage flag
        self.assertEqual(verdict["awarded_drops"], [])

    def test_walk_pace_halves_xp(self):
        gem = self.gem("rare", 600)
        route = self.publish_route(gems=[gem]).json()
        verdict = self.complete(route["id"], track(1.2), [gem["id"]]).json()
        self.assertEqual(verdict["status"], "valid")
        self.assertEqual(verdict["xp_earned"], 38)           # 75 × 0.5, rounded
        self.assertIsNone(verdict["leaderboard_rank"])       # walks post no time

    def test_vehicle_speed_is_not_valid(self):
        route = self.publish_route().json()
        verdict = self.complete(route["id"], track(12.0), []).json()
        self.assertNotEqual(verdict["status"], "valid")

    def test_streak_extends_once_per_day(self):
        route = self.publish_route().json()
        # Run a little past the route end so sampled distance clears the
        # 1 km streak minimum despite per-sample quantization.
        self.complete(route["id"], track(3.0, length_m=1100), [])
        me = self.client.get("/v1/users/me",
                             HTTP_AUTHORIZATION=f"Bearer {self.token}").json()
        self.assertEqual(me["streak_count"], 1)
        self.complete(route["id"], track(3.0), [])
        me = self.client.get("/v1/users/me",
                             HTTP_AUTHORIZATION=f"Bearer {self.token}").json()
        self.assertEqual(me["streak_count"], 1)   # same day: no double count

    # ---- gem wallet + standalone drops (earn-by-running)

    def wallet_sync(self, km):
        return self.post("/v1/wallet/sync", {"total_run_km": km}, auth=True).json()

    def test_wallet_mints_from_distance_and_never_double_mints(self):
        self.assertEqual(self.wallet_sync(0)["wallet"], {})          # start at 0
        wallet = self.wallet_sync(11)["wallet"]
        self.assertEqual(wallet["common"], 5)                        # 11 // 2
        self.assertEqual(wallet["uncommon"], 2)                      # 11 // 5
        self.assertNotIn("rare", wallet)
        again = self.wallet_sync(11)["wallet"]                       # re-sync: no change
        self.assertEqual(again, wallet)
        more = self.wallet_sync(16)["wallet"]                        # +5 km later
        self.assertEqual(more["common"], 8)                          # 16 // 2
        self.assertEqual(more["rare"], 1)                            # 16 // 15

    def test_drop_requires_wallet_gem(self):
        gem_id = str(catalog.gem_of("common")["id"])
        denied = self.post("/v1/drops", {"gem_id": gem_id, "lat": 37.0, "lng": -122.0},
                           auth=True)
        self.assertEqual(denied.status_code, 422)                    # wallet empty
        self.wallet_sync(2)                                          # mint 1 common
        ok = self.post("/v1/drops", {"gem_id": gem_id, "lat": 37.0, "lng": -122.0},
                       auth=True)
        self.assertEqual(ok.status_code, 200)
        nearby = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                               "radius_m": 1000}).json()
        self.assertEqual(len(nearby["drops"]), 1)

    def test_collect_drop_is_one_time_and_never_own(self):
        self.wallet_sync(2)
        gem_id = str(catalog.gem_of("common")["id"])
        drop = self.post("/v1/drops", {"gem_id": gem_id, "lat": 37.001, "lng": -122.0},
                         auth=True).json()
        near_track = [{"t": 0, "lat": 37.001, "lng": -122.0,
                       "horizontal_accuracy": 5, "speed": 3}]
        # Own drop: never collectable.
        own = self.post("/v1/drops/collect", {"claimed": [drop["id"]],
                                              "track": near_track}, auth=True).json()
        self.assertEqual(own["awarded_drops"], [])
        # A different runner passes it: collected, then gone for everyone.
        other_token = self.client.post(
            "/v1/auth/apple", data=json.dumps({"handle": "rival"}),
            content_type="application/json").json()["token"]
        got = self.client.post("/v1/drops/collect",
                               data=json.dumps({"claimed": [drop["id"]],
                                                "track": near_track}),
                               content_type="application/json",
                               HTTP_AUTHORIZATION=f"Bearer {other_token}").json()
        self.assertEqual(len(got["awarded_drops"]), 1)
        self.assertEqual(got["xp_earned"], 10)
        nearby = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                               "radius_m": 1000}).json()
        self.assertEqual(nearby["drops"], [])                        # one-time
        # A track that never came near awards nothing.
        far = self.client.post("/v1/drops/collect",
                               data=json.dumps({"claimed": [drop["id"]],
                                                "track": [{"t": 0, "lat": 38.0,
                                                           "lng": -122.0,
                                                           "horizontal_accuracy": 5,
                                                           "speed": 3}]}),
                               content_type="application/json",
                               HTTP_AUTHORIZATION=f"Bearer {other_token}").json()
        self.assertEqual(far["awarded_drops"], [])

    def test_catalog_matches_client_uuids(self):
        gems = self.client.get("/v1/gems/catalog").json()["gems"]
        self.assertEqual(len(gems), 8)
        # Swift GemCatalog uses UUID(uuid: (0,...,0,10)) for Trail Quartz.
        self.assertIn("00000000-0000-0000-0000-00000000000a",
                      [g["id"] for g in gems])
