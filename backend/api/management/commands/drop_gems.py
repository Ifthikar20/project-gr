"""Global backstop for system gem drops (docs/13).

Day to day, the presence trigger in GET /v1/drops keeps active areas
stocked — the map query's own coordinates are the capture point, so gems
only spawn where people actually use the app. This command is the optional
scheduled sweep over ALL popular routes (e.g. before an event, or to stock
a launch city ahead of users), sharing the same engine in system_drops.py.

    python manage.py drop_gems --max-drops 5 --min-runs 3 [--seed N]
"""
import random

from django.core.management.base import BaseCommand

from ...models import Route
from ...system_drops import drop_gem_on_route


class Command(BaseCommand):
    help = "Drop system gems on popular (frequently run) walkable paths, globally."

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
            drop = drop_gem_on_route(route, rng)
            if drop is not None:
                created += 1
                self.stdout.write(f"Dropped {drop.rarity} on '{route.name}' "
                                  f"at ({drop.lat:.5f}, {drop.lng:.5f})")
        self.stdout.write(f"Done — {created} system gem(s) dropped.")
