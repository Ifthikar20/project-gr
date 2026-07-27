"""End-to-end API tests using the same fixture vectors as the Swift
GameKitCoreTests: a straight 1 km route heading north, tracks at known paces.
"""
import io
import json
import uuid
from unittest import mock

from django.core.management import call_command
from django.test import Client, TestCase, override_settings

from . import catalog, walkability
from .geometry import RouteGeometry, polyline_decode, polyline_encode
from .models import ClaimAttempt, GemDrop, Route

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


# Hermetic: no real Overpass calls from tests; the walkability/bootstrap
# tests below opt back in with mocked transports.
@override_settings(WALKABILITY_MODE="off", PRESENCE_BOOTSTRAP=False)
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

    # ---- system drops on popular walkable paths (docs/13)

    def seed_popular_route(self, run_count=5):
        route_id = self.publish_route().json()["id"]
        Route.objects.filter(id=route_id).update(run_count=run_count)
        return route_id

    def test_drop_gems_targets_popular_routes_only(self):
        self.seed_popular_route(run_count=5)
        self.publish_route()                      # run_count 0 — not popular
        call_command("drop_gems", max_drops=2, min_runs=3, seed=7,
                     stdout=io.StringIO())
        drops = GemDrop.objects.filter(route__isnull=True, placed_by="system")
        self.assertEqual(drops.count(), 1)        # 1 popular route → 1 drop
        drop = drops.get()
        self.assertEqual(drop.respawn_rule, "one_time")
        self.assertIsNone(drop.dropped_by)
        self.assertNotEqual(drop.rarity, "legendary")
        # On the route's path: fixture route runs due north on lng -122.
        self.assertAlmostEqual(drop.lng, -122.0, places=4)
        self.assertTrue(37.0 <= drop.lat <= 37.0 + 1000 * DEG_PER_M_LAT)
        # Visible in the master-table geo query.
        nearby = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                               "radius_m": 5000}).json()
        self.assertEqual(len(nearby["drops"]), 1)

    def test_drop_gems_skips_unwalkable_points(self):
        self.seed_popular_route()
        with mock.patch("api.walkability.is_walkable", return_value=False):
            call_command("drop_gems", seed=7, stdout=io.StringIO())
        self.assertEqual(
            GemDrop.objects.filter(route__isnull=True, placed_by="system").count(), 0)

    def test_system_drops_trust_route_snap_when_check_unanswerable(self):
        """Candidates come from walking-snapped route polylines, so an
        unanswerable walkability check (None — Overpass down/rate-limited)
        must NOT block gem spawning; only an explicit False vetoes."""
        self.seed_popular_route()
        system = GemDrop.objects.filter(route__isnull=True, placed_by="system")
        with self.settings(WALKABILITY_MODE="overpass"):
            with mock.patch("api.walkability.is_walkable", return_value=None):
                call_command("drop_gems", seed=7, stdout=io.StringIO())
                self.assertEqual(system.count(), 1)          # trusted, spawns
                self.wallet_sync(2)                          # user drop: fail open
                ok = self.post("/v1/drops",
                               {"gem_id": str(catalog.gem_of("common")["id"]),
                                "lat": 37.0, "lng": -122.0}, auth=True)
                self.assertEqual(ok.status_code, 200)
            with mock.patch("api.walkability.is_walkable", return_value=False):
                call_command("drop_gems", seed=8, stdout=io.StringIO())
                self.assertEqual(system.count(), 1)          # False still vetoes

    def test_drop_rejected_on_unwalkable_coordinate(self):
        self.wallet_sync(2)
        gem_id = str(catalog.gem_of("common")["id"])
        with mock.patch("api.views.walkability.is_walkable", return_value=False):
            denied = self.post("/v1/drops",
                               {"gem_id": gem_id, "lat": 37.0, "lng": -122.0},
                               auth=True)
        self.assertEqual(denied.status_code, 422)
        self.assertEqual(denied.json()["code"], "not_walkable")

    def test_overpass_walkability_call(self):
        walkability._down_until = 0.0          # reset circuit breaker
        hit = io.BytesIO(json.dumps({"elements": [{"type": "way", "id": 1}]}).encode())
        miss = io.BytesIO(json.dumps({"elements": []}).encode())
        with self.settings(WALKABILITY_MODE="overpass"):
            with mock.patch("urllib.request.urlopen") as urlopen:
                urlopen.return_value.__enter__ = lambda s: hit
                urlopen.return_value.__exit__ = mock.Mock(return_value=False)
                self.assertIs(walkability.is_walkable(37.0, -122.0), True)
                urlopen.return_value.__enter__ = lambda s: miss
                self.assertIs(walkability.is_walkable(37.0, -122.0), False)
            with mock.patch("urllib.request.urlopen", side_effect=OSError):
                self.assertIsNone(walkability.is_walkable(37.0, -122.0))
            # Total failure opens the circuit: next call skips the network.
            with mock.patch("urllib.request.urlopen") as skipped:
                self.assertIsNone(walkability.is_walkable(37.0, -122.0))
                skipped.assert_not_called()
            walkability._down_until = 0.0      # don't leak into other tests
        self.assertIsNone(walkability.is_walkable(37.0, -122.0))   # mode off

    def test_claim_attempts_log_the_race(self):
        """Two neighbors go for the same gem: the log shows the winner AND
        the loser, with outcomes and how close each track came."""
        drop = GemDrop.objects.create(
            route=None, dropped_by=None, gem_id=catalog.gem_of("common")["id"],
            rarity="common", lat=37.001, lng=-122.0,
            position_along_route_m=0, respawn_rule="one_time", placed_by="system")
        near = [{"t": 0, "lat": 37.001, "lng": -122.0,
                 "horizontal_accuracy": 5, "speed": 3}]

        def claim(handle):
            token = self.client.post(
                "/v1/auth/apple", data=json.dumps({"handle": handle}),
                content_type="application/json").json()["token"]
            return self.client.post(
                "/v1/drops/collect",
                data=json.dumps({"claimed": [str(drop.id)], "track": near}),
                content_type="application/json",
                HTTP_AUTHORIZATION=f"Bearer {token}").json()

        self.assertEqual(len(claim("neighbor_a")["awarded_drops"]), 1)   # wins
        self.assertEqual(claim("neighbor_b")["awarded_drops"], [])       # 3 s late
        log = list(ClaimAttempt.objects.filter(gem_drop=drop)
                   .order_by("created_at")
                   .values_list("profile__handle", "outcome", "closest_m"))
        self.assertEqual([(h, o) for h, o, _ in log],
                         [("neighbor_a", "awarded"),
                          ("neighbor_b", "already_taken")])
        for _, _, closest in log:
            self.assertLess(closest, 1.0)   # both tracks were right on it

    def test_claim_attempts_log_too_far_and_bad_gps(self):
        self.wallet_sync(2)
        gem_id = str(catalog.gem_of("common")["id"])
        drop = self.post("/v1/drops", {"gem_id": gem_id, "lat": 37.001,
                                       "lng": -122.0}, auth=True).json()
        rival = self.client.post(
            "/v1/auth/apple", data=json.dumps({"handle": "rival"}),
            content_type="application/json").json()["token"]
        # Right coordinates but hopeless GPS accuracy: samples are ignored,
        # so the claim can't prove presence — too_far, closest unknown.
        blurry = [{"t": 0, "lat": 37.001, "lng": -122.0,
                   "horizontal_accuracy": 200, "speed": 3}]
        got = self.client.post(
            "/v1/drops/collect",
            data=json.dumps({"claimed": [drop["id"]], "track": blurry}),
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {rival}").json()
        self.assertEqual(got["awarded_drops"], [])
        attempt = ClaimAttempt.objects.get(gem_drop_id=drop["id"])
        self.assertEqual((attempt.outcome, attempt.closest_m), ("too_far", None))
        # Own-drop attempts are logged too.
        near = [{"t": 0, "lat": 37.001, "lng": -122.0,
                 "horizontal_accuracy": 5, "speed": 3}]
        self.post("/v1/drops/collect", {"claimed": [drop["id"]], "track": near},
                  auth=True)
        self.assertEqual(ClaimAttempt.objects.filter(
            gem_drop_id=drop["id"], outcome="own_drop").count(), 1)

    def test_route_run_race_is_logged(self):
        route = self.publish_route().json()
        drop = GemDrop.objects.create(
            route=None, dropped_by=None, gem_id=catalog.gem_of("rare")["id"],
            rarity="rare", lat=37.0 + 500 * DEG_PER_M_LAT, lng=-122.0,
            position_along_route_m=0, respawn_rule="one_time", placed_by="system")
        self.complete(route["id"], track(3.0), [])                # winner
        rival = self.client.post(
            "/v1/auth/apple", data=json.dumps({"handle": "rival"}),
            content_type="application/json").json()["token"]
        self.client.post(                                          # loser
            f"/v1/runs/{route['id']}/complete",
            data=json.dumps({"idempotency_key": str(uuid.uuid4()),
                             "started_at": "2026-07-23T11:00:00Z",
                             "track": track(3.0), "claimed_collections": []}),
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {rival}")
        outcomes = list(ClaimAttempt.objects.filter(gem_drop=drop)
                        .order_by("created_at").values_list("source", "outcome"))
        self.assertEqual(outcomes, [("route_run", "awarded"),
                                    ("route_run", "already_taken")])

    def test_stock_gems_spawns_at_startup_and_reports(self):
        self.seed_popular_route(run_count=5)
        out = io.StringIO()
        call_command("stock_gems", lat=37.0, lng=-122.0, stdout=out)
        self.assertIn("Stocked 1 new system gem(s)", out.getvalue())
        self.assertIn("1 standalone active", out.getvalue())
        # Second start: already stocked, says so, no pile-up.
        again = io.StringIO()
        call_command("stock_gems", lat=37.0, lng=-122.0, stdout=again)
        self.assertIn("No new gems needed", again.getvalue())
        self.assertEqual(GemDrop.objects.filter(route__isnull=True,
                                                placed_by="system").count(), 1)

    def test_presence_trigger_spawns_and_replenishes_gems(self):
        self.seed_popular_route(run_count=5)
        # Opening the map IS the trigger: the query's own coordinates get
        # topped up (1 popular route → target 1 system drop).
        nearby = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                               "radius_m": 5000}).json()
        self.assertEqual(len(nearby["drops"]), 1)
        first_id = nearby["drops"][0]["id"]
        # Self-limiting: another map open never piles up more gems.
        again = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                              "radius_m": 5000}).json()
        self.assertEqual([d["id"] for d in again["drops"]], [first_id])
        # Once collected, the next map open replenishes with a NEW gem.
        GemDrop.objects.filter(id=first_id).update(active=False)
        refreshed = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                  "radius_m": 5000}).json()
        self.assertEqual(len(refreshed["drops"]), 1)
        self.assertNotEqual(refreshed["drops"][0]["id"], first_id)

    def test_map_open_bootstraps_gems_where_user_is(self):
        """The SYSTEM creates gems near wherever a user opens the map — no
        routes and no other users required. With OSM unreachable too, the
        last-resort tier scatters them a short walk from the user."""
        with self.settings(PRESENCE_BOOTSTRAP=True), \
             mock.patch("api.walkability.fetch_walkable_ways", return_value=[]):
            drops = self.client.get("/v1/drops", {"lat": 64.2008, "lng": -149.4937,
                                                  "radius_m": 5000}).json()["drops"]
            self.assertEqual(len(drops), 3)              # stocked to the area cap
            for d in drops:                              # all a short walk away
                dy = (d["lat"] - 64.2008) * 111_320
                dx = (d["lng"] + 149.4937) * 111_320 * 0.435   # cos(64.2°)
                self.assertLess((dx * dx + dy * dy) ** 0.5, 600)
            # Self-limiting: another map open adds nothing.
            again = self.client.get("/v1/drops", {"lat": 64.2008, "lng": -149.4937,
                                                  "radius_m": 5000}).json()["drops"]
            self.assertEqual(len(again), 3)

    def test_bootstrap_prefers_real_walkable_ways(self):
        """When OSM answers, bootstrap gems land ON walkable-way geometry,
        not scattered around the user."""
        step = 500 * DEG_PER_M_LAT
        ways = [[(64.2 + i * step, -149.4937), (64.2 + (i + 1) * step, -149.4937)]
                for i in range(8)]
        with self.settings(PRESENCE_BOOTSTRAP=True), \
             mock.patch("api.walkability.fetch_walkable_ways", return_value=ways):
            drops = self.client.get("/v1/drops", {"lat": 64.2008, "lng": -149.4937,
                                                  "radius_m": 5000}).json()["drops"]
        self.assertEqual(len(drops), 3)
        for d in drops:                                  # exactly on the street line
            self.assertAlmostEqual(d["lng"], -149.4937, places=5)

    def test_route_run_claims_crossed_system_drop_first_come(self):
        route = self.publish_route().json()
        drop = GemDrop.objects.create(
            route=None, dropped_by=None, gem_id=catalog.gem_of("rare")["id"],
            rarity="rare", lat=37.0 + 500 * DEG_PER_M_LAT, lng=-122.0,
            position_along_route_m=0, respawn_rule="one_time", placed_by="system")
        verdict = self.complete(route["id"], track(3.0), []).json()
        self.assertEqual([d["id"] for d in verdict["awarded_drops"]], [str(drop.id)])
        self.assertEqual(verdict["xp_earned"], 75)
        # First come, first served: a second runner crossing it gets nothing.
        rival = self.client.post("/v1/auth/apple",
                                 data=json.dumps({"handle": "rival"}),
                                 content_type="application/json").json()["token"]
        second = self.client.post(
            f"/v1/runs/{route['id']}/complete",
            data=json.dumps({"idempotency_key": str(uuid.uuid4()),
                             "started_at": "2026-07-23T11:00:00Z",
                             "track": track(3.0), "claimed_collections": []}),
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {rival}").json()
        self.assertEqual(second["awarded_drops"], [])
        self.assertEqual(second["xp_earned"], 0)

    def test_seed_builds_street_routes_from_osm_ways(self):
        """Demo routes chain real walkable-way geometry into out-and-backs
        starting at the given coordinate — no geometric circles."""
        # Synthetic street: a straight chain of 500 m walkable segments
        # heading north along lng=-122 (as Overpass would return them).
        step = 500 * DEG_PER_M_LAT
        ways = [[(37.0 + i * step, -122.0), (37.0 + (i + 1) * step, -122.0)]
                for i in range(24)]
        with mock.patch("api.walkability.fetch_walkable_ways",
                        return_value=ways):
            call_command("seed", lat=37.0, lng=-122.0, stdout=io.StringIO())
        routes = Route.objects.filter(creator__isnull=True)
        self.assertEqual(routes.count(), 3)
        for route in routes:
            coords = polyline_decode(route.polyline)
            # Follows the street exactly — every point on lng -122.
            self.assertTrue(all(abs(lng + 122.0) < 1e-4 for _, lng in coords))
            # Out-and-back: ends where it started.
            self.assertAlmostEqual(coords[0][0], coords[-1][0], places=4)
            self.assertEqual(route.run_count, 3)          # competitor times
        # The first route starts AT the requested coordinate.
        first = min(routes, key=lambda r: r.distance_m)
        self.assertLess(abs(polyline_decode(first.polyline)[0][0] - 37.0)
                        * 111_320, 50)

    def test_seed_without_street_data_seeds_nothing(self):
        with mock.patch("api.walkability.fetch_walkable_ways", return_value=[]):
            call_command("seed", lat=64.2, lng=-149.5, stdout=io.StringIO())
        self.assertEqual(Route.objects.filter(creator__isnull=True).count(), 0)

    def test_seed_clear_removes_demo_data_without_reseeding(self):
        step = 500 * DEG_PER_M_LAT
        ways = [[(37.0 + i * step, -122.0), (37.0 + (i + 1) * step, -122.0)]
                for i in range(24)]
        with mock.patch("api.walkability.fetch_walkable_ways", return_value=ways):
            call_command("seed", lat=37.0, lng=-122.0, stdout=io.StringIO())
        self.assertTrue(Route.objects.filter(creator__isnull=True).exists())
        call_command("seed", clear=True, stdout=io.StringIO())
        self.assertFalse(Route.objects.filter(creator__isnull=True).exists())
        self.assertFalse(GemDrop.objects.filter(route__isnull=True,
                                                dropped_by__isnull=True).exists())

    def test_catalog_matches_client_uuids(self):
        gems = self.client.get("/v1/gems/catalog").json()["gems"]
        self.assertEqual(len(gems), 8)
        # Swift GemCatalog uses UUID(uuid: (0,...,0,10)) for Trail Quartz.
        self.assertIn("00000000-0000-0000-0000-00000000000a",
                      [g["id"] for g in gems])
