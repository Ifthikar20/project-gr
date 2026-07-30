"""System drop engine (docs/13, docs/14 §2) — shared by the drop_gems
command and the presence trigger in GET /v1/drops.

The presence trigger makes user activity the coordinate capture: opening
the map sends the user's lat/lng, and gems get stocked around exactly that
point. The budget is the PER-MILE CONTRACT — every count is radial within
settings.PRESENCE_RADIUS_M of the map-open point:

    below PRESENCE_FLOOR      → restock up to PRESENCE_FILL_TARGET
    FLOOR..HARD_MAX           → do nothing (someone else's gems are stock)
    PRESENCE_HARD_MAX         → never exceeded, enforced per-insert inside
                                a write-serialized transaction

No app usage in a region (no routes, no runs, no map opens) means no gems
ever spawn there.
"""
import logging
import math
import random
import time
from concurrent.futures import ThreadPoolExecutor
from threading import Lock

from django.conf import settings
from django.db import close_old_connections, transaction
from django.utils import timezone

log = logging.getLogger("api.system_drops")

from . import catalog, rules, walkability
from .geometry import RouteGeometry, polyline_decode
from .models import GemDrop, Route

RARITIES = ["common", "uncommon", "rare", "epic"]   # legendary: never
WEIGHTS = [40, 30, 20, 10]
# Rarer loot follows proven foot traffic, not scenery: gems on popular
# routes (already gated by PRESENCE_DROP_MIN_RUNS) roll this richer mix,
# while off-route sidewalk fills keep the common-heavy default. The OSM way
# class (trail vs sidewalk) deliberately carries no bonus — we stock where
# people already walk, we don't lure them somewhere "nicer".
HIGH_TRAFFIC_WEIGHTS = [15, 45, 27, 13]
ATTEMPTS_PER_ROUTE = 8


class CapReached(Exception):
    """A guarded create found the mile already at PRESENCE_HARD_MAX —
    the whole stocking pass stops."""


def bbox_deltas(lat, radius_m):
    return (radius_m / 111_320,
            radius_m / (111_320 * max(0.1, math.cos(math.radians(lat)))))


def _past(deadline):
    return deadline is not None and time.monotonic() > deadline


def mile_count(lat, lng):
    """Radial count of active standalone SYSTEM gems within the mile of a
    point — the contract's one unit of measure. Bbox prefilter (indexed),
    then exact planar distance. Player drops deliberately don't count:
    the contract governs system stock, and wallet litter must not be able
    to suppress it."""
    radius = settings.PRESENCE_RADIUS_M
    dlat, dlng = bbox_deltas(lat, radius)
    rows = GemDrop.objects.filter(
        route__isnull=True, active=True, placed_by="system",
        lat__gte=lat - dlat, lat__lte=lat + dlat,
        lng__gte=lng - dlng, lng__lte=lng + dlng).values_list("lat", "lng")
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    return sum(1 for rlat, rlng in rows
               if math.hypot((rlat - lat) * k, (rlng - lng) * klng) <= radius)


def near_existing_drop(lat, lng):
    """Min spacing vs every active standalone drop (same 100 m rule as
    route placement). Counts player drops too — spacing is about the map
    not feeling cluttered, whoever placed the gem."""
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


def _guarded_create(open_lat, open_lng, lat, lng, rng, weights=None):
    """The only way a presence gem is born. BEGIN IMMEDIATE (settings
    OPTIONS) takes SQLite's single write lock at block entry, so between
    the fresh counts and the INSERT no other writer — thread or process —
    can commit: the hard cap holds under concurrent overlapping top-ups.
    Both the requester's mile and the candidate's own mile are checked, so
    a gem is never born into ANY mile already holding PRESENCE_HARD_MAX."""
    with transaction.atomic():
        if mile_count(open_lat, open_lng) >= settings.PRESENCE_HARD_MAX:
            raise CapReached
        if (lat, lng) != (open_lat, open_lng) \
                and mile_count(lat, lng) >= settings.PRESENCE_HARD_MAX:
            raise CapReached
        return create_system_drop(lat, lng, rng, weights=weights)


def drop_gem_on_route(route, rng, near=None, deadline=None):
    """Sample a point on the route's (walking-snapped) polyline, verify
    spacing + walkability + the mile cap, and write one system GemDrop.
    None if no candidate survived. near=(lat, lng) requires the point to
    sit within the requester's mile (PRESENCE_RADIUS_M).

    Routes are the highest-traffic surface we can prove (run_count gate),
    so their gems roll the richer HIGH_TRAFFIC_WEIGHTS mix."""
    geom = RouteGeometry(polyline_decode(route.polyline))
    if geom.total_length_m <= 0:
        return None
    for _ in range(ATTEMPTS_PER_ROUTE):
        if _past(deadline):
            return None
        lat, lng = geom.coordinate_at(rng.uniform(0, geom.total_length_m))
        if near is not None:
            k = 111_320.0
            klng = k * max(0.1, math.cos(math.radians(near[0])))
            if math.hypot((lat - near[0]) * k,
                          (lng - near[1]) * klng) > settings.PRESENCE_RADIUS_M:
                continue
        if near_existing_drop(lat, lng):
            continue
        # Only an explicit "not walkable" vetoes the point. None (check off
        # or Overpass unanswerable/rate-limited) is accepted: the candidate
        # was sampled from a walking-directions-snapped route polyline, so
        # construction already vouches for it (docs/13 §2). When the
        # deadline can't afford the check's worst case, skip it — skipping
        # yields the same accepted outcome as unreachable.
        if deadline is None or (deadline - time.monotonic()
                                > settings.WALKABILITY_TIMEOUT_S * 2):
            if walkability.is_walkable(lat, lng) is False:
                continue
        open_point = near if near is not None else (lat, lng)
        try:
            return _guarded_create(open_point[0], open_point[1], lat, lng,
                                   rng, weights=HIGH_TRAFFIC_WEIGHTS)
        except CapReached:
            if near is None:
                return None     # global sweep: this area is full, move on
            raise
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


def drop_on_walkable_ways(lat, lng, count, rng, deadline=None):
    """Sample points directly on real OSM walkable ways within the
    requester's mile. The way geometry IS the walkable-path list, so linear
    interpolation between adjacent way nodes stays on the path. This is the
    ONLY off-route placement — we never guess-and-check with random
    scatter, because a rate-limited Overpass check fails open and lands
    gems on private land.

    Everything is anchored to PRESENCE_RADIUS_M: ways are fetched only
    within that circle, near ways are weighted higher still, and any
    sampled point that interpolates past the mile (long ways!) is rejected.
    All fills roll the default rarity mix: the way class (trail vs
    sidewalk) is a safety filter, not a loot signal."""
    radius = settings.PRESENCE_RADIUS_M
    ways = walkability.fetch_walkable_ways(
        lat, lng, radius,
        highways=walkability.PEDESTRIAN_HIGHWAYS, deadline=deadline)
    if not ways:
        return 0
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    way_weights = [
        (250 / (250 + min(math.hypot((p[0] - lat) * k, (p[1] - lng) * klng)
                          for p in coords))) ** 2
        for coords in ways]
    created = 0
    for _ in range(count * ATTEMPTS_PER_ROUTE):
        if created >= count or _past(deadline):
            break
        coords = rng.choices(ways, weights=way_weights)[0]
        i = rng.randrange(len(coords) - 1)
        t = rng.random()
        plat = coords[i][0] + t * (coords[i + 1][0] - coords[i][0])
        plng = coords[i][1] + t * (coords[i + 1][1] - coords[i][1])
        if math.hypot((plat - lat) * k, (plng - lng) * klng) > radius:
            continue
        if near_existing_drop(plat, plng):
            continue
        _guarded_create(lat, lng, plat, plng, rng)
        created += 1
    return created


def top_up_area(lat, lng, rng=None, budget_s=None):
    """The per-mile contract, one pass. Count the requester's mile; in the
    FLOOR..HARD_MAX band do nothing (shared world — someone else's gems
    are stock); below FLOOR, fill toward FILL_TARGET, every insert
    re-checking the HARD_MAX inside a serialized transaction. Tier 1: one
    gem per popular route (walking-snapped polylines). Tier 2: points on
    real OSM walkable ways. No random scatter — empty beats misplaced, so
    walkability-starved miles legitimately sit below FLOOR and retry on
    later opens."""
    if not settings.PRESENCE_DROPS:
        return 0
    rng = rng or random.Random()
    deadline = time.monotonic() + budget_s if budget_s else None
    count = mile_count(lat, lng)
    if count >= settings.PRESENCE_FLOOR:
        return 0
    need = settings.PRESENCE_FILL_TARGET - count

    dlat, dlng = bbox_deltas(lat, settings.PRESENCE_RADIUS_M)
    popular = list(Route.objects.filter(
        status="published", run_count__gte=settings.PRESENCE_DROP_MIN_RUNS,
        lat__gte=lat - dlat, lat__lte=lat + dlat,
        lng__gte=lng - dlng, lng__lte=lng + dlng).order_by("-run_count"))
    created = 0

    try:
        for route in popular:
            if created >= need or _past(deadline):
                break
            if drop_gem_on_route(route, rng, near=(lat, lng),
                                 deadline=deadline) is not None:
                created += 1

        if created < need and settings.PRESENCE_BOOTSTRAP and not _past(deadline):
            log.info("stocking: %d slot(s) left after routes — sampling OSM "
                     "walkable ways", need - created)
            created += drop_on_walkable_ways(lat, lng, need - created, rng,
                                             deadline=deadline)
    except CapReached:
        log.info("hard cap reached mid-spawn near (%.4f, %.4f) — a "
                 "neighboring mile filled up first; stopping", lat, lng)

    if created < need:
        if _past(deadline):
            log.info("stocking: budget spent with %d slot(s) unfilled near "
                     "(%.4f, %.4f) — later opens retry", need - created, lat, lng)
        else:
            log.info("stocking: %d slot(s) left empty — no walkable geometry "
                     "available (Overpass unreachable or no ways nearby); "
                     "leaving them open rather than scattering onto private "
                     "land", need - created)

    if created:
        log.info("presence trigger: %d gem(s) spawned for map open at "
                 "(%.4f, %.4f)", created, lat, lng)
    return created


# ── Presence-trigger dispatch: no lag, daily rotation ─────────────────────
#
# The map read must never wait on placement work it doesn't strictly need.
# A WARM mile (it already holds system gems) answers instantly and
# rotates/tops up in a background worker — that one response may show
# yesterday's layout a final time, replaced on the next refresh. Only
# first-contact bootstrap (an empty mile) runs inline, bounded by
# PRESENCE_INLINE_BUDGET_S, so the very first answer for a new area is
# already stocked — the app's loading cover exists for exactly that wait.

_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="gem-topup")
_inflight = set()
_inflight_lock = Lock()

BACKGROUND_BUDGET_S = 60


def _cell_key(lat, lng):
    # ~550 m grid: dedupes concurrent background jobs per neighborhood.
    return (round(lat / 0.005), round(lng / 0.005))


def expire_stale(lat, lng):
    """Daily rotation: uncollected SYSTEM gems never squat the same spot
    two days running — anything spawned before today frees its slot, and
    the top-up that follows restocks the mile at fresh positions.
    Player-placed drops are exempt: a runner chose those spots."""
    dlat, dlng = bbox_deltas(lat, settings.PRESENCE_RADIUS_M)
    today_start = timezone.now().replace(hour=0, minute=0,
                                         second=0, microsecond=0)
    expired = GemDrop.objects.filter(
        route__isnull=True, active=True, placed_by="system",
        created_at__lt=today_start,
        lat__gte=lat - dlat, lat__lte=lat + dlat,
        lng__gte=lng - dlng, lng__lte=lng + dlng).update(active=False)
    if expired:
        log.info("daily rotation: expired %d system gem(s) near (%.4f, %.4f)",
                 expired, lat, lng)
    return expired


def enforce_hard_max(lat, lng):
    """Read-time cap enforcement: whatever concurrent neighbors did while
    nobody was looking, the mile you OPEN is trimmed to PRESENCE_HARD_MAX
    before it's shown. The per-insert guards keep overshoot to a few gems
    in the worst overlap geometry; this makes the user-facing guarantee —
    "never more than 50 within a mile of MY location" — literal at every
    observation. Newest gems go first (least likely to be someone's
    target), and only system gems are touched."""
    radius = settings.PRESENCE_RADIUS_M
    excess = mile_count(lat, lng) - settings.PRESENCE_HARD_MAX
    if excess <= 0:
        return 0
    dlat, dlng = bbox_deltas(lat, radius)
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    with transaction.atomic():
        candidates = GemDrop.objects.filter(
            route__isnull=True, active=True, placed_by="system",
            lat__gte=lat - dlat, lat__lte=lat + dlat,
            lng__gte=lng - dlng, lng__lte=lng + dlng).order_by("-created_at")
        trimmed = 0
        for drop in candidates:
            if trimmed >= excess:
                break
            if math.hypot((drop.lat - lat) * k,
                          (drop.lng - lng) * klng) <= radius:
                drop.active = False
                drop.save(update_fields=["active"])
                trimmed += 1
    if trimmed:
        log.info("hard-max trim: deactivated %d excess gem(s) in the mile "
                 "at (%.4f, %.4f)", trimmed, lat, lng)
    return trimmed


def rotate_and_top_up(lat, lng, budget_s=None):
    expire_stale(lat, lng)
    enforce_hard_max(lat, lng)
    return top_up_area(lat, lng, budget_s=budget_s)


def _background_job(key, lat, lng):
    try:
        close_old_connections()
        rotate_and_top_up(lat, lng, budget_s=BACKGROUND_BUDGET_S)
    except Exception:
        log.exception("background top-up failed for cell %s", (key,))
    finally:
        close_old_connections()
        with _inflight_lock:
            _inflight.discard(key)


def has_pending_restock(lat, lng, count):
    """True when the world within this mile is about to change after an
    instant warm answer: the mile is sub-floor (top-up incoming) or
    yesterday's system gems are still active (daily rotation incoming).
    Drives the read response's `stocking` flag so clients look again in a
    few seconds instead of sitting on the thin/stale answer."""
    if count < settings.PRESENCE_FLOOR:
        return True
    dlat, dlng = bbox_deltas(lat, settings.PRESENCE_RADIUS_M)
    today_start = timezone.now().replace(hour=0, minute=0,
                                         second=0, microsecond=0)
    return GemDrop.objects.filter(
        route__isnull=True, active=True, placed_by="system",
        created_at__lt=today_start,
        lat__gte=lat - dlat, lat__lte=lat + dlat,
        lng__gte=lng - dlng, lng__lte=lng + dlng).exists()


def presence_trigger(lat, lng):
    """Entry point for GET /v1/drops. Warm mile → background job (instant
    answer); cold mile → inline bootstrap (first answer arrives stocked,
    bounded by PRESENCE_INLINE_BUDGET_S). settings.PRESENCE_ASYNC=False
    forces inline everywhere — tests need it because their in-memory
    SQLite can't be shared across threads.

    Returns True when restocking is still PENDING after this call (a
    background job is queued/running for a mile that will change); inline
    paths return False because the answer already reflects the restock."""
    if not settings.PRESENCE_DROPS:
        return False
    count = mile_count(lat, lng)
    warm = count > 0
    if not warm or not settings.PRESENCE_ASYNC:
        rotate_and_top_up(lat, lng,
                          budget_s=settings.PRESENCE_INLINE_BUDGET_S
                          if settings.PRESENCE_ASYNC else None)
        return False
    pending = has_pending_restock(lat, lng, count)
    key = _cell_key(lat, lng)
    with _inflight_lock:
        if key in _inflight:
            return pending               # this cell is already being stocked
        _inflight.add(key)
    _executor.submit(_background_job, key, lat, lng)
    return pending
