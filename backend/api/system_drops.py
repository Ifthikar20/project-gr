"""System drop engine (docs/13) — shared by the drop_gems command and the
presence trigger in GET /v1/drops.

The presence trigger makes user activity the coordinate capture: opening the
map sends the user's lat/lng, and that same request tops up system gems in
that area — if it holds popular routes and is short of active system drops.
No app usage in a region (no routes, no runs, no map opens) means no gems
ever spawn there.
"""
import logging
import math
import random

from django.conf import settings

log = logging.getLogger("api.system_drops")

from . import catalog, rules, walkability
from .geometry import RouteGeometry, polyline_decode
from .models import GemDrop, Route

RARITIES = ["common", "uncommon", "rare", "epic"]   # legendary: never
WEIGHTS = [60, 25, 12, 3]
ATTEMPTS_PER_ROUTE = 8


def bbox_deltas(lat, radius_m):
    return (radius_m / 111_320,
            radius_m / (111_320 * max(0.1, math.cos(math.radians(lat)))))


def near_existing_drop(lat, lng):
    """Min spacing vs every active standalone drop (same 100 m rule as
    route placement)."""
    spacing = rules.MIN_GEM_SPACING_M
    dlat, dlng = bbox_deltas(lat, spacing)
    nearby = GemDrop.objects.filter(
        route__isnull=True, active=True,
        lat__gte=lat - dlat, lat__lte=lat + dlat,
        lng__gte=lng - dlng, lng__lte=lng + dlng)
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    for d in nearby:
        if math.hypot((d.lat - lat) * k, (d.lng - lng) * klng) < spacing:
            return True
    return False


def drop_gem_on_route(route, rng):
    """Sample a point on the route's (walking-snapped) polyline, verify
    spacing + walkability, and write one system GemDrop. None if no
    candidate survived."""
    geom = RouteGeometry(polyline_decode(route.polyline))
    if geom.total_length_m <= 0:
        return None
    for _ in range(ATTEMPTS_PER_ROUTE):
        lat, lng = geom.coordinate_at(rng.uniform(0, geom.total_length_m))
        if near_existing_drop(lat, lng):
            continue
        # Only an explicit "not walkable" vetoes the point. None (check off
        # or Overpass unanswerable/rate-limited) is accepted: the candidate
        # was sampled from a walking-directions-snapped route polyline, so
        # construction already vouches for it — requiring a positive Overpass
        # answer made gem spawning silently dependent on a rate-limited
        # public API (docs/13 §2).
        if walkability.is_walkable(lat, lng) is False:
            continue
        return create_system_drop(lat, lng, rng)
    return None


def create_system_drop(lat, lng, rng):
    rarity = rng.choices(RARITIES, weights=WEIGHTS)[0]
    drop = GemDrop.objects.create(
        route=None, dropped_by=None,
        gem_id=catalog.gem_of(rarity)["id"], rarity=rarity,
        lat=lat, lng=lng, position_along_route_m=0,
        respawn_rule="one_time", placed_by="system")
    log.info("spawned %s gem at (%.5f, %.5f)", rarity, lat, lng)
    return drop


def drop_on_walkable_ways(lat, lng, radius_m, count, rng):
    """Bootstrap tier 2: sample points directly on real OSM walkable ways
    near the map query — the system stocks gems even where no routes exist
    yet. The way geometry IS the walkable-path list, so no per-point check
    is needed."""
    ways = walkability.fetch_walkable_ways(lat, lng, min(radius_m, 1500))
    if not ways:
        return 0
    created = 0
    for _ in range(count * ATTEMPTS_PER_ROUTE):
        if created >= count:
            break
        way = rng.choice(ways)
        i = rng.randrange(len(way) - 1)
        t = rng.random()
        plat = way[i][0] + t * (way[i + 1][0] - way[i][0])
        plng = way[i][1] + t * (way[i + 1][1] - way[i][1])
        if near_existing_drop(plat, plng):
            continue
        create_system_drop(plat, plng, rng)
        created += 1
    return created


def drop_near_center(lat, lng, count, rng):
    """Bootstrap tier 3, last resort (no routes AND no OSM data reachable):
    scatter gems a short walk (150-450 m) from where the user actually is,
    so an opened map is never empty. The walkability veto still applies
    when answerable, and the claim log flags any misplacement (docs/13 §6)."""
    klng = 111_320 * max(0.1, math.cos(math.radians(lat)))
    created = 0
    for _ in range(count * ATTEMPTS_PER_ROUTE):
        if created >= count:
            break
        bearing = rng.uniform(0, 2 * math.pi)
        dist = rng.uniform(150, 450)
        plat = lat + dist * math.cos(bearing) / 111_320
        plng = lng + dist * math.sin(bearing) / klng
        if near_existing_drop(plat, plng):
            continue
        if walkability.is_walkable(plat, plng) is False:
            continue
        create_system_drop(plat, plng, rng)
        created += 1
    return created


def top_up_area(lat, lng, radius_m, rng=None):
    """Presence trigger: the SYSTEM stocks gems around every map query —
    users never depend on other users dropping gems. Tier 1 samples popular
    routes (one active system gem per route, capped). An area with nothing
    at all is bootstrapped: tier 2 drops onto real OSM walkable ways; tier 3
    falls back to a short-walk scatter around the user. Self-limiting: once
    the area holds any active system gems, map opens are two count queries."""
    if not settings.PRESENCE_DROPS:
        return 0
    rng = rng or random.Random()
    dlat, dlng = bbox_deltas(lat, radius_m)
    box = {"lat__gte": lat - dlat, "lat__lte": lat + dlat,
           "lng__gte": lng - dlng, "lng__lte": lng + dlng}
    popular = list(Route.objects.filter(
        status="published", run_count__gte=settings.PRESENCE_DROP_MIN_RUNS,
        **box).order_by("-run_count"))
    active = GemDrop.objects.filter(route__isnull=True, active=True,
                                    placed_by="system", **box).count()
    created = 0
    if popular:
        target = min(settings.PRESENCE_DROP_MAX_PER_AREA, len(popular))
        for route in popular:
            if active + created >= target:
                break
            if drop_gem_on_route(route, rng) is not None:
                created += 1
    if active + created == 0 and settings.PRESENCE_BOOTSTRAP:
        cap = settings.PRESENCE_DROP_MAX_PER_AREA
        log.info("bootstrap: empty area (%.4f, %.4f) — trying OSM walkable ways",
                 lat, lng)
        created += drop_on_walkable_ways(lat, lng, radius_m, cap, rng)
        if created == 0:
            log.info("bootstrap: no OSM data — scattering near the user")
            created += drop_near_center(lat, lng, cap, rng)
    if created:
        log.info("presence trigger: %d gem(s) spawned for map open at (%.4f, %.4f)",
                 created, lat, lng)
    return created
