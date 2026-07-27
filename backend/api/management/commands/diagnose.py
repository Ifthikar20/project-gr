"""One-shot answer to "why don't I see gems?" — checks every link of the
gem-population chain (docs/13) around a coordinate and says which one is
broken.

    python manage.py diagnose --lat 37.7749 --lng -122.4194
"""
import math

from django.conf import settings
from django.core.management.base import BaseCommand

from ... import walkability
from ...models import GemDrop, Route


class Command(BaseCommand):
    help = "Explain gem population around a coordinate: data counts + downstream health."

    def add_arguments(self, parser):
        parser.add_argument("--lat", type=float, default=37.7749)
        parser.add_argument("--lng", type=float, default=-122.4194)
        parser.add_argument("--radius", type=int, default=5000)

    def handle(self, *args, **opts):
        lat, lng, radius = opts["lat"], opts["lng"], opts["radius"]
        dlat = radius / 111_320
        dlng = radius / (111_320 * max(0.1, math.cos(math.radians(lat))))
        box = {"lat__gte": lat - dlat, "lat__lte": lat + dlat,
               "lng__gte": lng - dlng, "lng__lte": lng + dlng}

        routes = Route.objects.filter(status="published", **box)
        popular = routes.filter(run_count__gte=settings.PRESENCE_DROP_MIN_RUNS)
        system = GemDrop.objects.filter(route__isnull=True, placed_by="system",
                                        active=True, **box)
        user_drops = GemDrop.objects.filter(route__isnull=True, active=True,
                                            dropped_by__isnull=False, **box)
        route_gems = GemDrop.objects.filter(route__in=routes, active=True)

        w = self.stdout.write
        w(f"Around ({lat:.4f}, {lng:.4f}) radius {radius} m:")
        w(f"  published routes ............ {routes.count()}")
        w(f"  popular routes (>= {settings.PRESENCE_DROP_MIN_RUNS} runs) . {popular.count()}")
        w(f"  gems ON those routes ........ {route_gems.count()}")
        w(f"  standalone system gems ...... {system.count()} (the map's loose pins)")
        w(f"  standalone user drops ....... {user_drops.count()}")
        w(f"  presence trigger ............ {'ON' if settings.PRESENCE_DROPS else 'OFF'} "
          f"(target {settings.PRESENCE_DROP_MAX_PER_AREA}/area)")
        w(f"  walkability mode ............ {settings.WALKABILITY_MODE}")
        if settings.WALKABILITY_MODE == "overpass":
            verdict = walkability.is_walkable(lat, lng)
            w(f"  overpass probe .............. "
              f"{'unreachable (None) — vetoes nothing, gems still spawn' if verdict is None else verdict}")

        w("")
        if not system.exists() and not popular.exists():
            w(self.style.WARNING(
                "→ No system gems or qualifying routes here YET — but bootstrap is "
                f"{'ON' if settings.PRESENCE_BOOTSTRAP else 'OFF'}: the next map open "
                "(GET /v1/drops) stocks this area itself — on OSM walkable ways when "
                "reachable; with no trusted geometry it stays empty (fail closed).\n"
                "  Make sure the app's location matches these coordinates."))
        elif not system.exists():
            w(self.style.WARNING(
                "→ Popular routes exist but no system gems yet: any map open "
                "(GET /v1/drops) will spawn them now."))
        else:
            w(self.style.SUCCESS(
                "→ Healthy: gems exist here. If the app shows none, its location "
                "differs from these coordinates or the build is stale."))
