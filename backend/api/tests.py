"""End-to-end API tests using the same fixture vectors as the Swift
GameKitCoreTests: a straight 1 km route heading north, tracks at known paces.
"""
import io
import json
import math
import random
import uuid
from datetime import timedelta
from unittest import mock

from django.core.management import call_command
from django.test import Client, TestCase, override_settings
from django.utils import timezone

from . import catalog, system_drops, walkability
from .geometry import RouteGeometry, polyline_decode, polyline_encode
from .models import ClaimAttempt, GemDrop, Profile, Route, Token

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
# test database, so the trigger must run inline here. AUTH_MODE insecure_dev
# preserves the pre-strict sign-in ergonomics these behavioural tests assume
# (unauthenticated map reads, id-claimed accounts); the strict path has its
# own AuthStrictTests below. THROTTLE off so the shared per-process counter
# doesn't 429 the many sign-ins across the suite — ThrottleTests turns it on.
@override_settings(WALKABILITY_MODE="off", PRESENCE_BOOTSTRAP=False,
                   PRESENCE_ASYNC=False, AUTH_MODE="insecure_dev",
                   THROTTLE_ENABLED=False)
class ApiTests(TestCase):
    def setUp(self):
        # Hermetic Overpass: the placement fetches return no geometry by
        # default (→ trusted route points, exactly the Overpass-down
        # fallback). Tests that need geometry set the mocks or patch
        # locally; the real parser stays reachable via real_fetch_placement.
        self.real_fetch_placement = walkability.fetch_placement_data
        # Delegates to fetch_walkable_ways (below) with no no-go rings, so
        # every test that stubs grid ways feeds the placement path too.
        placement_patcher = mock.patch(
            "api.walkability.fetch_placement_data",
            side_effect=lambda lat, lng, radius_m, deadline=None:
                (walkability.fetch_walkable_ways(lat, lng, radius_m), []))
        self.mock_placement = placement_patcher.start()
        self.addCleanup(placement_patcher.stop)
        ways_patcher = mock.patch("api.walkability.fetch_walkable_ways",
                                  return_value=[])
        self.mock_ways = ways_patcher.start()
        self.addCleanup(ways_patcher.stop)
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
        runs = [i for i in stash["items"] if i["source"] == "run"]
        self.assertEqual(len(runs), 1)   # gift items aside, the claim is single

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

    @staticmethod
    def _teleport_track():
        """Legit average pace and full route coverage, but a sustained
        >TELEPORT_SPEED burst — isolates the `teleport` flag from pace and
        coverage so we can assert teleport ALONE blocks the economy."""
        speeds = [3.0] * 40 + [10.0] * 6 + [3.0] * 300   # m/s per 1 s step
        samples, dist, t = [], 0.0, 0.0
        for sp in speeds:
            samples.append({"t": t, "lat": 37.0 + dist * DEG_PER_M_LAT,
                            "lng": -122.0, "horizontal_accuracy": 5, "speed": sp})
            dist += sp
            t += 1.0
            if dist >= 1000:
                break
        return samples

    def test_teleport_run_earns_nothing(self):
        """H2: a sustained-teleport track is invalid — no gems, no XP, no
        streak — even though its pace and coverage look fine."""
        gem = self.gem("common", 300)
        route = self.publish_route(gems=[gem]).json()
        verdict = self.complete(route["id"], self._teleport_track(),
                                [gem["id"]]).json()
        self.assertEqual(verdict["status"], "invalid")
        self.assertEqual(verdict["awarded_drops"], [])
        self.assertEqual(verdict["xp_earned"], 0)
        self.assertFalse(verdict["streak_extended"])
        self.assertIn(gem["id"], verdict["revoked"])

    def test_flagged_run_awards_gems_but_is_off_the_weekly_board(self):
        """H2: a coverage-flagged run still awards the gem the track actually
        reached (proximity is enforced independently), but its XP never ranks
        on the weekly board."""
        gem = self.gem("common", 100)                     # early — reachable
        route = self.publish_route(gems=[gem]).json()
        # Cover ~80% of the route → coverage flag (≥0.5, so `flagged`).
        verdict = self.complete(route["id"], track(3.0, length_m=800),
                                [gem["id"]]).json()
        self.assertEqual(verdict["status"], "flagged")
        self.assertEqual([d["id"] for d in verdict["awarded_drops"]], [gem["id"]])
        self.assertGreater(verdict["xp_earned"], 0)       # earned…
        board = self.client.get("/v1/leaderboards/local").json()
        self.assertEqual(board["entries"], [])            # …but unranked

    def test_utc_offset_persists_from_run_payload(self):
        route = self.publish_route().json()
        self.post(f"/v1/runs/{route['id']}/complete", {
            "idempotency_key": str(uuid.uuid4()), "started_at": "2026-07-23T10:00:00Z",
            "track": track(3.0, length_m=1100), "claimed_collections": [],
            "utc_offset_minutes": -420}, auth=True)
        profile = Profile.objects.get(id=self.client.get(
            "/v1/users/me", HTTP_AUTHORIZATION=f"Bearer {self.token}").json()["id"])
        self.assertEqual(profile.utc_offset_minutes, -420)

    def test_daily_respawn_uses_the_runners_local_day(self):
        """M3: the daily respawn boundary is the runner's local midnight, not
        UTC's. A gem grabbed at 01:00 UTC by a UTC-8 runner (17:00 their
        previous day) is NOT re-claimable at 09:00 UTC the same day (01:00
        their time) — both are the same local day."""
        from .models import Profile as P
        from . import views
        prof = P.objects.create(handle="pdt", auth_provider="guest",
                                external_user_id="x", utc_offset_minutes=-480)
        drop = GemDrop.objects.create(
            route=None, gem_id=catalog.gem_of("common")["id"], rarity="common",
            lat=37.0, lng=-122.0, position_along_route_m=0,
            respawn_rule="daily", placed_by="system")
        from datetime import datetime, timezone as tz
        # Collect at 2026-07-22 20:00 UTC = 12:00 local (local day 07-22).
        t0 = datetime(2026, 7, 22, 20, 0, tzinfo=tz.utc)
        self.assertTrue(views.claim_respawn(prof, drop, t0))
        from .models import StashItem
        StashItem.objects.create(profile=prof, gem_id=drop.gem_id, gem_drop=drop,
                                 collected_at=t0, is_first_find=False)
        # 2026-07-23 02:00 UTC = 18:00 local — a NEW UTC day but the SAME local
        # day (07-22), so it's still blocked. UTC-date logic would wrongly
        # allow it; this is the whole point of the local frame.
        t_same_local = datetime(2026, 7, 23, 2, 0, tzinfo=tz.utc)
        self.assertFalse(views.claim_respawn(prof, drop, t_same_local))
        # 2026-07-23 09:00 UTC = 01:00 local — the runner's next local day →
        # claimable again.
        t_next_local = datetime(2026, 7, 23, 9, 0, tzinfo=tz.utc)
        self.assertTrue(views.claim_respawn(prof, drop, t_next_local))

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

    def test_tokens_and_provider_ids_are_hashed_at_rest(self):
        import hashlib
        # The raw bearer token the client holds never appears in the DB —
        # only its SHA-256 digest does, and auth still works through it.
        raw = self.token
        self.assertFalse(Token.objects.filter(key=raw).exists())
        expected = hashlib.sha256(raw.encode()).hexdigest()
        self.assertTrue(Token.objects.filter(key=expected).exists())
        me = self.client.get("/v1/users/me",
                             HTTP_AUTHORIZATION=f"Bearer {raw}")
        self.assertEqual(me.status_code, 200)
        # Provider IDs are hashed too, and repeat sign-ins still map to
        # the same profile via the hashed lookup.
        first = self.client.post(
            "/v1/auth/apple",
            data=json.dumps({"handle": "hasher", "external_user_id": "apple-123"}),
            content_type="application/json").json()
        again = self.client.post(
            "/v1/auth/apple",
            data=json.dumps({"handle": "hasher", "external_user_id": "apple-123"}),
            content_type="application/json").json()
        self.assertEqual(first["profile"]["id"], again["profile"]["id"])
        self.assertFalse(Profile.objects.filter(
            external_user_id="apple-123").exists())

    def test_username_change_checks_availability(self):
        self.client.post("/v1/auth/apple", data=json.dumps({"handle": "taken_name"}),
                         content_type="application/json")
        check = self.client.get("/v1/handles/check", {"handle": "taken_name"},
                                HTTP_AUTHORIZATION=f"Bearer {self.token}").json()
        self.assertFalse(check["available"])
        check = self.client.get("/v1/handles/check", {"handle": "fresh_name"},
                                HTTP_AUTHORIZATION=f"Bearer {self.token}").json()
        self.assertTrue(check["available"])
        self.assertFalse(self.client.get(
            "/v1/handles/check", {"handle": "ab"}).json()["available"])  # too short
        denied = self.client.patch(
            "/v1/users/me", data=json.dumps({"handle": "taken_name"}),
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {self.token}")
        self.assertEqual(denied.status_code, 409)
        self.assertEqual(denied.json()["code"], "handle_taken")
        ok = self.client.patch(
            "/v1/users/me", data=json.dumps({"handle": "fresh_name"}),
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {self.token}")
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.json()["handle"], "fresh_name")

    def test_drops_response_carries_stocking_flag(self):
        # Inline mode (tests) answers pre-stocked, so the flag is False —
        # but the key must always be present for the client.
        body = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                             "radius_m": 1000}).json()
        self.assertIn("stocking", body)
        self.assertFalse(body["stocking"])

    def test_drops_read_is_never_cacheable(self):
        """iOS URLSession may heuristically cache header-less GETs; a
        replayed stale answer is a permanently wrong map, so the read
        says no-store explicitly."""
        response = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                 "radius_m": 1000})
        self.assertEqual(response["Cache-Control"], "no-store")

    def test_pending_restock_covers_sub_floor_and_stale_rotation(self):
        with self.settings(PRESENCE_FLOOR=2, PRESENCE_FILL_TARGET=3,
                           PRESENCE_HARD_MAX=5):
            # Sub-floor mile → top-up incoming.
            self.assertTrue(system_drops.has_pending_restock(37.0, -122.0, 1))
            # At-floor mile, all gems fresh → nothing pending.
            self.assertFalse(system_drops.has_pending_restock(37.0, -122.0, 2))
            # Yesterday's system gem still active → rotation incoming.
            GemDrop.objects.create(
                route=None, gem_id=catalog.gem_of("common")["id"],
                rarity="common", lat=37.0, lng=-122.0,
                position_along_route_m=0, respawn_rule="one_time",
                placed_by="system",
                created_at=timezone.now() - timedelta(days=1))
            self.assertTrue(system_drops.has_pending_restock(37.0, -122.0, 2))

    def test_routes_list_query_count_is_flat(self):
        for _ in range(3):
            self.assertEqual(self.publish_route().status_code, 200)
        # Token + routes(+creators) + drops prefetch + viewer stash = 4,
        # independent of how many routes the page holds.
        with self.assertNumQueries(4):
            self.client.get("/v1/routes", {"lat": 37.0, "lng": -122.0,
                                           "radius_m": 8000},
                            HTTP_AUTHORIZATION=f"Bearer {self.token}")

    # ---- stash, welcome gift & standalone drops

    def test_welcome_gift_stocks_a_new_stash(self):
        stash = self.client.get("/v1/stash",
                                HTTP_AUTHORIZATION=f"Bearer {self.token}").json()
        gifts = [i for i in stash["items"] if i["source"] == "gift"]
        self.assertEqual(len(gifts), 6)          # 3 common + 2 uncommon + 1 rare
        rarities = sorted(catalog.entry_for(uuid.UUID(i["gem_id"]))["rarity"]
                          for i in gifts)
        self.assertEqual(rarities, ["common"] * 3 + ["rare"] + ["uncommon"] * 2)
        self.assertTrue(all(not i["dropped"] for i in gifts))

    def test_drop_spends_a_stash_gem_and_keeps_the_record(self):
        gem_id = str(catalog.gem_of("common")["id"])
        # The welcome gift holds exactly one copy of this gem: first drop OK.
        ok = self.post("/v1/drops", {"gem_id": gem_id, "lat": 37.0, "lng": -122.0},
                       auth=True)
        self.assertEqual(ok.status_code, 200)
        nearby = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                               "radius_m": 1000}).json()
        self.assertEqual(len(nearby["drops"]), 1)
        # The stash row survives as the collection record, marked dropped.
        stash = self.client.get("/v1/stash",
                                HTTP_AUTHORIZATION=f"Bearer {self.token}").json()
        mine = [i for i in stash["items"] if i["gem_id"] == gem_id]
        self.assertEqual(len(mine), 1)
        self.assertTrue(mine[0]["dropped"])
        # No second copy → a repeat drop is refused.
        again = self.post("/v1/drops", {"gem_id": gem_id, "lat": 37.0, "lng": -122.0},
                          auth=True)
        self.assertEqual(again.status_code, 422)
        self.assertEqual(again.json()["code"], "not_in_stash")

    def test_collect_drop_is_one_time_and_never_own(self):
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

    def test_drop_gems_skips_points_off_the_pedestrian_network(self):
        """A route stretch with NO sidewalk/trail within PLACEMENT_SNAP_MAX_M
        spawns nothing — the strict network is the placement authority, not
        a fuzzy any-road-nearby check. (This is the private-property guard:
        a route along a bare residential street gets no gems.)"""
        self.seed_popular_route()
        offset = 200 / (111_320 * math.cos(math.radians(37.0)))   # 200 m east
        self.mock_ways.return_value = [[(37.0, -122.0 + offset),
                                        (37.02, -122.0 + offset)]]
        call_command("drop_gems", seed=7, stdout=io.StringIO())
        self.assertEqual(
            GemDrop.objects.filter(route__isnull=True, placed_by="system").count(), 0)

    def test_route_gems_snap_onto_the_pedestrian_network(self):
        """Routes legally follow road centerlines; gems must not. A sidewalk
        15 m east of the route pulls every placement onto itself."""
        route = Route.objects.get(id=self.seed_popular_route())
        offset = 15 / (111_320 * math.cos(math.radians(37.0)))
        net = system_drops.PedestrianNet(
            [[(37.0, -122.0 + offset), (37.01, -122.0 + offset)]])
        drop = system_drops.drop_gem_on_route(route, random.Random(1),
                                              net=net, near=(37.0, -122.0))
        self.assertIsNotNone(drop)
        self.assertAlmostEqual(drop.lng, -122.0 + offset, places=6)

    def test_system_drops_trust_route_snap_when_network_unanswerable(self):
        """Route candidates come from walking-snapped polylines, so an
        unreachable Overpass (no pedestrian network at all — the setUp
        default here) must NOT block spawning: the raw route point is
        trusted, and the next daily rotation re-places it snapped. A
        reachable network with nothing in snap range DOES veto (test
        above)."""
        self.seed_popular_route()
        system = GemDrop.objects.filter(route__isnull=True, placed_by="system")
        with self.settings(WALKABILITY_MODE="overpass"):
            with mock.patch("api.walkability.is_walkable", return_value=None):
                call_command("drop_gems", seed=7, stdout=io.StringIO())
                self.assertEqual(system.count(), 1)          # trusted, spawns
                ok = self.post("/v1/drops",                  # user drop: fail open
                               {"gem_id": str(catalog.gem_of("common")["id"]),
                                "lat": 37.0, "lng": -122.0}, auth=True)
                self.assertEqual(ok.status_code, 200)

    def test_player_drop_check_uses_strict_pedestrian_list(self):
        with mock.patch("api.views.walkability.is_walkable",
                        return_value=None) as check:
            ok = self.post("/v1/drops",
                           {"gem_id": str(catalog.gem_of("common")["id"]),
                            "lat": 37.0, "lng": -122.0}, auth=True)
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(check.call_args.kwargs.get("highways"),
                         walkability.PEDESTRIAN_HIGHWAYS)

    def test_stocking_pass_fetches_the_placement_network_once(self):
        self.mock_placement.reset_mock()
        with self.settings(PRESENCE_FLOOR=1, PRESENCE_FILL_TARGET=1,
                           PRESENCE_HARD_MAX=5, PRESENCE_BOOTSTRAP=True):
            system_drops.top_up_area(37.0, -122.0, random.Random(1))
        self.assertEqual(self.mock_placement.call_count, 1)
        self.assertEqual(self.mock_placement.call_args.args[2], 1609)

    def test_gems_never_spawn_inside_no_go_grounds(self):
        """A mapped footpath through a golf course / gated grounds is real
        geometry, but the polygon vetoes it — in BOTH tiers."""
        route = Route.objects.get(id=self.seed_popular_route())
        offset = 5 / (111_320 * math.cos(math.radians(37.0)))
        sidewalk = [[(36.999, -122.0 + offset), (37.011, -122.0 + offset)]]
        # A no-go ring swallowing the whole route + sidewalk.
        ring = [(36.998, -122.001), (37.012, -122.001),
                (37.012, -121.999), (36.998, -121.999), (36.998, -122.001)]
        net = system_drops.PedestrianNet(sidewalk)
        zones = walkability.NoGoZones([ring])
        drop = system_drops.drop_gem_on_route(route, random.Random(1),
                                              net=net, no_go=zones,
                                              near=(37.0, -122.0))
        self.assertIsNone(drop)
        made = system_drops.drop_on_walkable_ways(
            37.0, -122.0, 1, random.Random(1), ways=sidewalk, no_go=zones)
        self.assertEqual(made, 0)
        # Same geometry without the ring: both tiers place happily.
        empty = walkability.NoGoZones([])
        self.assertIsNotNone(system_drops.drop_gem_on_route(
            route, random.Random(1), net=net, no_go=empty,
            near=(37.0, -122.0)))
        self.assertEqual(system_drops.drop_on_walkable_ways(
            37.0, -122.0, 1, random.Random(2), ways=sidewalk,
            no_go=empty), 1)

    def test_placement_data_splits_network_from_no_go_rings(self):
        payload = {"elements": [
            {"type": "way", "tags": {"highway": "footway"},
             "geometry": [{"lat": 37.0, "lon": -122.0},
                          {"lat": 37.001, "lon": -122.0}]},
            {"type": "way", "tags": {"leisure": "golf_course"},
             "geometry": [{"lat": 37.0, "lon": -122.0},
                          {"lat": 37.001, "lon": -122.0},
                          {"lat": 37.001, "lon": -121.999},
                          {"lat": 37.0, "lon": -121.999},
                          {"lat": 37.0, "lon": -122.0}]},
            # Private footpath: excluded from the network, not closed, so
            # it lands in neither bucket.
            {"type": "way", "tags": {"highway": "footway", "access": "private"},
             "geometry": [{"lat": 37.0, "lon": -122.0},
                          {"lat": 37.002, "lon": -122.0}]},
        ]}
        with mock.patch("api.walkability.query_overpass",
                        return_value=payload):
            ways, rings = self.real_fetch_placement(37.0, -122.0, 1609)
        self.assertEqual(len(ways), 1)
        self.assertEqual(len(rings), 1)
        zones = walkability.NoGoZones(rings)
        self.assertTrue(zones.contains(37.0005, -121.9995))
        self.assertFalse(zones.contains(37.0005, -122.002))

    def test_point_check_vetoes_inside_no_go_area(self):
        with self.settings(WALKABILITY_MODE="overpass"):
            inside = {"elements": [{"type": "way", "id": 1},
                                   {"type": "area", "id": 2}]}
            with mock.patch("api.walkability.query_overpass",
                            return_value=inside):
                self.assertIs(walkability.is_walkable(37.0, -122.0), False)
            clear = {"elements": [{"type": "way", "id": 1}]}
            with mock.patch("api.walkability.query_overpass",
                            return_value=clear):
                self.assertIs(walkability.is_walkable(37.0, -122.0), True)

    def test_drop_rejected_on_unwalkable_coordinate(self):
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

    def test_rotation_postponed_when_overpass_unreachable(self):
        """An Overpass outage must never empty a stocked mile: with no
        placement geometry in hand, yesterday's gems stay on the map (and
        the answer flags the area as still due to change); the next open
        WITH an answer rotates them out as usual."""
        self.seed_popular_route(run_count=5)
        with self.settings(PRESENCE_FLOOR=1, PRESENCE_FILL_TARGET=1,
                           PRESENCE_HARD_MAX=1):
            first = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                  "radius_m": 5000}).json()["drops"]
            self.assertEqual(len(first), 1)
            GemDrop.objects.update(created_at=timezone.now() - timedelta(days=1))
            with mock.patch("api.walkability.fetch_placement_data",
                            return_value=None):
                held = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                     "radius_m": 5000}).json()
            self.assertEqual([d["id"] for d in held["drops"]],
                             [first[0]["id"]])         # kept, not expired
            self.assertTrue(held["stocking"])          # still due to change
            # Overpass answers again (the suite's default fetch): the
            # postponed rotation runs — slot freed, restocked fresh.
            refreshed = self.client.get("/v1/drops", {"lat": 37.0, "lng": -122.0,
                                                      "radius_m": 5000}).json()["drops"]
            self.assertEqual(len(refreshed), 1)
            self.assertNotEqual(refreshed[0]["id"], first[0]["id"])

    def test_failed_bootstrap_reports_stocking_true(self):
        """A cold mile whose bootstrap got NO answer from Overpass says
        `stocking: true` so the app looks again shortly, instead of
        settling on "No gems here". An answered-empty area (genuinely no
        pedestrian ways) stays fail-closed with `stocking: false`."""
        with self.settings(PRESENCE_BOOTSTRAP=True):
            with mock.patch("api.walkability.fetch_placement_data",
                            return_value=None):
                out = self.client.get("/v1/drops", {"lat": 64.2008,
                                                    "lng": -149.4937,
                                                    "radius_m": 5000}).json()
            self.assertEqual(out["drops"], [])
            self.assertTrue(out["stocking"])
            settled = self.client.get("/v1/drops", {"lat": 64.2008,
                                                    "lng": -149.4937,
                                                    "radius_m": 5000}).json()
            self.assertEqual(settled["drops"], [])
            self.assertFalse(settled["stocking"])

    def test_dev_scatter_unblocks_offline_dev(self):
        """PRESENCE_DEV_SCATTER (dev only, default off): with Overpass
        unreachable the pass fills the mile anyway — still spaced, still
        capped, still within the requester's mile. The default-off
        fail-closed path is covered by the bootstrap tests above."""
        lat, lng = 64.2008, -149.4937
        with self.settings(PRESENCE_BOOTSTRAP=True, PRESENCE_FLOOR=3,
                           PRESENCE_FILL_TARGET=3, PRESENCE_HARD_MAX=5,
                           PRESENCE_DEV_SCATTER=True), \
             mock.patch("api.walkability.fetch_placement_data",
                        return_value=None):
            drops = self.client.get("/v1/drops", {"lat": lat, "lng": lng,
                                                  "radius_m": 5000}).json()["drops"]
        self.assertEqual(len(drops), 3)
        for d in drops:                               # inside the mile
            dist = math.hypot((d["lat"] - lat) * 111_320,
                              (d["lng"] - lng) * 111_320
                              * math.cos(math.radians(lat)))
            self.assertLessEqual(dist, 1609)

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

    # ------------------------------------- logging & exception handling

    def test_presence_trigger_failure_never_breaks_map_read_and_is_logged(self):
        """The map read survives a stocking crash — but never silently:
        the swallow at views.drops used to hide the whole pipeline."""
        with mock.patch("api.system_drops.presence_trigger",
                        side_effect=RuntimeError("stocking exploded")):
            with self.assertLogs("api.views", level="ERROR") as logs:
                response = self.client.get(
                    "/v1/drops", {"lat": 37.0, "lng": -122.0, "radius_m": 5000})
        self.assertEqual(response.status_code, 200)
        self.assertIs(response.json()["stocking"], False)
        self.assertTrue(any("presence trigger failed" in line
                            for line in logs.output))

    def test_unhandled_view_error_is_problem_json_500_with_request_id(self):
        """An uncaught exception must reach the client as the problem+json
        shape HTTPGemRunAPI decodes — with a request id that also appears
        in the server-side traceback log (works with DEBUG=False too)."""
        self.publish_route()
        route_id = Route.objects.get().id
        with mock.patch("api.validation.validate",
                        side_effect=RuntimeError("boom")):
            with self.assertLogs("api.request", level="ERROR") as logs:
                response = self.complete(route_id, track(3.0), [])
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response["Content-Type"], "application/problem+json")
        body = response.json()
        self.assertEqual(body["code"], "internal")
        request_id = response["X-Request-ID"]
        self.assertIn(request_id, body["detail"])
        self.assertTrue(any(request_id in line for line in logs.output))

    def test_every_request_logs_one_line_with_request_id(self):
        with self.assertLogs("api.request", level="INFO") as logs:
            response = self.client.get("/v1/gems/catalog")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.has_header("X-Request-ID"))
        line = "\n".join(logs.output)
        self.assertIn("GET /v1/gems/catalog", line)
        self.assertIn(response["X-Request-ID"], line)

    def test_v1_405_and_unknown_path_are_problem_json(self):
        """@require_http_methods 405s and resolver 404s are text/html out
        of the box — under /v1/ both must keep the error contract."""
        denied = self.client.delete("/v1/handles/check")
        self.assertEqual(denied.status_code, 405)
        self.assertEqual(denied["Content-Type"], "application/problem+json")
        self.assertEqual(denied.json()["code"], "method_not_allowed")
        missing = self.client.get("/v1/definitely-not-a-thing")
        self.assertEqual(missing.status_code, 404)
        self.assertEqual(missing["Content-Type"], "application/problem+json")
        self.assertEqual(missing.json()["code"], "not_found")

    def test_malformed_publish_payload_is_422_and_leaves_no_route(self):
        bad = self.gem("common", 400)
        bad["gem_id"] = "not-a-uuid"
        with self.assertLogs("api.views", level="WARNING"):
            response = self.publish_route(gems=[bad])
        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["code"], "malformed")
        # Atomic: the half-published route rolled back with its drops.
        self.assertEqual(Route.objects.count(), 0)
        self.assertEqual(GemDrop.objects.count(), 0)

    def test_malformed_collect_ids_are_400_not_500(self):
        response = self.post("/v1/drops/collect",
                             {"claimed": ["nope"], "track": []}, auth=True)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["code"], "malformed")

    def test_garbage_track_samples_are_cleaned_not_500(self):
        """One malformed sample in a long track must not roll back the
        whole settlement — clean_track drops it and the run still counts."""
        self.publish_route()
        route_id = Route.objects.get().id
        samples = track(3.0) + [{"t": None}, {"lat": 1.0}, "junk", 42]
        response = self.complete(route_id, samples, [])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "valid")

    def test_truncated_overpass_body_is_unreachable_not_a_crash(self):
        """http.client.IncompleteRead is not an OSError — it used to escape
        the mirror loop and crash stock_gems (killing run.sh's launch)."""
        import http.client
        walkability._down_until = 0.0
        with override_settings(WALKABILITY_MODE="overpass"):
            with mock.patch("api.walkability.urllib.request.urlopen",
                            side_effect=http.client.IncompleteRead(b"")):
                with self.assertLogs("api.walkability", level="WARNING"):
                    verdict = walkability.is_walkable(37.0, -122.0)
        walkability._down_until = 0.0
        self.assertIsNone(verdict)

    def test_stock_gems_command_survives_a_stocking_failure(self):
        out = io.StringIO()
        with mock.patch("api.system_drops.top_up_area",
                        side_effect=RuntimeError("placement bug")):
            call_command("stock_gems", stdout=out)
        self.assertIn("Stocking failed", out.getvalue())

    # ------------------------------------------------- unique accounts

    def test_same_external_id_is_the_same_account(self):
        """Unique accounts: the hashed external id is the identity. The same
        id signing in twice lands on ONE profile; a different id gets its
        own — and the raw id never appears in the database."""
        first = self.post("/v1/auth/apple",
                          {"handle": "ali", "external_user_id": "apple-user-1"})
        again = self.post("/v1/auth/apple",
                          {"handle": "ali", "external_user_id": "apple-user-1"})
        other = self.post("/v1/auth/apple",
                          {"handle": "sam", "external_user_id": "apple-user-2"})
        self.assertEqual(first.json()["profile"]["id"],
                         again.json()["profile"]["id"])
        self.assertNotEqual(first.json()["profile"]["id"],
                            other.json()["profile"]["id"])
        self.assertFalse(Profile.objects.filter(
            external_user_id="apple-user-1").exists())

    def test_guest_provider_gets_a_stable_unique_account(self):
        first = self.post("/v1/auth/guest",
                          {"handle": "wanderer", "external_user_id": "device-abc"})
        self.assertEqual(first.status_code, 200)
        again = self.post("/v1/auth/guest",
                          {"handle": "wanderer", "external_user_id": "device-abc"})
        self.assertEqual(first.json()["profile"]["id"],
                         again.json()["profile"]["id"])


def _echo_verifier(provider, token):
    """Test identity verifier: the client's identity_token IS the verified
    subject (namespaced by provider). Stands in for real JWKS verification so
    the strict flow is testable without live Apple/Google keys."""
    return f"{provider}:{token}"


# Strict mode is the production auth posture: apple/google require a verified
# identity token; guests use a high-entropy secret; unauthenticated calls fail.
@override_settings(WALKABILITY_MODE="off", PRESENCE_BOOTSTRAP=False,
                   PRESENCE_ASYNC=False, THROTTLE_ENABLED=False,
                   AUTH_MODE="strict", IDENTITY_VERIFIER=_echo_verifier)
class AuthStrictTests(TestCase):
    def setUp(self):
        self.client = Client()

    def post(self, path, payload):
        return self.client.post(path, data=json.dumps(payload),
                                content_type="application/json")

    def test_apple_requires_a_verified_identity_token(self):
        # No identity_token → rejected. A client-claimed external_user_id is
        # NOT accepted as identity in strict mode.
        denied = self.post("/v1/auth/apple",
                           {"handle": "x", "external_user_id": "victim-apple-id"})
        self.assertEqual(denied.status_code, 401)
        self.assertEqual(Profile.objects.count(), 0)

    def test_verified_apple_token_signs_in_and_is_stable(self):
        first = self.post("/v1/auth/apple",
                          {"handle": "ali", "identity_token": "sub-1"})
        self.assertEqual(first.status_code, 200)
        again = self.post("/v1/auth/apple",
                          {"handle": "ali", "identity_token": "sub-1"})
        self.assertEqual(first.json()["profile"]["id"],
                         again.json()["profile"]["id"])
        self.assertEqual(Profile.objects.count(), 1)

    def test_cannot_adopt_another_account_by_claiming_its_external_id(self):
        # The real owner signs in with their verified token…
        owner = self.post("/v1/auth/apple",
                          {"handle": "owner", "identity_token": "sub-owner"}).json()
        owner_id = owner["profile"]["id"]
        # …an attacker who only knows the (hashed) external id but has a
        # DIFFERENT verified token gets their OWN account, never the owner's.
        attacker = self.post("/v1/auth/apple",
                             {"handle": "attacker", "identity_token": "sub-attacker",
                              "external_user_id": "sub-owner"}).json()
        self.assertNotEqual(owner_id, attacker["profile"]["id"])

    def test_guest_needs_a_long_secret_and_is_stable(self):
        secret = "g" * 32
        short = self.post("/v1/auth/guest", {"external_user_id": "tooshort"})
        self.assertEqual(short.status_code, 401)
        a = self.post("/v1/auth/guest", {"external_user_id": secret})
        b = self.post("/v1/auth/guest", {"external_user_id": secret})
        self.assertEqual(a.status_code, 200)
        self.assertEqual(a.json()["profile"]["id"], b.json()["profile"]["id"])
        other = self.post("/v1/auth/guest", {"external_user_id": "h" * 32})
        self.assertNotEqual(a.json()["profile"]["id"],
                            other.json()["profile"]["id"])

    def test_unauthenticated_call_is_rejected_in_strict_mode(self):
        # No shared dev-fallback profile: protected endpoints actually 401.
        self.assertEqual(self.client.get("/v1/stash").status_code, 401)


@override_settings(WALKABILITY_MODE="off", PRESENCE_BOOTSTRAP=False,
                   PRESENCE_ASYNC=False, AUTH_MODE="insecure_dev",
                   THROTTLE_ENABLED=True,
                   RATE_LIMITS={"auth": (3, 60), "reward": (40, 60),
                                "enumerate": (30, 60)})
class ThrottleTests(TestCase):
    def setUp(self):
        from django.core.cache import cache
        cache.clear()   # LocMemCache persists across tests in-process
        self.client = Client()

    def test_auth_endpoint_throttles_after_the_limit(self):
        ok = [self.client.post("/v1/auth/guest", data="{}",
                               content_type="application/json").status_code
              for _ in range(3)]
        self.assertEqual(ok, [200, 200, 200])
        blocked = self.client.post("/v1/auth/guest", data="{}",
                                   content_type="application/json")
        self.assertEqual(blocked.status_code, 429)
        self.assertEqual(blocked.json()["code"], "rate_limited")
