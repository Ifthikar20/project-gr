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
import zlib
from collections import namedtuple
from concurrent.futures import ThreadPoolExecutor
from threading import Lock

from django.conf import settings
from django.core.cache import cache
from django.db import close_old_connections, connection, transaction
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


def mile_count_cached(lat, lng):
    """Short-TTL cached mile_count for the ADVISORY read path only — the
    warm/cold + pending decision in presence_trigger, where a few seconds of
    staleness just means a self-correcting warm/cold guess. NEVER call this in
    the cap guard (_guarded_create) or enforce_hard_max: a stale count there
    could over-stock a mile. Keyed on the same ~550 m cell grid as the
    background dedupe so hot cells share one entry."""
    if not (settings.READ_CACHE_ENABLED and settings.CACHE_TTL_MILE):
        return mile_count(lat, lng)
    key = "mile:v1:%d:%d" % (round(lat / 0.005), round(lng / 0.005))
    val = cache.get(key)
    if val is None:
        val = mile_count(lat, lng)
        cache.set(key, val, settings.CACHE_TTL_MILE)
    return val


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


def _serialize_mile(open_lat, open_lng):
    """Serialize concurrent stocking of this mile so overlapping top-ups
    don't both race past the cap. On SQLite, BEGIN IMMEDIATE already takes a
    single global write lock, so this is a no-op. On Postgres (MVCC, no write
    lock on read), take a TRANSACTION-scoped advisory lock keyed on the
    open-point's ~mile grid cell: same-mile passes serialize, different miles
    run fully parallel. This is a CONTENTION optimization, not the cap's
    correctness guarantee — that remains `enforce_hard_max`, the read-time
    trim on every map open. Called inside an open transaction."""
    if connection.vendor != "postgresql":
        return
    # Deterministic 32-bit key from a ~1 km grid cell (crc32 is stable across
    # processes; Python's hash() is not). Fits pg_advisory_xact_lock(bigint).
    cell = f"gemmile:{round(open_lat, 2)}:{round(open_lng, 2)}"
    key = zlib.crc32(cell.encode())
    with connection.cursor() as cur:
        cur.execute("SELECT pg_advisory_xact_lock(%s)", [key])


def _guarded_create(open_lat, open_lng, lat, lng, rng, weights=None):
    """The only way a presence gem is born. Inside a serialized-per-mile
    transaction (SQLite: global BEGIN IMMEDIATE; Postgres: per-mile advisory
    lock — see _serialize_mile) the fresh counts and the INSERT can't
    interleave with another same-mile writer, so the hard cap holds under
    concurrent overlapping top-ups. Both the requester's mile and the
    candidate's own mile are checked, so a gem is never born into ANY mile
    already holding PRESENCE_HARD_MAX."""
    with transaction.atomic():
        _serialize_mile(open_lat, open_lng)
        if mile_count(open_lat, open_lng) >= settings.PRESENCE_HARD_MAX:
            raise CapReached
        if (lat, lng) != (open_lat, open_lng) \
                and mile_count(lat, lng) >= settings.PRESENCE_HARD_MAX:
            raise CapReached
        return create_system_drop(lat, lng, rng, weights=weights)


class PedestrianNet:
    """Strict pedestrian ways (sidewalks/trails/plazas), pre-projected for
    fast point snapping — the single source of truth for where a system gem
    is allowed to physically sit."""

    def __init__(self, ways):
        self.geoms = [RouteGeometry(list(w)) for w in ways if len(w) >= 2]

    def __bool__(self):
        return bool(self.geoms)

    def snap(self, lat, lng):
        """(lat, lng, distance_m) of the nearest point on the network;
        distance is inf when the network is empty."""
        best = (lat, lng, float("inf"))
        for geom in self.geoms:
            cross_m, along_m = geom.project(lat, lng)
            if cross_m < best[2]:
                point = geom.coordinate_at(along_m)
                best = (point[0], point[1], cross_m)
        return best


# `ok` is the crucial fourth field: True means Overpass ANSWERED (even if
# the answer holds zero ways — a genuinely path-less area); False means no
# answer at all (unreachable, rate-limited, budget spent). The daily
# rotation only retires yesterday's gems when ok is True — no answer must
# never empty a previously stocked mile.
PlacementContext = namedtuple("PlacementContext", "net no_go ways ok")


def fetch_placement_context(lat, lng, deadline=None):
    """Everything a placement pass needs about the ground, in ONE Overpass
    request: `(net, no_go, ways, ok)` — the strict pedestrian network to
    snap onto, the no-go polygons (private grounds, golf courses, school
    yards…) to never place inside, the raw ways for Tier 2 sampling, and
    whether Overpass actually answered. All empty with ok=False when it
    didn't — callers fall back to trusted route geometry, and the daily
    rotation postpones rather than expiring gems it can't replace."""
    data = walkability.fetch_placement_data(
        lat, lng, settings.PRESENCE_RADIUS_M, deadline=deadline)
    if data is None:
        return PlacementContext(PedestrianNet([]), walkability.NoGoZones([]),
                                [], False)
    ways, rings = data
    return PlacementContext(PedestrianNet(ways), walkability.NoGoZones(rings),
                            ways, True)


def drop_gem_on_route(route, rng, net=None, no_go=None, near=None,
                      deadline=None):
    """Sample a point on the route's polyline, SNAP it onto the strict
    pedestrian network (sidewalk/trail — never a road centerline, driveway,
    or yard), verify spacing + the mile cap, and write one system GemDrop.
    None if no candidate survived. near=(lat, lng) requires the point to
    sit within the requester's mile (PRESENCE_RADIUS_M).

    net=None fetches the network around the route itself (management
    command path). An EMPTY net (Overpass down) falls back to trusting the
    raw route point — routes are walking-directions-snapped, and the next
    daily rotation re-places these snapped (docs/13 §2).

    Routes are the highest-traffic surface we can prove (run_count gate),
    so their gems roll the richer HIGH_TRAFFIC_WEIGHTS mix."""
    geom = RouteGeometry(polyline_decode(route.polyline))
    if geom.total_length_m <= 0:
        return None
    if net is None:
        context = fetch_placement_context(route.lat, route.lng,
                                          deadline=deadline)
        net, no_go = context.net, context.no_go
    for _ in range(ATTEMPTS_PER_ROUTE):
        if _past(deadline):
            return None
        lat, lng = geom.coordinate_at(rng.uniform(0, geom.total_length_m))
        if net:
            slat, slng, dist_m = net.snap(lat, lng)
            if dist_m > settings.PLACEMENT_SNAP_MAX_M:
                continue        # no sidewalk/trail near this stretch
            lat, lng = slat, slng
        # A mapped footpath through a golf course / gated grounds / school
        # yard is real geometry but never gem territory.
        if no_go is not None and no_go.contains(lat, lng):
            continue
        if near is not None:
            k = 111_320.0
            klng = k * max(0.1, math.cos(math.radians(near[0])))
            if math.hypot((lat - near[0]) * k,
                          (lng - near[1]) * klng) > settings.PRESENCE_RADIUS_M:
                continue
        if near_existing_drop(lat, lng):
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


def drop_on_walkable_ways(lat, lng, count, rng, ways=None, no_go=None,
                          deadline=None):
    """Sample points directly on real OSM walkable ways within the
    requester's mile. The way geometry IS the walkable-path list, so linear
    interpolation between adjacent way nodes stays on the path. This is the
    ONLY off-route placement — we never guess-and-check with random
    scatter, because a rate-limited Overpass check fails open and lands
    gems on private land.

    `ways` is the strict placement network already fetched by the caller
    (top_up_area fetches ONCE per pass and shares it with Tier 1's
    snapping); None fetches here for standalone callers.

    Everything is anchored to PRESENCE_RADIUS_M: ways are fetched only
    within that circle, near ways are weighted higher still, and any
    sampled point that interpolates past the mile (long ways!) is rejected.
    All fills roll the default rarity mix: the way class (trail vs
    sidewalk) is a safety filter, not a loot signal."""
    radius = settings.PRESENCE_RADIUS_M
    if ways is None:
        ways = walkability.fetch_walkable_ways(
            lat, lng, radius,
            highways=walkability.PEDESTRIAN_PLACEMENT_HIGHWAYS,
            deadline=deadline)
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
        # Even an on-way point can sit inside no-go grounds (paths cross
        # golf courses and gated communities); the polygon is the veto.
        if no_go is not None and no_go.contains(plat, plng):
            continue
        if near_existing_drop(plat, plng):
            continue
        _guarded_create(lat, lng, plat, plng, rng)
        created += 1
    return created


def _dev_scatter(lat, lng, count, rng):
    """PRESENCE_DEV_SCATTER only — never production. Place the pass's
    remaining slots at random points within the mile WITHOUT walkability
    verification, so local development still gets a populated map when
    Overpass is rate-limiting the machine (or it's offline). Spacing and
    the per-mile caps still apply; the fail-closed rule is deliberately
    broken here and nowhere else."""
    radius = settings.PRESENCE_RADIUS_M
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    created = 0
    for _ in range(count * ATTEMPTS_PER_ROUTE):
        if created >= count:
            break
        r = radius * math.sqrt(rng.random())
        theta = rng.uniform(0, math.tau)
        plat = lat + r * math.cos(theta) / k
        plng = lng + r * math.sin(theta) / klng
        if near_existing_drop(plat, plng):
            continue
        try:
            _guarded_create(lat, lng, plat, plng, rng)
        except CapReached:
            break
        created += 1
    if created:
        log.warning("DEV SCATTER: placed %d gem(s) near (%.4f, %.4f) with "
                    "NO walkability verification (PRESENCE_DEV_SCATTER) — "
                    "dev convenience only, never enable in production",
                    created, lat, lng)
    return created


def top_up_area(lat, lng, rng=None, budget_s=None, context=None,
                deadline=None):
    """The per-mile contract, one pass. Count the requester's mile; in the
    FLOOR..HARD_MAX band do nothing (shared world — someone else's gems
    are stock); below FLOOR, fill toward FILL_TARGET, every insert
    re-checking the HARD_MAX inside a serialized transaction. Tier 1: one
    gem per popular route (walking-snapped polylines). Tier 2: points on
    real OSM walkable ways. No random scatter — empty beats misplaced, so
    walkability-starved miles legitimately sit below FLOOR and retry on
    later opens. (PRESENCE_DEV_SCATTER, dev only, is the one deliberate
    exception — see _dev_scatter.)

    `context` is a pre-fetched PlacementContext (rotate_and_top_up fetches
    once and shares it with the rotation gate); None fetches here.
    `deadline` (monotonic) overrides budget_s when the caller already
    started the clock."""
    if not settings.PRESENCE_DROPS:
        return 0
    rng = rng or random.Random()
    if deadline is None:
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

    # ONE ground fetch per pass, shared by both tiers: the strict network
    # (Tier 1 snaps onto it, Tier 2 samples on it) plus the no-go polygons
    # both tiers must stay out of. Replaces the old per-candidate
    # is_walkable HTTP calls (faster) and guarantees every gem sits ON a
    # public sidewalk/trail and INSIDE no private grounds. Skipped
    # entirely when neither tier has work to do.
    if context is None and (popular or settings.PRESENCE_BOOTSTRAP):
        context = fetch_placement_context(lat, lng, deadline=deadline)
    if context is not None:
        net, no_go, strict_ways = context.net, context.no_go, context.ways
    else:
        strict_ways = []
        net = PedestrianNet([])
        no_go = walkability.NoGoZones([])
    if popular and not net:
        log.info("stocking: strict pedestrian network unavailable near "
                 "(%.4f, %.4f) — route placements fall back to trusted "
                 "route points until the next rotation", lat, lng)

    try:
        for route in popular:
            if created >= need or _past(deadline):
                break
            if drop_gem_on_route(route, rng, net=net, no_go=no_go,
                                 near=(lat, lng),
                                 deadline=deadline) is not None:
                created += 1

        if created < need and settings.PRESENCE_BOOTSTRAP and not _past(deadline):
            log.info("stocking: %d slot(s) left after routes — sampling OSM "
                     "walkable ways", need - created)
            created += drop_on_walkable_ways(lat, lng, need - created, rng,
                                             ways=strict_ways, no_go=no_go,
                                             deadline=deadline)
    except CapReached:
        log.info("hard cap reached mid-spawn near (%.4f, %.4f) — a "
                 "neighboring mile filled up first; stopping", lat, lng)

    # DEV ONLY: with the flag on, unfilled slots scatter within the mile so
    # an Overpass-less machine still gets a populated map to develop against.
    if created < need and settings.PRESENCE_DEV_SCATTER:
        created += _dev_scatter(lat, lng, need - created, rng)

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


def stale_system_gems(lat, lng):
    """Queryset of yesterday's uncollected SYSTEM gems in the mile's bbox —
    the set the daily rotation retires. One definition, shared by the
    rotation itself, its geometry gate, and the pending-restock signal."""
    dlat, dlng = bbox_deltas(lat, settings.PRESENCE_RADIUS_M)
    today_start = timezone.now().replace(hour=0, minute=0,
                                         second=0, microsecond=0)
    return GemDrop.objects.filter(
        route__isnull=True, active=True, placed_by="system",
        created_at__lt=today_start,
        lat__gte=lat - dlat, lat__lte=lat + dlat,
        lng__gte=lng - dlng, lng__lte=lng + dlng)


def expire_stale(lat, lng):
    """Daily rotation: uncollected SYSTEM gems never squat the same spot
    two days running — anything spawned before today frees its slot, and
    the top-up that follows restocks the mile at fresh positions.
    Player-placed drops are exempt: a runner chose those spots. Callers
    gate this on having replacement geometry in hand (rotate_and_top_up) —
    expiring what we can't replace empties the world."""
    expired = stale_system_gems(lat, lng).update(active=False)
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
    """One maintenance pass for a mile. The rotation is gated on geometry:
    yesterday's gems only leave the map once the replacement pass has
    ground truth in hand (context.ok) — an Overpass outage postpones the
    rotation to a later open instead of emptying a previously stocked
    mile. The one Overpass fetch is shared with the top-up that follows.

    Returns True when this mile is still due to change because the fetch
    failed (rotation postponed, or fill still below floor) — the honest
    `stocking` signal for inline callers: worth looking again soon."""
    deadline = time.monotonic() + budget_s if budget_s else None
    rotation_due = stale_system_gems(lat, lng).exists()
    # Fetch only when a pass could actually use the geometry — mirrors
    # top_up_area's own gate, so a bare mile with stocking off (no
    # bootstrap, no qualifying routes) still never calls Overpass.
    needs_fill = mile_count(lat, lng) < settings.PRESENCE_FLOOR
    if needs_fill and not settings.PRESENCE_BOOTSTRAP:
        dlat, dlng = bbox_deltas(lat, settings.PRESENCE_RADIUS_M)
        needs_fill = Route.objects.filter(
            status="published",
            run_count__gte=settings.PRESENCE_DROP_MIN_RUNS,
            lat__gte=lat - dlat, lat__lte=lat + dlat,
            lng__gte=lng - dlng, lng__lte=lng + dlng).exists()
    context = None
    if rotation_due or needs_fill:
        context = fetch_placement_context(lat, lng, deadline=deadline)
    if rotation_due:
        if context.ok:
            expire_stale(lat, lng)
        else:
            log.warning("rotation postponed near (%.4f, %.4f): no placement "
                        "geometry (Overpass unreachable or budget spent) — "
                        "yesterday's gems stay as stock until a later open",
                        lat, lng)
    enforce_hard_max(lat, lng)
    top_up_area(lat, lng, context=context, deadline=deadline)
    if context is None or context.ok:
        return False
    return rotation_due or mile_count(lat, lng) < settings.PRESENCE_FLOOR


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
    return stale_system_gems(lat, lng).exists()


def presence_trigger(lat, lng):
    """Entry point for GET /v1/drops. Warm mile → background job (instant
    answer); cold mile → inline bootstrap (first answer arrives stocked,
    bounded by PRESENCE_INLINE_BUDGET_S). settings.PRESENCE_ASYNC=False
    forces inline everywhere — tests need it because their in-memory
    SQLite can't be shared across threads.

    Returns True when restocking is still PENDING after this call: a
    background job is queued/running for a mile that will change, or an
    inline pass came up short because the geometry fetch failed — the
    client looks again in a few seconds instead of settling on a bare
    map. An inline answer that reflects the ground truth (including a
    genuinely path-less area, fail closed) returns False."""
    if not settings.PRESENCE_DROPS:
        return False
    # Advisory count only (warm/cold + pending flag) — cacheable. The cap
    # guard downstream re-counts uncached inside its serialized transaction.
    count = mile_count_cached(lat, lng)
    warm = count > 0
    if not warm or not settings.PRESENCE_ASYNC:
        return rotate_and_top_up(lat, lng,
                                 budget_s=settings.PRESENCE_INLINE_BUDGET_S
                                 if settings.PRESENCE_ASYNC else None)
    pending = has_pending_restock(lat, lng, count)
    key = _cell_key(lat, lng)
    with _inflight_lock:
        if key in _inflight:
            return pending               # this cell is already being stocked
        _inflight.add(key)
    try:
        _dispatch_topup(key, lat, lng)
    except Exception:
        # Dispatch can raise (thread-spawn failure under fd/memory pressure,
        # or a Celery broker that's down). The thread worker's own finally is
        # normally what discards the key — if dispatch never got that far,
        # discard here so the cell isn't leaked (never restocked again).
        with _inflight_lock:
            _inflight.discard(key)
        log.exception("could not queue top-up for cell %s", (key,))
    return pending


def _dispatch_topup(key, lat, lng):
    """Route the background restock to the configured backend (docs/20):

      * "thread" (default) — the in-process pool, with the in-flight cell
        dedupe. Correct for one box.
      * "celery"           — enqueue a shared task so N app boxes don't each
        run the same pass. The per-mile advisory lock + enforce_hard_max keep
        it correct; the in-process cell key is released immediately (it can't
        dedupe across processes anyway). Flipping backends is config-only.
    """
    if settings.STOCKING_BACKEND == "celery":
        from .tasks import rotate_and_top_up_task     # lazy: no celery import in thread mode
        rotate_and_top_up_task.delay(lat, lng)
        with _inflight_lock:
            _inflight.discard(key)
        return
    _executor.submit(_background_job, key, lat, lng)
