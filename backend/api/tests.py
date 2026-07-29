"""End-to-end API tests using the same fixture vectors as the Swift
GameKitCoreTests: a straight 1 km route heading north, tracks at known paces.
"""
import io
import json
import random
import uuid
from datetime import timedelta
from unittest import mock

from django.core.management import call_command
from django.test import Client, TestCase, override_settings
from django.utils import timezone

from . import catalog, system_drops, walkability
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
# tests below opt back in with mocked transports. PRESENCE_ASYNC off: the
# background worker's own DB connection can't see the per-thread in-memory
# test database, so the trigger must run inline here.
@override_settings(WALKABILITY_MODE="off", PRESENCE_BOOTSTRAP=False,
                   PRESENCE_ASYNC=False)
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
        # Visible in the master-table geo query (presence trigger off so the
        # map open doesn't top up beyond the command's own drop).
        with self.settings(PRESENCE_DROPS=False):
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
        with self.settings(PRESENCE_FLOOR=1, PRESENCE_FILL_TARGET=1,
                           PRESENCE_HARD_MAX=1):
            out = io.StringIO()
            call_command("stock_gems", lat=37.0, lng=-122.0, stdout=out)
            self.assertIn("Stocked 1 new system gem(s)", out.getvalue())
            self.assertIn("1 standalone active", out.getvalue())
            # Second start: already stocked to the cap, says so, no pile-up.
            again = io.StringIO()
            call_command("stock_gems", lat=37.0, lng=-122.0, stdout=again)
            self.assertIn("No new gems needed", again.getvalue())
        self.assertEqual(GemDrop.objects.filter(route__isnull=True,
                                                placed_by="system").count(), 1)

    def test_presence_trigger_spawns_and_replenishes_gems(self):
        self.seed_popular_route(run_count=5)
        with self.settings(PRESENCE_FLOOR=1, PRESENCE_FILL_TARGET=1,
                           PRESENCE_HARD_MAX=1):
            # Opening the map IS the trigger: the query's own coordinates get
            # topped up (mile below floor → fill to target).
            nearby = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                   "radius_m": 5000}).json()
            self.assertEqual(len(nearby["drops"]), 1)
            first_id = nearby["drops"][0]["id"]
            # Self-limiting: another map open never piles past the area cap.
            again = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                  "radius_m": 5000}).json()
            self.assertEqual([d["id"] for d in again["drops"]], [first_id])
            # Once collected, the next map open replenishes with a NEW gem.
            GemDrop.objects.filter(id=first_id).update(active=False)
            refreshed = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                      "radius_m": 5000}).json()
            self.assertEqual(len(refreshed["drops"]), 1)
            self.assertNotEqual(refreshed["drops"][0]["id"], first_id)

    def test_map_open_without_walkable_geometry_spawns_nothing(self):
        """Fail closed: with no routes and OSM unreachable there is no
        trusted walkable geometry, so the bootstrap places NOTHING —
        empty map beats gems scattered onto private land."""
        with self.settings(PRESENCE_BOOTSTRAP=True), \
             mock.patch("api.walkability.fetch_walkable_ways", return_value=[]):
            drops = self.client.get("/v1/drops", {"lat": 64.2008, "lng": -149.4937,
                                                  "radius_m": 5000}).json()["drops"]
            self.assertEqual(drops, [])

    def test_bootstrap_prefers_real_walkable_ways(self):
        """When OSM answers, bootstrap gems land ON walkable-way geometry,
        not scattered around the user."""
        step = 500 * DEG_PER_M_LAT
        ways = [[(64.2 + i * step, -149.4937), (64.2 + (i + 1) * step, -149.4937)]
                for i in range(8)]
        with self.settings(PRESENCE_BOOTSTRAP=True, PRESENCE_FLOOR=3,
                           PRESENCE_FILL_TARGET=3, PRESENCE_HARD_MAX=5), \
             mock.patch("api.walkability.fetch_walkable_ways", return_value=ways):
            drops = self.client.get("/v1/drops", {"lat": 64.2008, "lng": -149.4937,
                                                  "radius_m": 5000}).json()["drops"]
        self.assertEqual(len(drops), 3)
        for d in drops:                                  # exactly on the street line
            self.assertAlmostEqual(d["lng"], -149.4937, places=5)

    def test_bootstrap_never_places_beyond_near_limit(self):
        """Gems are a walk, not a drive: ways farther than the mile
        (PRESENCE_RADIUS_M) from the map-open point never receive gems,
        whatever the client's read radius."""
        far = 2_000 * DEG_PER_M_LAT
        ways = [[(64.2008 + far, -149.4937), (64.2008 + far * 2, -149.4937)]]
        with self.settings(PRESENCE_BOOTSTRAP=True, PRESENCE_FLOOR=3,
                           PRESENCE_FILL_TARGET=3, PRESENCE_HARD_MAX=5), \
             mock.patch("api.walkability.fetch_walkable_ways", return_value=ways):
            drops = self.client.get("/v1/drops", {"lat": 64.2008, "lng": -149.4937,
                                                  "radius_m": 5000}).json()["drops"]
        self.assertEqual(drops, [])

    def test_daily_rotation_respawns_system_gems_elsewhere(self):
        """Uncollected system gems expire after their spawn day: the next
        map open frees their slots and restocks fresh, so the world never
        repeats yesterday's layout. Player-placed drops are exempt."""
        self.seed_popular_route(run_count=5)
        with self.settings(PRESENCE_FLOOR=1, PRESENCE_FILL_TARGET=1,
                           PRESENCE_HARD_MAX=1):
            first = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                  "radius_m": 5000}).json()["drops"]
            self.assertEqual(len(first), 1)
            yesterday = timezone.now() - timedelta(days=1)
            GemDrop.objects.update(created_at=yesterday)
            player = GemDrop.objects.create(
                route=None, dropped_by=None,
                gem_id=catalog.gem_of("common")["id"], rarity="common",
                lat=37.004, lng=-122.0, position_along_route_m=0,
                respawn_rule="one_time", placed_by="creator",
                created_at=yesterday)
            refreshed = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                      "radius_m": 5000}).json()["drops"]
        ids = {d["id"] for d in refreshed}
        self.assertNotIn(first[0]["id"], ids)          # yesterday's spot freed
        self.assertIn(str(player.id), ids)             # player drop survives
        self.assertEqual(
            sum(1 for d in refreshed if d["placed_by"] == "system"), 1,
            "rotation should restock the freed slot with a fresh gem")

    # ── Per-mile contract (docs/14 §2.1) ─────────────────────────────────

    @staticmethod
    def grid_ways(lat, lng, lines=3):
        """A synthetic sidewalk grid: `lines` parallel 3 km vertical ways
        centered on the open point — ample capacity for fill tests."""
        step = 500 * DEG_PER_M_LAT
        spacing_lng = 300 / (111_320 * 0.55)     # ~300 m apart at lat 64
        ways = []
        for j in range(lines):
            offset = (j - lines // 2) * spacing_lng
            ways.append([(lat - 3 * step + i * step, lng + offset)
                         for i in range(7)])
        return ways

    @staticmethod
    def prefill_system(lat, lng, count, spacing_m=150):
        """Spaced active system gems marching north from the open point."""
        made = []
        for i in range(count):
            made.append(GemDrop.objects.create(
                route=None, dropped_by=None,
                gem_id=catalog.gem_of("common")["id"], rarity="common",
                lat=lat + i * spacing_m * DEG_PER_M_LAT, lng=lng,
                position_along_route_m=0, respawn_rule="one_time",
                placed_by="system"))
        return made

    def test_floor_triggers_restock_and_band_does_not(self):
        """Below PRESENCE_FLOOR a map open restocks to FILL_TARGET; at or
        above the floor the mile is left alone (someone else's gems count
        as stock — the shared-world band)."""
        lat, lng = 64.2008, -149.4937
        with self.settings(PRESENCE_BOOTSTRAP=True, PRESENCE_FLOOR=3,
                           PRESENCE_FILL_TARGET=5, PRESENCE_HARD_MAX=8), \
             mock.patch("api.walkability.fetch_walkable_ways",
                        return_value=self.grid_ways(lat, lng)):
            self.prefill_system(lat, lng, 2)
            made = system_drops.top_up_area(lat, lng, rng=random.Random(7))
            self.assertEqual(made, 3)                    # 2 → fill to 5
            self.assertEqual(system_drops.mile_count(lat, lng), 5)
            # At the floor (and anywhere in the band): no action.
            self.assertEqual(
                system_drops.top_up_area(lat, lng, rng=random.Random(8)), 0)
            self.assertEqual(system_drops.mile_count(lat, lng), 5)

    def test_hard_cap_holds_when_neighbors_already_stocked(self):
        """The cap is re-checked inside every guarded insert: a fill pass
        that starts legitimately still stops the moment the mile reaches
        PRESENCE_HARD_MAX."""
        lat, lng = 64.2008, -149.4937
        with self.settings(PRESENCE_BOOTSTRAP=True, PRESENCE_FLOOR=6,
                           PRESENCE_FILL_TARGET=8, PRESENCE_HARD_MAX=6), \
             mock.patch("api.walkability.fetch_walkable_ways",
                        return_value=self.grid_ways(lat, lng)):
            self.prefill_system(lat, lng, 5)
            made = system_drops.top_up_area(lat, lng, rng=random.Random(7))
            self.assertLessEqual(made, 1)
            self.assertLessEqual(system_drops.mile_count(lat, lng), 6)

    def test_overlapping_top_ups_respect_every_mile(self):
        """Two map opens ~800 m apart, both stocking: every mile — each
        open point's and the midpoint's — stays at or under the hard max,
        because each insert freshly counts both the requester's and the
        candidate's mile."""
        lat, lng = 64.2008, -149.4937
        lat2 = lat + 800 * DEG_PER_M_LAT
        mid = (lat + lat2) / 2
        with self.settings(PRESENCE_BOOTSTRAP=True, PRESENCE_FLOOR=5,
                           PRESENCE_FILL_TARGET=5, PRESENCE_HARD_MAX=5), \
             mock.patch("api.walkability.fetch_walkable_ways",
                        side_effect=lambda la, ln, *a, **k:
                        self.grid_ways(la, ln)):
            system_drops.top_up_area(lat, lng, rng=random.Random(1))
            system_drops.top_up_area(lat2, lng, rng=random.Random(2))
        for point_lat in (lat, lat2, mid):
            self.assertLessEqual(
                system_drops.mile_count(point_lat, lng), 5,
                f"mile at lat {point_lat} exceeded the hard max")

    def test_observed_mile_is_trimmed_to_hard_max(self):
        """Read-time enforcement: whatever concurrent neighbors spilled in
        while nobody was looking, opening the map trims YOUR mile back to
        the hard max before restock logic runs."""
        lat, lng = 64.2008, -149.4937
        with self.settings(PRESENCE_FLOOR=2, PRESENCE_FILL_TARGET=3,
                           PRESENCE_HARD_MAX=6), \
             mock.patch("api.walkability.fetch_walkable_ways",
                        return_value=[]):
            self.prefill_system(lat, lng, 9)
            self.assertEqual(system_drops.mile_count(lat, lng), 9)
            system_drops.rotate_and_top_up(lat, lng)
            self.assertEqual(system_drops.mile_count(lat, lng), 6)

    def test_player_drops_do_not_count_toward_system_contract(self):
        """Player wallet drops neither satisfy the floor nor consume the
        system cap — littering can't suppress system stock."""
        lat, lng = 64.2008, -149.4937
        for i in range(3):                     # player drops 500 m east
            GemDrop.objects.create(
                route=None, dropped_by=None,
                gem_id=catalog.gem_of("common")["id"], rarity="common",
                lat=lat + i * 200 * DEG_PER_M_LAT,
                lng=lng + 500 / (111_320 * 0.55),
                position_along_route_m=0, respawn_rule="one_time",
                placed_by="creator")
        self.assertEqual(system_drops.mile_count(lat, lng), 0)
        with self.settings(PRESENCE_BOOTSTRAP=True, PRESENCE_FLOOR=2,
                           PRESENCE_FILL_TARGET=2, PRESENCE_HARD_MAX=4), \
             mock.patch("api.walkability.fetch_walkable_ways",
                        return_value=self.grid_ways(lat, lng)):
            made = system_drops.top_up_area(lat, lng, rng=random.Random(7))
        self.assertEqual(made, 2)
        self.assertEqual(system_drops.mile_count(lat, lng), 2)

    def test_mile_count_is_radial_not_bbox(self):
        """A gem in the bbox corner (~2.2 km away) is outside the mile; a
        gem 1.6 km straight north is inside."""
        lat, lng = 64.2008, -149.4937
        dlat, dlng = system_drops.bbox_deltas(lat, 1609)
        corner = GemDrop.objects.create(
            route=None, dropped_by=None,
            gem_id=catalog.gem_of("common")["id"], rarity="common",
            lat=lat + dlat * 0.97, lng=lng + dlng * 0.97,
            position_along_route_m=0, respawn_rule="one_time",
            placed_by="system")
        self.assertEqual(system_drops.mile_count(lat, lng), 0)
        corner.delete()
        GemDrop.objects.create(
            route=None, dropped_by=None,
            gem_id=catalog.gem_of("common")["id"], rarity="common",
            lat=lat + 1_600 * DEG_PER_M_LAT, lng=lng,
            position_along_route_m=0, respawn_rule="one_time",
            placed_by="system")
        self.assertEqual(system_drops.mile_count(lat, lng), 1)

    def test_rarity_bonus_follows_route_traffic_not_way_class(self):
        """Rarer loot tracks proven foot traffic, not scenery: gems on
        popular routes roll HIGH_TRAFFIC_WEIGHTS, while off-route sidewalk
        fills roll the default mix whatever the OSM way class — the system
        stocks where people already walk instead of luring them onto
        "nicer" trails."""
        route_id = self.seed_popular_route(run_count=5)
        route = Route.objects.get(id=route_id)
        with mock.patch("api.system_drops.create_system_drop") as spawn:
            system_drops.drop_gem_on_route(route, random.Random(1),
                                           near=(37.0, -122.0))
        self.assertEqual(spawn.call_args.kwargs.get("weights"),
                         system_drops.HIGH_TRAFFIC_WEIGHTS)

        step = 500 * DEG_PER_M_LAT
        trail = [[(37.0 + i * step, -122.0), (37.0 + (i + 1) * step, -122.0)]
                 for i in range(4)]
        with mock.patch("api.system_drops.create_system_drop") as spawn, \
             mock.patch("api.walkability.fetch_walkable_ways",
                        return_value=trail):
            made = system_drops.drop_on_walkable_ways(37.0, -122.0, 1,
                                                      random.Random(1))
        self.assertEqual(made, 1)
        self.assertIsNone(spawn.call_args.kwargs.get("weights"))

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
        """Demo routes chain real walkable-way geometry into open-ended
        one-way paths starting at the given coordinate — no loops."""
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
            # Open-ended: ends well away from where it started (no loop).
            self.assertGreater(abs(coords[-1][0] - coords[0][0]) * 111_320, 100)
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

    def test_my_runs_lists_completed_history(self):
        gem = self.gem("common", 500)
        route = self.publish_route(gems=[gem]).json()
        self.complete(route["id"], track(3.0), [gem["id"]])
        runs = self.client.get(
            "/v1/runs/mine",
            HTTP_AUTHORIZATION=f"Bearer {self.token}").json()["runs"]
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["route_name"], "Test Route")
        self.assertGreaterEqual(runs[0]["distance_m"], 990)   # sampled track
        self.assertGreater(runs[0]["xp_earned"], 0)

    def test_friends_search_add_weekly_rank_and_remove(self):
        """The whole friends loop: search by handle → follow → they appear
        on the weekly board with their stats → swipe-remove deletes only my
        follow row."""
        rival_token = self.client.post(
            "/v1/auth/apple", data=json.dumps({"handle": "gemhunter"}),
            content_type="application/json").json()["token"]
        # The rival completes a run this week and collects a gem, so
        # their weekly XP is non-zero (runs without gems score 0).
        gem = self.gem("common", 500)
        route = self.publish_route(gems=[gem]).json()
        self.client.post(
            f"/v1/runs/{route['id']}/complete",
            data=json.dumps({"idempotency_key": str(uuid.uuid4()),
                             "started_at": timezone.now().strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "track": track(3.0),
                             "claimed_collections": [gem["id"]]}),
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {rival_token}")

        found = self.client.get(
            "/v1/players", {"search": "GEMH"},
            HTTP_AUTHORIZATION=f"Bearer {self.token}").json()["players"]
        self.assertEqual([p["handle"] for p in found], ["gemhunter"])

        added = self.client.post(
            "/v1/friends", data=json.dumps({"profile_id": found[0]["id"]}),
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {self.token}").json()["friends"]
        self.assertEqual([f["handle"] for f in added if not f["is_me"]],
                         ["gemhunter"])
        rival_row = next(f for f in added if f["handle"] == "gemhunter")
        self.assertGreater(rival_row["weekly_xp"], 0)
        self.assertEqual(rival_row["weekly_runs"], 1)
        # Rival out-ran me this week → ranked above my row.
        self.assertEqual(added[0]["handle"], "gemhunter")

        self.client.delete(
            f"/v1/friends/{found[0]['id']}",
            HTTP_AUTHORIZATION=f"Bearer {self.token}")
        after = self.client.get(
            "/v1/friends",
            HTTP_AUTHORIZATION=f"Bearer {self.token}").json()["friends"]
        self.assertEqual([f["is_me"] for f in after], [True])

    def test_dev_fallback_survives_duplicate_profiles(self):
        """The app fires routes+drops concurrently; a get_or_create race once
        left two dev-fallback profiles and every request 500'd. Unauthed
        requests must keep working with duplicates present."""
        from .models import Profile
        for _ in range(2):
            Profile.objects.create(handle="runner", auth_provider="guest",
                                   external_user_id="dev-fallback")
        response = self.client.get("/v1/routes", {"lat": 37.0, "lng": -122.0,
                                                  "radius_m": 5000})
        self.assertEqual(response.status_code, 200)
        drops = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                              "radius_m": 5000})
        self.assertEqual(drops.status_code, 200)

    def test_catalog_matches_client_uuids(self):
        gems = self.client.get("/v1/gems/catalog").json()["gems"]
        self.assertEqual(len(gems), 26)
        ids = [g["id"] for g in gems]
        # Swift GemCatalog uses UUID(uuid: (0,...,0,10)) for Trail Quartz.
        self.assertIn("00000000-0000-0000-0000-00000000000a", ids)
        # Ancient Relics start at int 40 (0x28 = Bone).
        self.assertIn("00000000-0000-0000-0000-000000000028", ids)
