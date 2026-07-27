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
import urllib.parse
import urllib.request

from django.conf import settings

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


def is_walkable(lat, lng, radius_m=None):
    if settings.WALKABILITY_MODE != "overpass":
        return None
    timeout = settings.WALKABILITY_TIMEOUT_S
    query = QUERY_TEMPLATE.format(
        timeout=int(timeout), radius=int(radius_m or settings.WALKABILITY_RADIUS_M),
        lat=lat, lng=lng, highways=WALKABLE_HIGHWAYS)
    request = urllib.request.Request(
        settings.OVERPASS_URL,
        data=urllib.parse.urlencode({"data": query}).encode(),
        headers={"User-Agent": "GemRun/0.1 (walkability check)"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except (OSError, ValueError):
        return None   # network/parse failure — never guess
    return bool(payload.get("elements"))
