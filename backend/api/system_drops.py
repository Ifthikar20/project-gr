"""System drop engine (docs/13) — shared by the drop_gems command and the
presence trigger in GET /v1/drops.

The presence trigger makes user activity the coordinate capture: opening the
map sends the user's lat/lng, and that same request tops up system gems in
that area — if it holds popular routes and is short of active system drops.
No app usage in a region (no routes, no runs, no map opens) means no gems
ever spawn there.
"""
import math
import random

from django.conf import settings

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
        # False = Overpass says not walkable → skip. None = check off or
        # unreachable → trust the route snap (it came from walking
        # directions). True = confirmed.
        if walkability.is_walkable(lat, lng) is False:
            continue
        rarity = rng.choices(RARITIES, weights=WEIGHTS)[0]
        return GemDrop.objects.create(
            route=None, dropped_by=None,
            gem_id=catalog.gem_of(rarity)["id"], rarity=rarity,
            lat=lat, lng=lng, position_along_route_m=0,
            respawn_rule="one_time", placed_by="system")
    return None


def top_up_area(lat, lng, radius_m, rng=None):
    """Presence trigger: replenish system drops around a map query's
    coordinates. Self-limiting — the target is one active system drop per
    popular route in the area, capped, so repeated map opens never pile up
    gems; collection frees a slot and the next map open refills it."""
    if not settings.PRESENCE_DROPS:
        return 0
    rng = rng or random.Random()
    dlat, dlng = bbox_deltas(lat, radius_m)
    box = {"lat__gte": lat - dlat, "lat__lte": lat + dlat,
           "lng__gte": lng - dlng, "lng__lte": lng + dlng}
    popular = list(Route.objects.filter(
        status="published", run_count__gte=settings.PRESENCE_DROP_MIN_RUNS,
        **box).order_by("-run_count"))
    if not popular:
        return 0
    target = min(settings.PRESENCE_DROP_MAX_PER_AREA, len(popular))
    active = GemDrop.objects.filter(route__isnull=True, active=True,
                                    placed_by="system", **box).count()
    created = 0
    for route in popular:
        if active + created >= target:
            break
        if drop_gem_on_route(route, rng) is not None:
            created += 1
    return created
