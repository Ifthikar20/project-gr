"""Cold-start seeding (docs/02): three loops around a center + competitor
profiles with plausible times, so leaderboards read as a live city.

    python manage.py seed --lat 37.7749 --lng -122.4194
"""
import math
import uuid
from datetime import datetime, timedelta, timezone as tz

from django.core.management.base import BaseCommand

from ... import catalog
from ...geometry import RouteGeometry, polyline_encode
from ...models import GemDrop, Profile, Route, Run

COMPETITORS = [("maya.runs", 7), ("dev_collects", 4), ("sam_routes", 11)]

SPECS = [
    ("First Light Loop", 0, 0, 320, [("common", 0.15), ("common", 0.5), ("uncommon", 0.85)]),
    ("Gem Hunter's Circuit", 900, 400, 800,
     [("common", 0.1), ("uncommon", 0.35), ("rare", 0.55), ("uncommon", 0.8)]),
    ("Ridge Endurance Run", -1200, -700, 1450,
     [("common", 0.1), ("rare", 0.45), ("epic", 0.7), ("legendary", 0.78), ("uncommon", 0.9)]),
]


def offset(lat, lng, dlat_m, dlng_m):
    return (lat + dlat_m / 111_320,
            lng + dlng_m / (111_320 * math.cos(math.radians(lat))))


class Command(BaseCommand):
    help = "Seed demo routes, gems, and competitor leaderboard times around a location."

    def add_arguments(self, parser):
        parser.add_argument("--lat", type=float, default=37.7749)
        parser.add_argument("--lng", type=float, default=-122.4194)

    def handle(self, *args, **opts):
        if Route.objects.filter(creator__isnull=True).exists():
            self.stdout.write("Already seeded — skipping.")
            return
        competitors = [
            Profile.objects.create(handle=h, level=lvl, auth_provider="guest")
            for h, lvl in COMPETITORS
        ]
        for name, dlat, dlng, radius, gems in SPECS:
            clat, clng = offset(opts["lat"], opts["lng"], dlat, dlng)
            n = 36
            coords = [offset(clat, clng, radius * math.sin(2 * math.pi * i / n),
                             radius * math.cos(2 * math.pi * i / n))
                      for i in range(n + 1)]
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
            self.stdout.write(f"Seeded {name} ({distance_m} m, {len(gems)} gems)")
