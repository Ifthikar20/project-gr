"""Walkability check — the downstream call (docs/13).

Apple exposes no "list of walkable paths" API, so the authoritative check
asks OpenStreetMap's Overpass API whether a coordinate sits on or near the
pedestrian network: ways tagged with walkable highway values, excluding
motorways/trunks (never listed) and anything marked private or foot=no.

Three-valued result so callers choose their own fail policy:
    True  — a walkable way exists within the radius
    False — Overpass answered and found nothing walkable there
    None  — check disabled (WALKABILITY_MODE != "overpass") or unreachable
"""
import http.client
import json
import logging
import ssl
import time
import urllib.parse
import urllib.request

from django.conf import settings

log = logging.getLogger("api.walkability")

try:
    import certifi
    _SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())
except ImportError:      # certifi missing → default trust store
    _SSL_CONTEXT = None
    # requirements.txt calls this out as a real footgun: stock macOS
    # Pythons ship without linked system certs, so every HTTPS call can
    # fail. Name the root cause once, here, instead of leaving only the
    # per-mirror failure symptoms downstream.
    log.warning("certifi is not installed — falling back to the system "
                "trust store; if every Overpass call fails with SSL "
                "errors, `pip install -r requirements.txt`")

# Pedestrian-legal highway values (OSM wiki: guidelines for pedestrian
# navigation). Motorway/trunk/primary are excluded by omission.
WALKABLE_HIGHWAYS = ("footway|path|pedestrian|steps|track|living_street|"
                     "residential|service|cycleway|bridleway|unclassified")

# Strict subset for VALIDATING pedestrian presence: sidewalks and dedicated
# walking/running trails ONLY. "service" (driveways), "track" (farm/private
# dirt tracks), "cycleway"/"bridleway" (bike/horse infrastructure that often
# parallels private land), and "living_street"/"residential" (road
# centerlines) all produced gems that read as sitting on private property.
# In OSM, sidewalks are highway=footway and trails are highway=path.
PEDESTRIAN_HIGHWAYS = "footway|pedestrian|path|steps"

# Stricter still for PLACING gems — every system gem must sit exactly ON one
# of these. "steps" is excluded here (building-entrance stairs read as
# private property, and stairs are poor run-past collection spots anyway);
# it stays valid for the presence check above.
PEDESTRIAN_PLACEMENT_HIGHWAYS = "footway|pedestrian|path"

# Grounds where a gem must never sit even though a mapped footpath crosses
# them: the path itself usually carries no access tag — the private-ness
# lives on the ENCLOSING polygon (gated grounds, golf courses, school
# yards, military/industrial land, airfields).
NO_GO_AREA_FILTERS = (
    '["access"~"^(private|no)$"]',
    '["leisure"="golf_course"]',
    '["amenity"~"^(school|kindergarten|college|university)$"]',
    '["landuse"~"^(military|industrial|railway)$"]',
    '["aeroway"="aerodrome"]',
)

QUERY_TEMPLATE = """
[out:json][timeout:{timeout}];
way(around:{radius},{lat:.6f},{lng:.6f})
  ["highway"~"^({highways})$"]
  ["foot"!~"^(no|private)$"]
  ["access"!~"^(no|private)$"];
out ids 1;
is_in({lat:.6f},{lng:.6f})->.a;
(
""" + "\n".join(f"  area.a{f};" for f in NO_GO_AREA_FILTERS) + """
);
out ids 1;
"""


WAYS_QUERY_TEMPLATE = """
[out:json][timeout:{timeout}];
way(around:{radius},{lat:.6f},{lng:.6f})
  ["highway"~"^({highways})$"]
  ["foot"!~"^(no|private)$"]
  ["access"!~"^(no|private)$"];
out geom 400;
"""

# ONE request for a stocking pass: the strict pedestrian network AND every
# no-go polygon in the same circle — split client-side by tags/closure.
PLACEMENT_DATA_QUERY_TEMPLATE = """
[out:json][timeout:{timeout}];
(
  way(around:{radius},{lat:.6f},{lng:.6f})
    ["highway"~"^({highways})$"]
    ["foot"!~"^(no|private)$"]
    ["access"!~"^(no|private)$"];
""" + "\n".join(
    f"  way(around:{{radius}},{{lat:.6f}},{{lng:.6f}}){f};"
    for f in NO_GO_AREA_FILTERS) + """
);
out geom 800;
"""


# Circuit breaker: after every mirror fails (usually per-IP rate limiting —
# Overpass is keyless, throttling is its only currency), skip further calls
# for a cooldown instead of stalling each request ~10s on doomed retries.
_down_until = 0.0
CIRCUIT_COOLDOWN_S = 120


def query_overpass(query, timeout, deadline=None, purpose="query"):
    """POST a query to the first Overpass mirror that answers. The main
    public instance rate-limits aggressively, so single-endpoint calls
    failed often; None when every mirror fails. `deadline` (monotonic) caps
    the per-mirror timeout to the caller's remaining budget and skips
    mirrors entirely when under ~1 s remains — inline bootstrap must never
    outlive the map request it rides in.

    `purpose` tags every vendor-call log line with WHY we're calling
    (point-check / ways-fetch + coordinates), so a slow map open can be
    traced to the exact upstream request. GEMRUN_LOG_LEVEL=DEBUG shows the
    per-attempt lines; successes/failures log at INFO/WARNING regardless."""
    global _down_until
    if time.monotonic() < _down_until:
        log.debug("overpass[%s]: circuit open for %.0fs more — skipped",
                  purpose, _down_until - time.monotonic())
        return None            # circuit open — recent total failure
    for url in settings.OVERPASS_URLS:
        effective_timeout = timeout
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining < 1:
                log.debug("overpass[%s]: %.1fs budget left — mirror %s "
                          "skipped", purpose, remaining, url)
                return None    # out of budget — behaves like unreachable
            effective_timeout = min(timeout, remaining)
        request = urllib.request.Request(
            url, data=urllib.parse.urlencode({"data": query}).encode(),
            headers={"User-Agent": "GemRun/0.1 (walkability)"})
        log.debug("overpass[%s]: → POST %s (timeout %.1fs, %d-byte query)",
                  purpose, url, effective_timeout, len(query))
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=effective_timeout,
                                        context=_SSL_CONTEXT) as response:
                payload = json.load(response)
            log.info("overpass[%s]: %s answered in %.1fs (%d elements)",
                     purpose, url, time.monotonic() - started,
                     len(payload.get("elements", [])))
            return payload
        except (OSError, ValueError, http.client.HTTPException) as exc:
            # The exact reason matters — SSL cert failures, timeouts, and
            # rate limits all look like "unreachable" without this line.
            # HTTPException covers truncated bodies (IncompleteRead,
            # LineTooLong), which are not OSErrors and used to escape this
            # loop entirely — crashing `manage.py stock_gems` (and with it
            # run.sh's launch) on a half-answer from a struggling mirror.
            log.warning("overpass[%s]: %s failed after %.1fs: %r",
                        purpose, url, time.monotonic() - started, exc)
    _down_until = time.monotonic() + CIRCUIT_COOLDOWN_S
    log.warning("overpass[%s]: all %d mirror(s) failed (rate limit?) — "
                "pausing checks for %ds; spawning proceeds on trusted "
                "placements", purpose, len(settings.OVERPASS_URLS),
                CIRCUIT_COOLDOWN_S)
    return None


def fetch_walkable_ways(lat, lng, radius_m=2500, highways=WALKABLE_HIGHWAYS,
                        deadline=None):
    """Geometry of walkable ways around a point, as lists of (lat, lng) —
    the real 'walkable path list' used by the seed command to build
    street-following demo routes and by system_drops to place gems. An
    explicit data fetch, so it ignores WALKABILITY_MODE; returns [] when no
    Overpass mirror is reachable (or the caller's deadline is spent).

    Pass highways=PEDESTRIAN_HIGHWAYS to exclude roads/driveways/tracks."""
    query = WAYS_QUERY_TEMPLATE.format(
        timeout=int(settings.WALKABILITY_TIMEOUT_S) * 2, radius=int(radius_m),
        lat=lat, lng=lng, highways=highways)
    payload = query_overpass(
        query, timeout=settings.WALKABILITY_TIMEOUT_S * 2, deadline=deadline,
        purpose=f"ways-fetch ({lat:.4f},{lng:.4f}) r={int(radius_m)}m")
    if payload is None:
        return []
    # Drop closed-ring ways (park loops, roundabouts) — they show as
    # circles on the map and violate the "walking paths only" rule. Also
    # drop parking-lot access aisles and indoor corridors: technically
    # footways, but gems there read as on private/commercial property.
    ways = []
    for el in payload.get("elements", []):
        tags = el.get("tags") or {}
        if tags.get("footway") == "access_aisle" or tags.get("indoor") == "yes":
            continue
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue
        first, last = geom[0], geom[-1]
        if abs(first["lat"] - last["lat"]) < 1e-6 and abs(first["lon"] - last["lon"]) < 1e-6:
            continue
        ways.append([(p["lat"], p["lon"]) for p in geom])
    return ways


def _point_in_ring(lat, lng, ring):
    """Ray casting over a closed ring of (lat, lng) vertices."""
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        lat_i, lng_i = ring[i]
        lat_j, lng_j = ring[j]
        if (lat_i > lat) != (lat_j > lat):
            cross = (lng_j - lng_i) * (lat - lat_i) / ((lat_j - lat_i) or 1e-18) + lng_i
            if lng < cross:
                inside = not inside
        j = i
    return inside


class NoGoZones:
    """Closed no-go polygons (private grounds, golf courses, school yards…)
    with per-ring bbox prefilters, so a placement candidate can be vetoed
    with a cheap point-in-polygon test."""

    def __init__(self, rings):
        self.rings = []
        for ring in rings:
            if len(ring) < 4:
                continue
            lats = [p[0] for p in ring]
            lngs = [p[1] for p in ring]
            self.rings.append((min(lats), max(lats), min(lngs), max(lngs), ring))

    def __bool__(self):
        return bool(self.rings)

    def __len__(self):
        return len(self.rings)

    def contains(self, lat, lng):
        for min_lat, max_lat, min_lng, max_lng, ring in self.rings:
            if not (min_lat <= lat <= max_lat and min_lng <= lng <= max_lng):
                continue
            if _point_in_ring(lat, lng, ring):
                return True
        return False


def _is_no_go_tags(tags):
    return (tags.get("access") in ("private", "no")
            or tags.get("leisure") == "golf_course"
            or tags.get("amenity") in ("school", "kindergarten",
                                       "college", "university")
            or tags.get("landuse") in ("military", "industrial", "railway")
            or tags.get("aeroway") == "aerodrome")


def fetch_placement_data(lat, lng, radius_m, deadline=None):
    """One Overpass request for a stocking pass: `(ways, no_go_rings)` —
    the strict pedestrian network to place ON, and the closed no-go
    polygons to never place INSIDE (a mapped footpath through a golf
    course or gated grounds is real geometry, but not gem territory).
    Multipolygon relations are not resolved in v1; closed ways cover the
    common private grounds. `None` when Overpass is unreachable (or the
    caller's deadline is spent) — distinct from an answered `([], [])`,
    which means the area genuinely has no strict pedestrian ways. The
    daily rotation keys off that difference: no answer must never read
    as "no paths here"."""
    # Data-source seam (docs/20): a locally imported OSM extract in PostGIS
    # replaces the public Overpass dependency at scale. Config-only switch —
    # the caller (fetch_placement_context) is unchanged.
    if settings.WALKABILITY_SOURCE == "postgis":
        from . import walkability_pg
        return walkability_pg.fetch_placement_data_pg(lat, lng, radius_m)
    query = PLACEMENT_DATA_QUERY_TEMPLATE.format(
        timeout=int(settings.WALKABILITY_TIMEOUT_S) * 2, radius=int(radius_m),
        lat=lat, lng=lng, highways=PEDESTRIAN_PLACEMENT_HIGHWAYS)
    payload = query_overpass(
        query, timeout=settings.WALKABILITY_TIMEOUT_S * 2, deadline=deadline,
        purpose=f"placement-data ({lat:.4f},{lng:.4f}) r={int(radius_m)}m")
    if payload is None:
        return None
    network_kinds = set(PEDESTRIAN_PLACEMENT_HIGHWAYS.split("|"))
    ways, rings = [], []
    for el in payload.get("elements", []):
        tags = el.get("tags") or {}
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue
        coords = [(p["lat"], p["lon"]) for p in geom]
        first, last = coords[0], coords[-1]
        closed = (abs(first[0] - last[0]) < 1e-6
                  and abs(first[1] - last[1]) < 1e-6)
        if closed and _is_no_go_tags(tags):
            rings.append(coords)
            continue
        # Network membership mirrors fetch_walkable_ways' filters: open
        # strict-pedestrian ways, no access aisles/indoor corridors, and
        # never anything access/foot-private (the union's no-go branches
        # can return highway-tagged private ways too).
        if (not closed and tags.get("highway") in network_kinds
                and tags.get("footway") != "access_aisle"
                and tags.get("indoor") != "yes"
                and tags.get("access") not in ("no", "private")
                and tags.get("foot") not in ("no", "private")):
            ways.append(coords)
    log.debug("placement-data: %d network way(s), %d no-go ring(s) near "
              "(%.4f, %.4f)", len(ways), len(rings), lat, lng)
    return ways, rings


def is_walkable(lat, lng, radius_m=None, highways=WALKABLE_HIGHWAYS):
    """Pass highways=PEDESTRIAN_HIGHWAYS for the strict presence check
    (sidewalk/trail required — a nearby residential road doesn't count).
    The query also asks Overpass which AREAS enclose the exact point
    (`is_in`): standing inside a golf course, school yard, or
    access=private grounds answers False even when a mapped path is
    within radius."""
    if settings.WALKABILITY_MODE != "overpass":
        return None
    timeout = settings.WALKABILITY_TIMEOUT_S
    radius = int(radius_m or settings.WALKABILITY_RADIUS_M)
    query = QUERY_TEMPLATE.format(
        timeout=int(timeout), radius=radius,
        lat=lat, lng=lng, highways=highways)
    strict = highways == PEDESTRIAN_HIGHWAYS
    payload = query_overpass(
        query, timeout=timeout,
        purpose=f"point-check ({lat:.4f},{lng:.4f}) r={radius}m "
                f"{'strict' if strict else 'full'}")
    if payload is None:
        return None   # every mirror failed — never guess
    elements = payload.get("elements", [])
    if any(el.get("type") == "area" for el in elements):
        return False   # inside no-go grounds — path nearby or not
    return any(el.get("type") == "way" for el in elements)
