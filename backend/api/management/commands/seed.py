"""Cold-start seeding (docs/02): demo routes that START at the given
coordinate and follow REAL streets — walkable-way geometry fetched from
OpenStreetMap (walkability.fetch_walkable_ways), chained into out-and-back
loops. Never geometric circles: if no street data is reachable, nothing is
seeded (an empty map is honest; a fake one isn't). Competitor profiles get
plausible times so leaderboards read as a live city.

    python manage.py seed --lat 37.7749 --lng -122.4194
    python manage.py seed --reset          # wipe system demo data first
"""
import math

from django.core.management.base import BaseCommand

from ... import catalog, walkability
from ...geometry import RouteGeometry, polyline_encode
from ...models import GemDrop, Profile, Route, Run
from datetime import datetime, timedelta, timezone as tz

COMPETITORS = [("maya.runs", 7), ("dev_collects", 4), ("sam_routes", 11)]

# (name, target out-and-back distance m, gems as (rarity, fraction-along))
SPECS = [
    ("First Light Loop", 2_000,
     [("common", 0.15), ("common", 0.5), ("uncommon", 0.85)]),
    ("Gem Hunter's Circuit", 5_000,
     [("common", 0.1), ("uncommon", 0.35), ("rare", 0.55), ("uncommon", 0.8)]),
    ("Ridge Endurance Run", 9_500,
     [("common", 0.1), ("rare", 0.45), ("epic", 0.7),
      ("legendary", 0.78), ("uncommon", 0.9)]),
]


def node_key(pt):
    return (round(pt[0], 5), round(pt[1], 5))


def street_route(center, target_m, ways, used):
    """Chain walkable ways into an out-and-back starting as close to
    `center` as the street network allows: walk out to ~half the target
    along connected ways, then retrace home. Returns the coordinate list,
    or None when the reachable network is too short."""
    adjacency = {}
    for i, way in enumerate(ways):
        if i in used:
            continue
        adjacency.setdefault(node_key(way[0]), []).append((i, False))
        adjacency.setdefault(node_key(way[-1]), []).append((i, True))
    if not adjacency:
        return None
    ruler = RouteGeometry([center])
    node = min(adjacency, key=lambda n: ruler.distance(center, n))
    coords, total = [], 0.0
    while total < target_m / 2:
        options = [(i, rev) for i, rev in adjacency.get(node, []) if i not in used]
        if not options:
            break
        idx, reverse = options[0]
        segment = list(reversed(ways[idx])) if reverse else list(ways[idx])
        coords.extend(segment if not coords else segment[1:])
        used.add(idx)
        total = RouteGeometry(coords).total_length_m
        node = node_key(coords[-1])
    if total < max(400.0, target_m * 0.2):
        return None
    return coords + list(reversed(coords))[1:]          # retrace back home


class Command(BaseCommand):
    help = "Seed street-following demo routes, gems, and competitor times around a location."

    def add_arguments(self, parser):
        parser.add_argument("--lat", type=float, default=37.7749)
        parser.add_argument("--lng", type=float, default=-122.4194)
        parser.add_argument("--reset", action="store_true",
                            help="Delete system-seeded routes/drops before seeding.")
        parser.add_argument("--clear", action="store_true",
                            help="Delete system-seeded routes/drops and exit (no reseed).")

    def handle(self, *args, **opts):
        if opts["reset"] or opts["clear"]:
            Route.objects.filter(creator__isnull=True).delete()
            GemDrop.objects.filter(route__isnull=True, dropped_by__isnull=True).delete()
            self.stdout.write("Cleared system demo routes and drops.")
            if opts["clear"]:
                return
        if Route.objects.filter(creator__isnull=True).exists():
            self.stdout.write("Already seeded — skipping.")
            return

        center = (opts["lat"], opts["lng"])
        ways = walkability.fetch_walkable_ways(*center)
        if not ways:
            self.stdout.write(self.style.WARNING(
                "No walkable-way data reachable (Overpass) — seeding no routes. "
                "Routes will appear as users create them."))
            return

        competitors = [
            Profile.objects.get_or_create(handle=h, auth_provider="guest",
                                          defaults={"level": lvl})[0]
            for h, lvl in COMPETITORS
        ]
        used = set()
        for name, target_m, gems in SPECS:
            coords = street_route(center, target_m, ways, used)
            if coords is None:
                self.stdout.write(f"Not enough connected streets for {name} — skipped.")
                continue
            geom = RouteGeometry(coords)
            distance_m = int(geom.total_length_m)
            gain = distance_m // 100
            profile = [int(gain * (0.5 - 0.5 * math.cos(2 * math.pi * i / 40)))
                       for i in range(41)]
            difficulty = ("easy" if distance_m < 4000
                          else "moderate" if distance_m < 9000 else "hard")
            route = Route.objects.create(
                name=name, polyline=polyline_encode(coords), distance_m=distance_m,
                elevation_gain_m=gain, elevation_profile=profile,
                difficulty=difficulty, lat=coords[0][0], lng=coords[0][1])
            for rarity, fraction in gems:
                along = geom.total_length_m * fraction
                lat, lng = geom.coordinate_at(along)
                respawn = ("daily" if rarity in ("common", "uncommon")
                           else "one_time" if rarity == "legendary" else "once_per_user")
                GemDrop.objects.create(route=route, gem_id=catalog.gem_of(rarity)["id"],
                                       rarity=rarity, lat=lat, lng=lng,
                                       position_along_route_m=int(along),
                                       respawn_rule=respawn, placed_by="system")
            # Plausible competitor times: 4:50–6:20 /km.
            for i, competitor in enumerate(competitors):
                Run.objects.create(
                    profile=competitor, route=route,
                    idempotency_key=f"seed-{route.id}-{i}", status="valid",
                    started_at=datetime.now(tz.utc) - timedelta(days=i + 1),
                    duration_s=int(distance_m / 1000 * (290 + i * 45)),
                    distance_m=distance_m, is_walk=False,
                    pace_s_per_km=290 + i * 45,
                    xp_earned=45)
                route.run_count += 1
            route.save(update_fields=["run_count"])
            self.stdout.write(f"Seeded {name} ({distance_m} m on real streets, "
                              f"{len(gems)} gems)")
