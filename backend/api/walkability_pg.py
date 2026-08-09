"""PostGIS walkable-geometry source (tier 12k+; docs/20).

The scaling fix for gem population: instead of asking the public Overpass API
for pedestrian ways on every cold map-open (one shared egress IP that Overpass
rate-limits), import an OpenStreetMap extract into PostGIS once and answer from
a local indexed query. Activated by config only — set
GEMRUN_WALKABILITY_SOURCE=postgis and walkability.fetch_placement_data routes
here instead of Overpass; nothing else changes.

## One-time setup (per region)

1. Provision PostGIS (the Postgres cluster from GEMRUN_DB_HOST, or a dedicated
   instance) and `CREATE EXTENSION postgis;`.
2. Import an extract with osm2pgsql (pedestrian ways + the closed no-go
   polygons — parks/golf/school grounds):
       osm2pgsql -d gemrun -c region-latest.osm.pbf
   giving the standard `planet_osm_line` (ways) and `planet_osm_polygon`
   (areas) tables, with a GiST index on `way` (osm2pgsql builds it).
3. Refresh weekly with a scheduled re-import (the map barely moves).

## What's left to implement

Exactly the one function below — fill in the two ST_DWithin queries against
your imported tables and return the same `(ways, rings)` shape the Overpass
path returns. The query shapes are written out as SQL constants so this is a
wiring job, not a design job. Until then, calling it raises a loud error (you
only get here by deliberately flipping the config flag).
"""
import logging

log = logging.getLogger("api.walkability")

# The strict pedestrian network to place gems ON — same highway set as the
# Overpass path's PEDESTRIAN_PLACEMENT_HIGHWAYS, and the same exclusions
# (private/indoor/access-aisle). Meters via geography casts.
WAYS_SQL = """
SELECT ST_AsText(way)
FROM   planet_osm_line
WHERE  highway IN ('footway', 'pedestrian', 'path')
  AND  COALESCE(tags->'footway', '') <> 'access_aisle'
  AND  COALESCE(tags->'indoor',  '') <> 'yes'
  AND  COALESCE(access, '') NOT IN ('no', 'private')
  AND  COALESCE(tags->'foot', '') NOT IN ('no', 'private')
  AND  ST_DWithin(way::geography,
                  ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography,
                  %(radius_m)s);
"""

# The closed no-go polygons to never place gems INSIDE (private grounds).
NO_GO_SQL = """
SELECT ST_AsText(ST_ExteriorRing((ST_Dump(way)).geom))
FROM   planet_osm_polygon
WHERE  (leisure IN ('golf_course', 'park')
        OR landuse IN ('cemetery', 'military')
        OR amenity IN ('school', 'university', 'hospital'))
  AND  ST_DWithin(way::geography,
                  ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography,
                  %(radius_m)s);
"""


def fetch_placement_data_pg(lat, lng, radius_m):
    """Return `(ways, rings)` — lists of `[(lat, lng), …]` coordinate lists —
    for a stocking pass, or `None` if the store is unreachable (same contract
    as walkability.fetch_placement_data's Overpass path, so the caller is
    unchanged). `([], [])` means the area genuinely has no pedestrian ways.

    TODO(scale): run WAYS_SQL and NO_GO_SQL against the imported OSM tables
    (a read-only connection is ideal) and parse the WKT LINESTRINGs into
    coordinate lists. Until wired, this raises so a premature switch is
    obvious in staging rather than silently emptying the map."""
    raise NotImplementedError(
        "GEMRUN_WALKABILITY_SOURCE=postgis is set but the PostGIS source is "
        "not wired yet. Import an OSM extract (see this module's docstring) "
        "and implement fetch_placement_data_pg using WAYS_SQL / NO_GO_SQL, "
        "or set GEMRUN_WALKABILITY_SOURCE=overpass.")
