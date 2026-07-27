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
WEIGHTS = [40, 30, 20, 10]
# Dedicated trails and promenades — gems here skew emerald-and-up; plain
# sidewalks (footway) keep the common-heavy default mix.
PRIME_WALKWAYS = {"path", "pedestrian", "steps"}
PRIME_WEIGHTS = [15, 45, 27, 13]
ATTEMPTS_PER_ROUTE = 8
# Gems are a walk, not a drive: every presence-triggered gem must land
# within this distance of the map-open point, regardless of query radius.
NEAR_LIMIT_M = 800


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


def drop_gem_on_route(route, rng, near=None):
    """Sample a point on the route's (walking-snapped) polyline, verify
    spacing + walkability, and write one system GemDrop. None if no
    candidate survived. near=(lat, lng) also requires the point to sit
    within NEAR_LIMIT_M of the map-open coordinates."""
    geom = RouteGeometry(polyline_decode(route.polyline))
    if geom.total_length_m <= 0:
        return None
    for _ in range(ATTEMPTS_PER_ROUTE):
        lat, lng = geom.coordinate_at(rng.uniform(0, geom.total_length_m))
        if near is not None:
            k = 111_320.0
            klng = k * max(0.1, math.cos(math.radians(near[0])))
            if math.hypot((lat - near[0]) * k,
                          (lng - near[1]) * klng) > NEAR_LIMIT_M:
                continue
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


def create_system_drop(lat, lng, rng, weights=None):
    rarity = rng.choices(RARITIES, weights=weights or WEIGHTS)[0]
    drop = GemDrop.objects.create(
        route=None, dropped_by=None,
        gem_id=catalog.random_gem_of(rarity, rng)["id"], rarity=rarity,
        lat=lat, lng=lng, position_along_route_m=0,
        respawn_rule="one_time", placed_by="system")
    log.info("spawned %s gem at (%.5f, %.5f)", rarity, lat, lng)
    return drop


def drop_on_walkable_ways(lat, lng, radius_m, count, rng):
    """Sample points directly on real OSM walkable ways near the map query.
    The way geometry IS the walkable-path list, so linear interpolation
    between adjacent way nodes stays on the path. This is the ONLY off-route
    placement — we never guess-and-check with random scatter, because a
    rate-limited Overpass check fails open and lands gems on private land.

    Everything is anchored to NEAR_LIMIT_M: ways are fetched only within
    that circle, near ways are weighted higher still, and any sampled point
    that interpolates past the limit (long ways!) is rejected — gems are a
    short walk, never a drive. Dedicated trails get the rarer-skewed mix."""
    ways = walkability.fetch_walkable_ways(
        lat, lng, min(radius_m, NEAR_LIMIT_M), with_tags=True,
        highways=walkability.PEDESTRIAN_HIGHWAYS)
    if not ways:
        return 0
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    way_weights = [
        (250 / (250 + min(math.hypot((p[0] - lat) * k, (p[1] - lng) * klng)
                          for p in coords))) ** 2
        for coords, _ in ways]
    created = 0
    for _ in range(count * ATTEMPTS_PER_ROUTE):
        if created >= count:
            break
        coords, highway = rng.choices(ways, weights=way_weights)[0]
        i = rng.randrange(len(coords) - 1)
        t = rng.random()
        plat = coords[i][0] + t * (coords[i + 1][0] - coords[i][0])
        plng = coords[i][1] + t * (coords[i + 1][1] - coords[i][1])
        if math.hypot((plat - lat) * k, (plng - lng) * klng) > NEAR_LIMIT_M:
            continue
        if near_existing_drop(plat, plng):
            continue
        rarity_weights = PRIME_WEIGHTS if highway in PRIME_WALKWAYS else WEIGHTS
        create_system_drop(plat, plng, rng, weights=rarity_weights)
        created += 1
    return created


def top_up_area(lat, lng, radius_m, rng=None):
    """Presence trigger: stock gems around every map query up to
    PRESENCE_DROP_MAX_PER_AREA, ONLY on walkable geometry. Tier 1: one gem
    per popular route (route polylines are already walking-snapped). Tier 2:
    sample points on real OSM walkable ways. No random scatter — a
    rate-limited walkability check fails open and lands gems on private
    property, so empty is preferred over misplaced."""
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
    cap = settings.PRESENCE_DROP_MAX_PER_AREA
    created = 0

    def remaining():
        return max(0, cap - active - created)

    for route in popular:
        if remaining() == 0:
            break
        if drop_gem_on_route(route, rng, near=(lat, lng)) is not None:
            created += 1

    if remaining() > 0 and settings.PRESENCE_BOOTSTRAP:
        log.info("stocking: %d slot(s) left after routes — sampling OSM walkable ways",
                 remaining())
        created += drop_on_walkable_ways(lat, lng, radius_m, remaining(), rng)

    if remaining() > 0:
        log.info("stocking: %d slot(s) left empty — no walkable geometry available "
                 "(Overpass unreachable or no ways nearby); leaving slots open rather "
                 "than scattering onto private land", remaining())

    if created:
        log.info("presence trigger: %d gem(s) spawned for map open at (%.4f, %.4f)",
                 created, lat, lng)
    return created
