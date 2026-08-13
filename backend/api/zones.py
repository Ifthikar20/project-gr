"""The day's zones, server-side (docs/21) — the API filling the client's
ZoneProviding seam.

A faithful port of the iOS pipeline so both sides agree on the same ground:
OverpassZoneParser's one-request query and classification, RingMath's
area/centroid/scale/decimate, and ZoneSelector's scoring, fail-closed no-go
veto, seeded weighted pick and stable (day, centroid) zone ids. Same park
geometry + same day ⇒ same zone UUIDs as the client would compute for
itself, which is what keeps partial mile progress keyed correctly whichever
side answered.

Fetching rides walkability.query_overpass (mirrors, circuit breaker,
logging); answers are cached per (~500 m cell, day) and persisted as Zone
rows so mint claims can be checked against zones that were actually served.
Three-valued serve result, the ZoneProviding contract verbatim:
    list  — the day's zones (possibly empty: answered, nothing anchors here)
    None  — Overpass unreachable; the endpoint 503s and the client's own
            provider chain takes over. No answer must never read as "no
            zones here".
"""
import logging
import math

from django.core.cache import cache
from django.conf import settings

from . import walkability, zone_rules
from .seeded import SplitMix64, stable_seed_daily, stable_zone_id

log = logging.getLogger("api.zones")

M_PER_DEG_LAT = 111_320.0

ZONE_CACHE_TTL_S = 15 * 60

# One request for everything zone selection needs in a circle — the client's
# OverpassZoneParser.query, verbatim: parks anchor, strict pedestrian ways
# score, no-go polygons veto.
ZONE_QUERY_TEMPLATE = """
[out:json][timeout:{timeout}];
(
  way(around:{radius},{lat:.6f},{lng:.6f})["highway"~"^(footway|pedestrian|path)$"]["foot"!~"^(no|private)$"]["access"!~"^(no|private)$"];
  way(around:{radius},{lat:.6f},{lng:.6f})["leisure"~"^(park|nature_reserve|garden)$"];
  way(around:{radius},{lat:.6f},{lng:.6f})["landuse"="recreation_ground"];
  way(around:{radius},{lat:.6f},{lng:.6f})["access"~"^(private|no)$"];
  way(around:{radius},{lat:.6f},{lng:.6f})["leisure"="golf_course"];
  way(around:{radius},{lat:.6f},{lng:.6f})["amenity"~"^(school|kindergarten|college|university)$"];
  way(around:{radius},{lat:.6f},{lng:.6f})["landuse"~"^(military|industrial|railway)$"];
  way(around:{radius},{lat:.6f},{lng:.6f})["aeroway"="aerodrome"];
);
out geom 1200;
"""

PARK_LEISURE = {"park", "nature_reserve", "garden"}
TRAIL_HIGHWAYS = {"footway", "pedestrian", "path"}


# ---------------------------------------------------------------- geometry

def planar_distance(a, b):
    """RouteGeometry.planarDistance: equirectangular, cos at A's latitude —
    argument order matters at metre scale, keep each call site's."""
    dx = (a[1] - b[1]) * M_PER_DEG_LAT * math.cos(math.radians(a[0]))
    dy = (a[0] - b[0]) * M_PER_DEG_LAT
    return math.hypot(dx, dy)


def ring_area_m2(ring):
    """RingMath.areaM2: planar shoelace with cos-lat scaling at ring[0]."""
    if len(ring) < 3:
        return 0.0
    m_per_deg_lng = M_PER_DEG_LAT * math.cos(math.radians(ring[0][0]))
    total = 0.0
    j = len(ring) - 1
    for i in range(len(ring)):
        xi = ring[i][1] * m_per_deg_lng
        yi = ring[i][0] * M_PER_DEG_LAT
        xj = ring[j][1] * m_per_deg_lng
        yj = ring[j][0] * M_PER_DEG_LAT
        total += (xj + xi) * (yj - yi)
        j = i
    return abs(total) / 2


def ring_centroid(ring):
    """RingMath.centroid: vertex mean, the repeated closing vertex dropped.
    The mint-progress zone id derives from this — formula is frozen."""
    if not ring:
        return (0.0, 0.0)
    points = list(ring)
    if (len(points) > 1
            and abs(points[0][0] - points[-1][0]) < 1e-9
            and abs(points[0][1] - points[-1][1]) < 1e-9):
        points.pop()
    lat = sum(p[0] for p in points) / len(points)
    lng = sum(p[1] for p in points) / len(points)
    return (lat, lng)


def ring_scaled(ring, center, k):
    """RingMath.scaled: shape-preserving growth about a point."""
    if k == 1:
        return list(ring)
    return [(center[0] + (p[0] - center[0]) * k,
             center[1] + (p[1] - center[1]) * k) for p in ring]


def ring_decimated(ring, max_vertices):
    """RingMath.decimated: uniform stride down to max_vertices, preserving
    the repeated-first-vertex closure when present."""
    if max_vertices < 4 or len(ring) <= max_vertices:
        return list(ring)
    is_closed = (len(ring) > 1
                 and abs(ring[0][0] - ring[-1][0]) < 1e-9
                 and abs(ring[0][1] - ring[-1][1]) < 1e-9)
    open_ring = list(ring[:-1]) if is_closed else list(ring)
    target = max_vertices - (1 if is_closed else 0)
    if len(open_ring) <= target:
        return list(ring)
    out = [open_ring[i * len(open_ring) // target] for i in range(target)]
    if is_closed:
        out.append(out[0])
    return out


# ---------------------------------------------------- Overpass classification

def classify_zone_elements(payload):
    """OverpassZoneParser.placementData: split the union answer by tags and
    closure. No-go wins over park — a private park is no-go land. Returns
    (parks, trails, no_go_rings); parks are {"name", "ring"} dicts."""
    parks, trails, rings = [], [], []
    for el in payload.get("elements", []):
        if el.get("type") != "way":
            continue
        tags = el.get("tags") or {}
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue
        coords = [(p["lat"], p["lon"]) for p in geom]
        closed = (abs(coords[0][0] - coords[-1][0]) < 1e-6
                  and abs(coords[0][1] - coords[-1][1]) < 1e-6)
        if closed and walkability._is_no_go_tags(tags):
            rings.append(coords)
        elif closed and _is_park_tags(tags):
            parks.append({"name": tags.get("name"), "ring": coords})
        elif not closed and _is_trail_tags(tags):
            trails.append(coords)
    return parks, trails, rings


def _is_park_tags(tags):
    return (tags.get("leisure") in PARK_LEISURE
            or tags.get("landuse") == "recreation_ground")


def _is_trail_tags(tags):
    return (tags.get("highway") in TRAIL_HIGHWAYS
            and tags.get("footway") != "access_aisle"
            and tags.get("indoor") != "yes"
            and tags.get("access") not in ("no", "private")
            and tags.get("foot") not in ("no", "private"))


def fetch_zone_data(lat, lng, deadline=None):
    """One Overpass request for a day's zones; None when unreachable —
    distinct from an answered ([], [], []). Tests patch this."""
    query = ZONE_QUERY_TEMPLATE.format(
        timeout=int(settings.WALKABILITY_TIMEOUT_S) * 2,
        radius=int(zone_rules.SEARCH_RADIUS_M), lat=lat, lng=lng)
    payload = walkability.query_overpass(
        query, timeout=settings.WALKABILITY_TIMEOUT_S * 2, deadline=deadline,
        purpose=f"zones ({lat:.4f},{lng:.4f})")
    if payload is None:
        return None
    return classify_zone_elements(payload)


# ------------------------------------------------------------------ selection

def _vetoed(center, radius_m, ring, no_go):
    """ZoneSelector.vetoed: fail-closed — the anchor or ANY of eight probes
    near the zone's edge inside no-go land drops the candidate."""
    if not no_go:
        return False
    if no_go.contains(center[0], center[1]):
        return True
    if ring is not None and len(ring) >= 4:
        for k in range(8):
            vertex = ring[k * len(ring) // 8]
            lat = center[0] + (vertex[0] - center[0]) * 0.9
            lng = center[1] + (vertex[1] - center[1]) * 0.9
            if no_go.contains(lat, lng):
                return True
        return False
    m_per_deg_lng = M_PER_DEG_LAT * math.cos(math.radians(center[0]))
    for k in range(8):
        theta = k / 8 * 2 * math.pi
        lat = center[0] + 0.8 * radius_m * math.sin(theta) / M_PER_DEG_LAT
        lng = center[1] + 0.8 * radius_m * math.cos(theta) / m_per_deg_lng
        if no_go.contains(lat, lng):
            return True
    return False


def _trail_length_within(radius_m, center, trails):
    """Metres of trail polyline inside the circle — a segment counts when
    its midpoint does (ZoneSelector.trailLength)."""
    total = 0.0
    for trail in trails:
        if len(trail) < 2:
            continue
        for i in range(1, len(trail)):
            a, b = trail[i - 1], trail[i]
            mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            if planar_distance(mid, center) <= radius_m:
                total += planar_distance(a, b)
    return total


def select_zones(parks, trails, no_go_rings, user_lat, user_lng, day,
                 source="server"):
    """ZoneSelector.select, draw-for-draw: score parks by area + trail
    metres, veto fail-closed, seeded weighted pick from the top eight with
    separation enforced as we go. Returns zone dicts ready to serialize."""
    no_go = walkability.NoGoZones(no_go_rings)
    trails_known = bool(trails)
    use_rings = source != "localsearch"
    user = (user_lat, user_lng)

    candidates = []
    for park in parks:
        ring = park["ring"]
        area = ring_area_m2(ring)
        if area < zone_rules.MIN_PARK_AREA_M2:
            continue
        center = ring_centroid(ring)
        if planar_distance(center, user) > zone_rules.SEARCH_RADIUS_M:
            continue
        radius = min(max(math.sqrt(area / math.pi) * 1.1,
                         zone_rules.MIN_ZONE_RADIUS_M),
                     zone_rules.MAX_ZONE_RADIUS_M)
        zone_ring = None
        if use_rings:
            k = min(max(math.sqrt(zone_rules.TARGET_ZONE_AREA_M2 / area), 1),
                    zone_rules.MAX_RING_SCALE)
            zone_ring = ring_decimated(ring_scaled(ring, center, k),
                                       zone_rules.MAX_RING_VERTICES)
        if _vetoed(center, radius, zone_ring, no_go):
            continue
        trail_m = _trail_length_within(radius, center, trails)
        if trails_known and trail_m < zone_rules.MIN_TRAIL_LENGTH_M:
            continue
        area_score = min(area, 300_000) / 300_000
        trail_score = min(trail_m, 5_000) / 5_000
        score = (0.5 * area_score + 0.5 * trail_score if trails_known
                 else area_score)
        candidates.append({"center": center, "radius_m": radius,
                           "ring": zone_ring, "name": park["name"],
                           "score": max(score, 0.01)})
    if not candidates:
        return []

    # Top eight by (score, lat, lng) descending — coordinate tie-break so
    # equal scores can't make the day's pick depend on input order.
    pool = sorted(candidates,
                  key=lambda c: (c["score"], c["center"][0], c["center"][1]),
                  reverse=True)[:8]
    rng = SplitMix64(stable_seed_daily(day, user_lat, user_lng,
                                       salt=zone_rules.ZONE_PICK_SALT))
    remaining = list(pool)
    picked = []
    while len(picked) < zone_rules.MAX_ZONE_COUNT and remaining:
        total = sum(c["score"] for c in remaining)
        roll = rng.next_unit_double() * total
        index = len(remaining) - 1
        for i, candidate in enumerate(remaining):
            roll -= candidate["score"]
            if roll <= 0:
                index = i
                break
        choice = remaining.pop(index)
        separated = all(
            planar_distance(p["center"], choice["center"])
            >= zone_rules.MIN_SEPARATION_FACTOR * (p["radius_m"] + choice["radius_m"])
            for p in picked)
        if separated:
            picked.append(choice)

    return [{
        "id": stable_zone_id(day, c["center"][0], c["center"][1]),
        "name": c["name"] or "Green Zone",
        "lat": c["center"][0],
        "lng": c["center"][1],
        "radius_m": c["radius_m"],
        "ring": c["ring"],
        "day": day,
        "source": source,
    } for c in picked]


# ------------------------------------------------------------------- serving

def _cell_key(day, lat, lng):
    # The same ~500 m cell grid as StableSeed.daily, so everyone who would
    # compute the same seed shares one cached answer.
    return f"zones:v1:{day}:{round(lat / 0.005)}:{round(lng / 0.005)}"


def serve_zones(lat, lng, day):
    """The day's zones near a point: cache, else fetch + select + persist.
    None means Overpass was unreachable AND no cached answer exists — the
    endpoint 503s so the client's own provider chain takes over."""
    key = _cell_key(day, lat, lng)
    cached = cache.get(key)
    if cached is not None:
        return cached
    data = fetch_zone_data(lat, lng)
    if data is None:
        return None
    parks, trails, rings = data
    zones = select_zones(parks, trails, rings, lat, lng, day)
    cache.set(key, zones, ZONE_CACHE_TTL_S)
    _persist(zones)
    log.info("zones: %d selected for day %d near (%.4f, %.4f) from %d "
             "park(s), %d trail(s), %d no-go ring(s)",
             len(zones), day, lat, lng, len(parks), len(trails), len(rings))
    return zones


def _persist(zones):
    """Upsert served zones so mint claims can be checked against zones that
    actually existed — the read path stays cache-only."""
    from .models import Zone
    for z in zones:
        Zone.objects.update_or_create(
            id=z["id"],
            defaults={"day": z["day"], "name": z["name"], "lat": z["lat"],
                      "lng": z["lng"], "radius_m": z["radius_m"],
                      "ring": z["ring"], "source": z["source"]})
