"""Startup gem stocking (docs/13): run the presence trigger once for a
location so gems exist BEFORE the first map open, and report exactly what
the area holds. run.sh calls this on every backend start; each individual
spawn is also logged by api.system_drops.

    python manage.py stock_gems --lat 37.7749 --lng -122.4194
"""
import math

from django.core.management.base import BaseCommand

from ... import system_drops
from ...models import GemDrop, Route


class Command(BaseCommand):
    help = "Spawn system gems around a location now and print the area's gem inventory."

    def add_arguments(self, parser):
        parser.add_argument("--lat", type=float, default=37.7749)
        parser.add_argument("--lng", type=float, default=-122.4194)
        parser.add_argument("--radius", type=int, default=5000)

    def handle(self, *args, **opts):
        lat, lng, radius = opts["lat"], opts["lng"], opts["radius"]
        created = system_drops.top_up_area(lat, lng, radius)

        dlat = radius / 111_320
        dlng = radius / (111_320 * max(0.1, math.cos(math.radians(lat))))
        box = {"lat__gte": lat - dlat, "lat__lte": lat + dlat,
               "lng__gte": lng - dlng, "lng__lte": lng + dlng}
        routes = Route.objects.filter(status="published", **box)
        standalone = GemDrop.objects.filter(route__isnull=True, active=True,
                                            placed_by="system", **box)
        on_routes = GemDrop.objects.filter(route__in=routes, active=True)

        if created:
            self.stdout.write(self.style.SUCCESS(
                f"Stocked {created} new system gem(s) at startup:"))
            for d in standalone.order_by("-id")[:created]:
                self.stdout.write(f"  + {d.rarity} at ({d.lat:.5f}, {d.lng:.5f})")
        else:
            self.stdout.write("No new gems needed (area already stocked).")
        self.stdout.write(
            f"Gem inventory near ({lat:.4f}, {lng:.4f}): "
            f"{standalone.count()} standalone active, "
            f"{on_routes.count()} on {routes.count()} route(s).")
