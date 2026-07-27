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

# Pedestrian-legal highway values (OSM wiki: guidelines for pedestrian
# navigation). Motorway/trunk/primary are excluded by omission.
WALKABLE_HIGHWAYS = ("footway|path|pedestrian|steps|track|living_street|"
                     "residential|service|cycleway|bridleway|unclassified")

QUERY_TEMPLATE = """
[out:json][timeout:{timeout}];
way(around:{radius},{lat:.6f},{lng:.6f})
  ["highway"~"^({highways})$"]
  ["foot"!~"^(no|private)$"]
  ["access"!~"^(no|private)$"];
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


def query_overpass(query, timeout):
    """POST a query to the first Overpass mirror that answers. The main
    public instance rate-limits aggressively, so single-endpoint calls
    failed often; None when every mirror fails."""
    for url in settings.OVERPASS_URLS:
        request = urllib.request.Request(
            url, data=urllib.parse.urlencode({"data": query}).encode(),
            headers={"User-Agent": "GemRun/0.1 (walkability)"})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=timeout,
                                        context=_SSL_CONTEXT) as response:
                payload = json.load(response)
            log.info("overpass: %s answered in %.1fs (%d elements)",
                     url, time.monotonic() - started, len(payload.get("elements", [])))
            return payload
        except (OSError, ValueError) as exc:
            # The exact reason matters — SSL cert failures, timeouts, and
            # rate limits all look like "unreachable" without this line.
            log.warning("overpass: %s failed after %.1fs: %r",
                        url, time.monotonic() - started, exc)
    log.warning("overpass: all %d mirror(s) failed — walkability unanswerable",
                len(settings.OVERPASS_URLS))
    return None


def fetch_walkable_ways(lat, lng, radius_m=2500):
    """Geometry of walkable ways around a point, as lists of (lat, lng) —
    the real 'walkable path list' used by the seed command to build
    street-following demo routes. An explicit data fetch, so it ignores
    WALKABILITY_MODE; returns [] when no Overpass mirror is reachable."""
    query = WAYS_QUERY_TEMPLATE.format(
        timeout=int(settings.WALKABILITY_TIMEOUT_S) * 2, radius=int(radius_m),
        lat=lat, lng=lng, highways=WALKABLE_HIGHWAYS)
    payload = query_overpass(query, timeout=settings.WALKABILITY_TIMEOUT_S * 2)
    if payload is None:
        return []
    return [[(p["lat"], p["lon"]) for p in el["geometry"]]
            for el in payload.get("elements", [])
            if len(el.get("geometry") or []) >= 2]


def is_walkable(lat, lng, radius_m=None):
    if settings.WALKABILITY_MODE != "overpass":
        return None
    timeout = settings.WALKABILITY_TIMEOUT_S
    query = QUERY_TEMPLATE.format(
        timeout=int(timeout), radius=int(radius_m or settings.WALKABILITY_RADIUS_M),
        lat=lat, lng=lng, highways=WALKABLE_HIGHWAYS)
    payload = query_overpass(query, timeout=timeout)
    if payload is None:
        return None   # every mirror failed — never guess
    return bool(payload.get("elements"))
