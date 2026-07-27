"""System gem drops on popular walkable paths (docs/13).

Popularity comes from our own data: published routes ranked by run_count —
paths users demonstrably run. Every candidate point is sampled from a route
polyline (already snapped to pedestrian directions at creation), then
re-checked against the walkability downstream call when it's enabled.

Created drops land in the GemDrop master table (route=NULL, placed_by=
"system", one_time) and are handed out first-come-first-served: via
POST /v1/drops/collect on free runs, or automatically when a route run's
track crosses them.

    python manage.py drop_gems --max-drops 5 --min-runs 3 [--seed N]
"""
import math
import random

from django.core.management.base import BaseCommand

from ... import catalog, rules, walkability
from ...geometry import RouteGeometry, polyline_decode
from ...models import GemDrop, Route

RARITIES = ["common", "uncommon", "rare", "epic"]   # legendary: never
WEIGHTS = [60, 25, 12, 3]
ATTEMPTS_PER_ROUTE = 8


class Command(BaseCommand):
    help = "Drop system gems on popular (frequently run) walkable paths."

    def add_arguments(self, parser):
        parser.add_argument("--max-drops", type=int, default=5)
        parser.add_argument("--min-runs", type=int, default=3,
                            help="Only routes with at least this many runs qualify.")
        parser.add_argument("--seed", type=int, default=None,
                            help="RNG seed for reproducible placement (tests).")

    def handle(self, *args, **opts):
        rng = random.Random(opts["seed"])
        popular = (Route.objects.filter(status="published",
                                        run_count__gte=opts["min_runs"])
                   .order_by("-run_count"))
        created = 0
        for route in popular:
            if created >= opts["max_drops"]:
                break
            geom = RouteGeometry(polyline_decode(route.polyline))
            if geom.total_length_m <= 0:
                continue
            for _ in range(ATTEMPTS_PER_ROUTE):
                lat, lng = geom.coordinate_at(rng.uniform(0, geom.total_length_m))
                if self.near_existing_drop(lat, lng):
                    continue
                # False = Overpass says not walkable → skip. None = check off
                # or unreachable → trust the route snap (it came from walking
                # directions), True = confirmed.
                if walkability.is_walkable(lat, lng) is False:
                    continue
                rarity = rng.choices(RARITIES, weights=WEIGHTS)[0]
                GemDrop.objects.create(
                    route=None, dropped_by=None,
                    gem_id=catalog.gem_of(rarity)["id"], rarity=rarity,
                    lat=lat, lng=lng, position_along_route_m=0,
                    respawn_rule="one_time", placed_by="system")
                created += 1
                self.stdout.write(
                    f"Dropped {rarity} on '{route.name}' at ({lat:.5f}, {lng:.5f})")
                break
        self.stdout.write(f"Done — {created} system gem(s) dropped.")

    def near_existing_drop(self, lat, lng):
        """Min spacing vs every active standalone drop (same 100 m rule as
        route placement)."""
        spacing = rules.MIN_GEM_SPACING_M
        dlat = spacing / 111_320
        dlng = spacing / (111_320 * max(0.1, math.cos(math.radians(lat))))
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
