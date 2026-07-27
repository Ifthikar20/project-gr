"""The 14 /v1 endpoints (docs/06, docs/11), wire-compatible with the iOS
HTTPGemRunAPI client: snake_case JSON, ISO-8601 timestamps without fractional
seconds, encoded polylines, fuzzed Rare+ drops, idempotent run completion.
"""
import hashlib
import json
import math
import secrets
import uuid
from datetime import datetime, timedelta, timezone as tz

from django.conf import settings
from django.db import transaction
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from . import catalog, rules, system_drops, validation, walkability
from .geometry import RouteGeometry, polyline_decode
from .models import GemDrop, Profile, Route, Run, StashItem, Token

FUZZ_RADIUS_M = 150


# ---------------------------------------------------------------- helpers

def iso(dt):
    return dt.astimezone(tz.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def problem(status, title, code=None, detail=None):
    return JsonResponse({"title": title, "detail": detail, "code": code},
                        status=status, content_type="application/problem+json")


def body_of(request):
    try:
        return json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return None


def profile_from(request):
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        token = Token.objects.filter(key=header[7:]).select_related("profile").first()
        if token:
            return token.profile
    if settings.ALLOW_ALL_ACCOUNTS:
        # Dev flag (mirrors iOS AuthFlags.allowAllAccounts): unauthenticated
        # calls act as a shared dev profile instead of failing.
        profile, _ = Profile.objects.get_or_create(
            auth_provider="guest", external_user_id="dev-fallback",
            defaults={"handle": "runner"})
        return profile
    return None


def profile_json(p):
    return {"id": str(p.id), "handle": p.handle, "avatar_url": None,
            "xp": p.xp, "level": p.level,
            "streak_count": p.streak_count, "streak_shields": p.streak_shields}


def drop_json(d, exact=True):
    payload = {"id": str(d.id), "gem_id": str(d.gem_id), "rarity": d.rarity,
               "lat": d.lat, "lng": d.lng,
               "position_along_route_m": d.position_along_route_m,
               "respawn_rule": d.respawn_rule, "placed_by": d.placed_by,
               "fuzz_radius_m": None}
    if not exact:
        # Deterministic jitter (≤ ~75 m) so the fuzz circle doesn't leak the
        # exact spot at its center (docs/06).
        seed = hashlib.sha256(str(d.id).encode()).digest()
        angle = seed[0] / 255 * 2 * math.pi
        dist = 30 + seed[1] / 255 * 45
        payload["lat"] += dist * math.sin(angle) / 111_320
        payload["lng"] += dist * math.cos(angle) / (111_320 * math.cos(math.radians(d.lat)))
        payload["fuzz_radius_m"] = FUZZ_RADIUS_M
    return payload


def route_json(route, viewer=None):
    collected_drop_ids = set()
    if viewer is not None:
        collected_drop_ids = set(
            StashItem.objects.filter(profile=viewer, gem_drop__route=route)
            .values_list("gem_drop_id", flat=True))
    drops = []
    for d in route.gem_drops.filter(active=True):
        exact = (d.rarity in ("common", "uncommon")) or (d.id in collected_drop_ids)
        drops.append(drop_json(d, exact=exact))
    return {"id": str(route.id), "name": route.name, "description": route.description,
            "polyline": route.polyline, "distance_m": route.distance_m,
            "elevation_gain_m": route.elevation_gain_m,
            "difficulty": route.difficulty, "status": route.status,
            "creator_handle": route.creator.handle if route.creator else None,
            "run_count": route.run_count, "gem_drops": drops,
            "elevation_profile": route.elevation_profile}


# ---------------------------------------------------------------- auth & user

@csrf_exempt
@require_http_methods(["POST"])
def auth_provider(request, provider):
    if provider not in ("apple", "google"):
        return problem(404, "Unknown auth provider")
    data = body_of(request)
    if data is None:
        return problem(400, "Invalid JSON")
    external_id = data.get("external_user_id")
    if not settings.ALLOW_ALL_ACCOUNTS:
        # Token verification (Apple identityToken / Google idToken) lands here.
        return problem(501, "Identity token verification not yet enabled",
                       code="auth_strict_mode")
    handle = (data.get("handle") or "runner").strip() or "runner"
    profile = None
    if external_id:
        profile = Profile.objects.filter(auth_provider=provider,
                                         external_user_id=external_id).first()
    if profile is None:
        profile = Profile.objects.create(handle=handle, auth_provider=provider,
                                         external_user_id=external_id)
    else:
        profile.handle = handle
        profile.save(update_fields=["handle"])
    token = Token.objects.create(key=secrets.token_hex(24), profile=profile)
    return JsonResponse({"token": token.key, "profile": profile_json(profile)})


@csrf_exempt
@require_http_methods(["GET", "PATCH", "DELETE"])
def me(request):
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    if request.method == "GET":
        return JsonResponse(profile_json(profile))
    if request.method == "PATCH":
        data = body_of(request) or {}
        if handle := (data.get("handle") or "").strip():
            profile.handle = handle
            profile.save(update_fields=["handle"])
        return JsonResponse(profile_json(profile))
    profile.delete()   # DELETE — cascades runs/stash/tokens (App Store requirement)
    return JsonResponse({})


# ---------------------------------------------------------------- routes

@csrf_exempt
@require_http_methods(["GET", "POST"])
def routes(request):
    if request.method == "GET":
        try:
            lat = float(request.GET["lat"])
            lng = float(request.GET["lng"])
            radius = int(request.GET.get("radius_m", 5000))
        except (KeyError, ValueError):
            return problem(400, "lat, lng and radius_m are required")
        dlat = radius / 111_320
        dlng = radius / (111_320 * max(0.1, math.cos(math.radians(lat))))
        viewer = profile_from(request)
        qs = (Route.objects.filter(status="published",
                                   lat__gte=lat - dlat, lat__lte=lat + dlat,
                                   lng__gte=lng - dlng, lng__lte=lng + dlng)
              .order_by("name"))
        return JsonResponse({"routes": [route_json(r, viewer) for r in qs]})
    return publish_route(request)


def publish_route(request):
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    data = body_of(request)
    if not data or not data.get("polyline") or not data.get("name"):
        return problem(400, "name and polyline are required")

    coords = polyline_decode(data["polyline"])
    if len(coords) < 2:
        return problem(422, "Polyline too short")
    geom = RouteGeometry(coords)
    distance_m = int(round(geom.total_length_m))
    # 2% tolerance: polyline encoding quantizes to ~1.1 m per vertex, so an
    # exactly-1 km client route can decode a few meters short.
    if distance_m < 980:
        return problem(422, "Routes must be at least 1 km")

    drops = data.get("gem_drops") or []
    errors = validate_placement(drops, distance_m, geom)
    if errors:
        return problem(422, "Gem placement rejected", code="placement",
                       detail="; ".join(errors))

    difficulty = "easy" if distance_m < 4000 else "moderate" if distance_m < 9000 else "hard"
    route = Route.objects.create(
        id=uuid.UUID(data["id"]) if data.get("id") else uuid.uuid4(),
        creator=profile, name=data["name"][:40],
        description=(data.get("description") or None),
        polyline=data["polyline"], distance_m=distance_m,
        elevation_gain_m=int(data.get("elevation_gain_m") or 0),
        elevation_profile=data.get("elevation_profile"),
        difficulty=difficulty, status="published",
        lat=coords[0][0], lng=coords[0][1])
    for d in drops:
        GemDrop.objects.create(
            id=uuid.UUID(d["id"]) if d.get("id") else uuid.uuid4(),
            route=route, gem_id=uuid.UUID(d["gem_id"]), rarity=d["rarity"],
            lat=d["lat"], lng=d["lng"],
            position_along_route_m=int(d["position_along_route_m"]),
            respawn_rule=d.get("respawn_rule")
                or ("daily" if d["rarity"] in ("common", "uncommon") else "once_per_user"),
            placed_by="creator")
    return JsonResponse(route_json(route, profile))


def validate_placement(drops, distance_m, geom):
    """Server-side re-check of the docs/02 budget the client already enforced."""
    errors = []
    if len(drops) > rules.budget_slots(distance_m):
        errors.append("too many gems (1 slot per 250 m)")
    points = 0
    positions = []
    for d in drops:
        rarity = d.get("rarity")
        if rarity == "legendary":
            errors.append("legendary gems are system-seeded only")
            continue
        cost = rules.PLACEMENT_COST.get(rarity)
        if cost is None:
            errors.append(f"unknown rarity {rarity!r}")
            continue
        points += cost
        pos = int(d["position_along_route_m"])
        positions.append(pos)
        if rarity in ("rare", "epic") and pos < distance_m * rules.RARE_MIN_ROUTE_FRACTION:
            errors.append(f"{rarity} gems must be at least 40% into the route")
        # Matches the client's offline approximation until terrain data exists.
        if rarity == "epic" and distance_m < 8000:
            errors.append("epic gems need a route of at least 8 km")
    if points > rules.budget_points(distance_m):
        errors.append("rarity-point budget exceeded")
    positions.sort()
    for a, b in zip(positions, positions[1:]):
        if b - a < rules.MIN_GEM_SPACING_M:
            errors.append("gems must be at least 100 m apart")
            break
    return errors


@csrf_exempt
@require_http_methods(["GET", "PATCH", "DELETE"])
def route_detail(request, route_id):
    route = Route.objects.filter(id=route_id).first()
    if route is None or route.status == "archived":
        return problem(404, "Route not found")
    if request.method == "GET":
        return JsonResponse(route_json(route, profile_from(request)))
    profile = profile_from(request)
    if profile is None or route.creator_id != profile.id:
        return problem(403, "Only the creator can modify a route")
    if request.method == "PATCH":
        data = body_of(request) or {}
        if name := (data.get("name") or "").strip():
            route.name = name[:40]
        if "description" in data:
            route.description = data["description"]
        route.save()
        return JsonResponse(route_json(route, profile))
    route.status = "archived"   # DELETE = soft archive
    route.save(update_fields=["status"])
    return JsonResponse({})


# ---------------------------------------------------------------- runs

@csrf_exempt
@require_http_methods(["POST"])
def start_run(request):
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    data = body_of(request) or {}
    route = Route.objects.filter(id=data.get("route_id")).first()
    if route is None:
        return problem(404, "Route not found")
    # Exact coordinates for every active drop so offline collection works.
    exact = [drop_json(d, exact=True) for d in route.gem_drops.filter(active=True)]
    return JsonResponse({"run_id": str(uuid.uuid4()), "exact_drops": exact})


@csrf_exempt
@require_http_methods(["POST"])
@transaction.atomic
def complete_run(request, route_id):
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    route = Route.objects.filter(id=route_id).first()
    if route is None:
        return problem(404, "Route not found")
    data = body_of(request)
    if not data or not data.get("idempotency_key"):
        return problem(400, "idempotency_key is required")

    # Idempotency: same key → the stored verdict, no double awards.
    existing = Run.objects.filter(profile=profile,
                                  idempotency_key=data["idempotency_key"]).first()
    if existing is not None and existing.verdict is not None:
        return JsonResponse(existing.verdict)

    track = data.get("track") or []
    claimed = [uuid.UUID(c) for c in (data.get("claimed_collections") or [])]
    started_at = parse_iso(data["started_at"]) if data.get("started_at") else datetime.now(tz.utc)

    geom = RouteGeometry(polyline_decode(route.polyline))
    verdict_v = validation.validate(track, geom)
    drops = {d.id: d for d in route.gem_drops.filter(active=True)}
    replayed = validation.replay_collections(
        geom,
        [{"id": d.id, "lat": d.lat, "lng": d.lng,
          "position_along_route_m": d.position_along_route_m} for d in drops.values()],
        track)

    now = datetime.now(tz.utc)
    awarded, revoked = [], []
    if verdict_v["status"] != "invalid":
        for drop_id in claimed:
            drop = drops.get(drop_id)
            if drop is None or drop_id not in replayed or not claim_respawn(profile, drop, now):
                revoked.append(str(drop_id))
                continue
            awarded.append(drop)
    else:
        revoked = [str(c) for c in claimed]

    # Standalone drops (system or runner-left) whose coordinates this track
    # crossed: claimed here too, first-come-first-served (docs/13).
    crossed = []
    if verdict_v["status"] != "invalid":
        crossed = claim_crossed_standalone_drops(profile, track)

    streak_extended = update_streak(profile, verdict_v)
    xp = 0
    if verdict_v["status"] != "invalid":
        xp = validation.xp_for([d.rarity for d in awarded], verdict_v["is_walk"],
                               profile.streak_count)
        # Crossed standalone drops score plain rarity XP (same as /drops/collect).
        xp += sum(rules.XP_BY_RARITY[d.rarity] for d in crossed)
        profile.xp += xp
        while profile.xp >= rules.xp_to_advance(profile.level):
            profile.xp -= rules.xp_to_advance(profile.level)
            profile.level += 1
    profile.save()

    run = Run.objects.create(
        profile=profile, route=route, idempotency_key=data["idempotency_key"],
        started_at=started_at, duration_s=verdict_v["duration_s"],
        distance_m=verdict_v["distance_m"], pace_s_per_km=verdict_v["pace_s_per_km"],
        is_walk=verdict_v["is_walk"], status=verdict_v["status"], xp_earned=xp)
    route.run_count += 1
    route.save(update_fields=["run_count"])

    for drop in awarded:
        is_first = (drop.respawn_rule == "one_time"
                    and not StashItem.objects.filter(gem_drop=drop).exists())
        StashItem.objects.create(profile=profile, gem_id=drop.gem_id, gem_drop=drop,
                                 run=run, collected_at=now, is_first_find=is_first)
    for drop in crossed:
        StashItem.objects.create(profile=profile, gem_id=drop.gem_id, gem_drop=drop,
                                 run=run, collected_at=now, is_first_find=True)

    rank = None
    if verdict_v["status"] == "valid" and not verdict_v["is_walk"]:
        faster = (Run.objects.filter(route=route, status="valid", is_walk=False,
                                     duration_s__lt=verdict_v["duration_s"])
                  .exclude(id=run.id).count())
        rank = faster + 1

    payload = {"status": verdict_v["status"],
               "awarded_drops": [drop_json(d, exact=True) for d in awarded + crossed],
               "revoked": revoked, "xp_earned": xp, "leaderboard_rank": rank,
               "streak_extended": streak_extended}
    run.verdict = payload
    run.save(update_fields=["verdict"])
    return JsonResponse(payload)


def claim_crossed_standalone_drops(profile, track):
    """Active standalone drops from the master table whose coordinates the
    track passed within the collect radius. One-time: the row is atomically
    deactivated so exactly one runner ever gets each drop; never your own.
    Runs inside complete_run's transaction (select_for_update)."""
    if not track:
        return []
    lats = [s["lat"] for s in track]
    lngs = [s["lng"] for s in track]
    margin_lat = rules.DROP_COLLECT_RADIUS_M / 111_320
    margin_lng = rules.DROP_COLLECT_RADIUS_M / (
        111_320 * max(0.1, math.cos(math.radians(lats[0]))))
    candidates = (GemDrop.objects.select_for_update()
                  .filter(route__isnull=True, active=True,
                          lat__gte=min(lats) - margin_lat, lat__lte=max(lats) + margin_lat,
                          lng__gte=min(lngs) - margin_lng, lng__lte=max(lngs) + margin_lng)
                  .exclude(dropped_by=profile))
    claimed = []
    for drop in candidates:
        if not track_passes_near(track, drop.lat, drop.lng):
            continue
        drop.active = False
        drop.save(update_fields=["active"])
        claimed.append(drop)
    return claimed


def claim_respawn(profile, drop, now):
    """Respawn rules as queries (docs/02, docs/05 uniqueness semantics)."""
    qs = StashItem.objects.filter(gem_drop=drop)
    if drop.respawn_rule == "daily":
        return not qs.filter(profile=profile, collected_at__date=now.date()).exists()
    if drop.respawn_rule == "once_per_user":
        return not qs.filter(profile=profile).exists()
    return not qs.filter(profile=profile).exists()   # one_time: once each; first gets the crown


def update_streak(profile, verdict_v):
    """Server-owned streak (docs/02) — replaces the client's clientStreakDays."""
    if verdict_v["status"] == "invalid" \
            or verdict_v["distance_m"] < rules.MIN_VALID_RUN_DISTANCE_M:
        return False
    today = datetime.now(tz.utc).date()
    last = profile.streak_last_date
    if last is not None:
        gap = (today - last).days
        if gap == 0:
            return False
        if gap == 1:
            profile.streak_count += 1
        else:
            missed = gap - 1
            if profile.streak_shields >= missed:
                profile.streak_shields -= missed
                profile.streak_count += 1
            else:
                profile.streak_count = 1
    else:
        profile.streak_count = 1
    if profile.streak_count % rules.SHIELD_EARNED_EVERY_DAYS == 0:
        profile.streak_shields = min(rules.MAX_SHIELDS, profile.streak_shields + 1)
    profile.streak_last_date = today
    return True


# ---------------------------------------------------------------- stash & boards

@csrf_exempt
@require_http_methods(["GET"])
def stash(request):
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    items = [{"id": str(s.id), "gem_id": str(s.gem_id),
              "gem_drop_id": str(s.gem_drop_id), "run_id": str(s.run_id or uuid.UUID(int=0)),
              "collected_at": iso(s.collected_at), "is_first_find": s.is_first_find}
             for s in profile.stash.order_by("-collected_at")]
    return JsonResponse({"items": items})


@csrf_exempt
@require_http_methods(["GET"])
def route_leaderboard(request, route_id):
    window = request.GET.get("window", "all")
    viewer = profile_from(request)
    qs = Run.objects.filter(route_id=route_id, status="valid", is_walk=False)
    if window == "month":
        qs = qs.filter(started_at__gte=datetime.now(tz.utc) - timedelta(days=31))
    best = {}
    for run in qs.select_related("profile"):
        cur = best.get(run.profile_id)
        if cur is None or run.duration_s < cur.duration_s:
            best[run.profile_id] = run
    rows = sorted(best.values(), key=lambda r: r.duration_s)
    return JsonResponse({"entries": [
        {"rank": i + 1, "handle": r.profile.handle, "level": r.profile.level,
         "best_time_s": r.duration_s,
         "is_me": viewer is not None and r.profile_id == viewer.id}
        for i, r in enumerate(rows)]})


@csrf_exempt
@require_http_methods(["GET"])
def local_leaderboard(request):
    viewer = profile_from(request)
    now = datetime.now(tz.utc)
    week_start = now - timedelta(days=now.weekday(), hours=now.hour,
                                 minutes=now.minute, seconds=now.second)
    totals = {}
    for run in Run.objects.filter(started_at__gte=week_start).select_related("profile"):
        totals.setdefault(run.profile, 0)
        totals[run.profile] += run.xp_earned
    rows = sorted(totals.items(), key=lambda kv: -kv[1])
    return JsonResponse({"entries": [
        {"rank": i + 1, "handle": p.handle, "level": p.level, "best_time_s": xp,
         "is_me": viewer is not None and p.id == viewer.id}
        for i, (p, xp) in enumerate(rows)]})


# ------------------------------------------------- wallet & standalone drops

@csrf_exempt
@require_http_methods(["POST"])
def wallet_sync(request):
    """Mint wallet gems from total lifetime run distance (Apple Health,
    client-reported — trusted while the accept-all dev flag is on)."""
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    data = body_of(request) or {}
    try:
        total_km = max(0.0, float(data.get("total_run_km", 0)))
    except (TypeError, ValueError):
        return problem(400, "total_run_km must be a number")
    wallet = dict(profile.wallet or {})
    minted = dict(profile.wallet_minted or {})
    for tier, threshold in rules.MINT_THRESHOLD_KM.items():
        earned = int(total_km // threshold)
        delta = earned - int(minted.get(tier, 0))
        if delta > 0:
            wallet[tier] = int(wallet.get(tier, 0)) + delta
            minted[tier] = earned
    profile.wallet = wallet
    profile.wallet_minted = minted
    profile.save(update_fields=["wallet", "wallet_minted"])
    return JsonResponse({"wallet": wallet})


@csrf_exempt
@require_http_methods(["GET", "POST"])
def drops(request):
    profile = profile_from(request)
    if request.method == "GET":
        try:
            lat = float(request.GET["lat"])
            lng = float(request.GET["lng"])
            radius = int(request.GET.get("radius_m", 5000))
        except (KeyError, ValueError):
            return problem(400, "lat, lng and radius_m are required")
        # Presence trigger (docs/13): this map query's coordinates ARE the
        # capture point — top up system gems here before answering, so gems
        # only ever spawn where people actually use the app. Best-effort:
        # a top-up failure must never break the map read.
        try:
            system_drops.top_up_area(lat, lng, radius)
        except Exception:
            pass
        dlat = radius / 111_320
        dlng = radius / (111_320 * max(0.1, math.cos(math.radians(lat))))
        qs = GemDrop.objects.filter(route__isnull=True, active=True,
                                    lat__gte=lat - dlat, lat__lte=lat + dlat,
                                    lng__gte=lng - dlng, lng__lte=lng + dlng)
        return JsonResponse({"drops": [drop_json(d, exact=True) for d in qs]})

    # POST — drop a wallet gem anywhere on the map.
    if profile is None:
        return problem(401, "Sign in required")
    data = body_of(request) or {}
    gem_id = data.get("gem_id")
    entry = catalog.entry_for(uuid.UUID(gem_id)) if gem_id else None
    if entry is None:
        return problem(422, "Unknown gem")
    rarity = entry["rarity"]
    if rarity == "legendary":
        return problem(422, "Legendary gems cannot be dropped")
    wallet = dict(profile.wallet or {})
    if int(wallet.get(rarity, 0)) < 1:
        return problem(422, "No gem of that rarity in your wallet",
                       code="wallet_empty")
    try:
        lat, lng = float(data["lat"]), float(data["lng"])
    except (KeyError, TypeError, ValueError):
        return problem(400, "lat and lng are required")
    # Walkability downstream call (docs/13): only a definite "not walkable"
    # rejects — None (check off/unreachable) keeps drops flowing.
    if walkability.is_walkable(lat, lng) is False:
        return problem(422, "Gems can only be dropped on walkable paths",
                       code="not_walkable")
    wallet[rarity] = int(wallet[rarity]) - 1
    profile.wallet = wallet
    profile.save(update_fields=["wallet"])
    drop = GemDrop.objects.create(
        route=None, dropped_by=profile, gem_id=entry["id"], rarity=rarity,
        lat=lat, lng=lng, position_along_route_m=0,
        respawn_rule="one_time", placed_by="creator")
    return JsonResponse(drop_json(drop, exact=True))


@csrf_exempt
@require_http_methods(["POST"])
@transaction.atomic
def collect_drops(request):
    """Free-run collection of standalone drops: the track must pass within
    the collection radius; a drop is one-time — first collector takes it —
    and you can never collect your own."""
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    data = body_of(request) or {}
    track = data.get("track") or []
    claimed = [uuid.UUID(c) for c in (data.get("claimed") or [])]
    now = datetime.now(tz.utc)
    awarded = []
    for drop_id in claimed:
        drop = (GemDrop.objects.select_for_update()
                .filter(id=drop_id, route__isnull=True, active=True).first())
        if drop is None or drop.dropped_by_id == profile.id:
            continue
        if not track_passes_near(track, drop.lat, drop.lng):
            continue
        drop.active = False
        drop.save(update_fields=["active"])
        StashItem.objects.create(profile=profile, gem_id=drop.gem_id,
                                 gem_drop=drop, collected_at=now,
                                 is_first_find=True)
        awarded.append(drop)
    xp = sum(rules.XP_BY_RARITY[d.rarity] for d in awarded)
    if xp:
        profile.xp += xp
        while profile.xp >= rules.xp_to_advance(profile.level):
            profile.xp -= rules.xp_to_advance(profile.level)
            profile.level += 1
        profile.save(update_fields=["xp", "level"])
    return JsonResponse({"awarded_drops": [drop_json(d, exact=True) for d in awarded],
                         "xp_earned": xp})


def track_passes_near(track, lat, lng):
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    for s in track:
        dy = (s["lat"] - lat) * k
        dx = (s["lng"] - lng) * klng
        if math.hypot(dx, dy) <= rules.DROP_COLLECT_RADIUS_M:
            return True
    return False


@csrf_exempt
@require_http_methods(["GET"])
def gem_catalog(request):
    return JsonResponse({"gems": [
        {"id": str(e["id"]), "name": e["name"], "rarity": e["rarity"],
         "set_id": str(e["set_id"]), "icon_ref": e["icon_ref"]}
        for e in catalog.ENTRIES]})
