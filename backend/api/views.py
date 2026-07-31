"""The 14 /v1 endpoints (docs/06, docs/11), wire-compatible with the iOS
HTTPGemRunAPI client: snake_case JSON, ISO-8601 timestamps without fractional
seconds, encoded polylines, fuzzed Rare+ drops, idempotent run completion.
"""
import hashlib
import json
import logging
import math
import secrets
import uuid
from datetime import datetime, timedelta, timezone as tz

from django.conf import settings
from django.db import transaction
from django.db.models import Prefetch
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from . import catalog, rules, system_drops, validation, walkability
from .geometry import RouteGeometry, polyline_decode
from .models import (ClaimAttempt, Friendship, GemDrop, Profile, Route, Run,
                     StashItem, Token)

FUZZ_RADIUS_M = 150

log = logging.getLogger("api.views")


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


def clean_track(raw):
    """Keep only well-formed GPS samples — numeric t/lat/lng, with accuracy
    and speed defaulted. validation.py and closest_track_distance index
    these keys directly, so one malformed sample in a 1,800-sample track
    used to 500 the whole settlement (rolling back the run, unlogged)."""
    samples = []
    raw = raw if isinstance(raw, list) else []
    for s in raw:
        if not isinstance(s, dict):
            continue
        try:
            samples.append({
                "t": float(s["t"]),
                "lat": float(s["lat"]),
                "lng": float(s["lng"]),
                "horizontal_accuracy": float(s.get("horizontal_accuracy", 0)),
                "speed": float(s.get("speed", 0)),
            })
        except (KeyError, TypeError, ValueError):
            continue
    if len(samples) < len(raw):
        log.warning("track cleaning dropped %d of %d malformed sample(s)",
                    len(raw) - len(samples), len(raw))
    return samples


def digest(value):
    """One-way SHA-256 of a client-held secret/identifier. Auth tokens and
    provider user IDs are stored ONLY as digests — a leaked database holds
    no usable bearer token and no raw Apple/Google identifier. The client
    keeps the raw token; every lookup hashes before comparing."""
    return hashlib.sha256(value.encode()).hexdigest()


def grant_welcome_gift(profile):
    """First-login gift: a deterministic starter set of stash gems (3 common,
    2 uncommon, 1 rare — same for everyone) so a brand-new player opens the
    Stash to real gems and has something to drop for others immediately.
    There is no wallet — these live in the stash like any collected gem."""
    now = datetime.now(tz.utc)
    gifts = (catalog.gems_of("common", 3) + catalog.gems_of("uncommon", 2)
             + catalog.gems_of("rare", 1))
    StashItem.objects.bulk_create([
        StashItem(profile=profile, gem_id=g["id"], gem_drop=None, run=None,
                  source="gift", collected_at=now, is_first_find=False)
        for g in gifts
    ])


def profile_from(request):
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        token = (Token.objects.filter(key=digest(header[7:]))
                 .select_related("profile").first())
        if token:
            return token.profile
    if settings.ALLOW_ALL_ACCOUNTS:
        # Dev flag (mirrors iOS AuthFlags.allowAllAccounts): unauthenticated
        # calls act as a shared dev profile instead of failing. NOT
        # get_or_create: the app fires routes+drops concurrently, and two
        # racing creates once left duplicates that 500'd every request —
        # always take the oldest, tolerate strays.
        profile = (Profile.objects.filter(auth_provider="guest",
                                          external_user_id="dev-fallback")
                   .order_by("created_at").first())
        if profile is None:
            profile = Profile.objects.create(handle="runner", auth_provider="guest",
                                             external_user_id="dev-fallback")
            grant_welcome_gift(profile)
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


def route_json(route, viewer=None, collected_ids=None, active_drops=None):
    """List pages pass `collected_ids` (one stash query for the whole page)
    and `active_drops` (prefetched) so N routes cost a fixed number of
    queries; single-route callers omit both and keep the per-route lookups."""
    if collected_ids is None:
        collected_ids = set()
        if viewer is not None:
            collected_ids = set(
                StashItem.objects.filter(profile=viewer, gem_drop__route=route)
                .values_list("gem_drop_id", flat=True))
    if active_drops is None:
        active_drops = route.gem_drops.filter(active=True)
    drops = []
    for d in active_drops:
        exact = (d.rarity in ("common", "uncommon")) or (d.id in collected_ids)
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
        # This 501s EVERY sign-in — if the flag was flipped before
        # verification shipped, the log is the only place that says so.
        log.warning("sign-in rejected: ALLOW_ALL_ACCOUNTS is off but token "
                    "verification is not implemented (auth_strict_mode)")
        return problem(501, "Identity token verification not yet enabled",
                       code="auth_strict_mode")
    handle = (data.get("handle") or "runner").strip() or "runner"
    # Provider IDs are stored hashed (see digest()) — lookups hash first.
    hashed_external = digest(external_id) if external_id else None
    profile = None
    if hashed_external:
        profile = Profile.objects.filter(auth_provider=provider,
                                         external_user_id=hashed_external).first()
    if profile is None:
        profile = Profile.objects.create(handle=handle, auth_provider=provider,
                                         external_user_id=hashed_external)
        grant_welcome_gift(profile)
    else:
        profile.handle = handle
        profile.save(update_fields=["handle"])
    # The client keeps the raw token; the DB keeps only its digest.
    raw_token = secrets.token_hex(24)
    Token.objects.create(key=digest(raw_token), profile=profile)
    return JsonResponse({"token": raw_token, "profile": profile_json(profile)})


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
            # Renames must be unique (case-insensitive) across everyone
            # else — renaming to your own current handle is a no-op, not
            # a conflict.
            taken = (Profile.objects.filter(handle__iexact=handle)
                     .exclude(id=profile.id).exists())
            if taken:
                return problem(409, "That username is taken",
                               code="handle_taken")
            profile.handle = handle
            profile.save(update_fields=["handle"])
        return JsonResponse(profile_json(profile))
    profile.delete()   # DELETE — cascades runs/stash/tokens (App Store requirement)
    return JsonResponse({})


@csrf_exempt
@require_http_methods(["GET"])
def handle_check(request):
    """Live availability for the Settings username editor: is this handle
    free for the CALLER to take? (Your own current handle counts as free.)"""
    handle = (request.GET.get("handle") or "").strip()
    if len(handle) < 3:
        return JsonResponse({"available": False})
    qs = Profile.objects.filter(handle__iexact=handle)
    viewer = profile_from(request)
    if viewer is not None:
        qs = qs.exclude(id=viewer.id)
    return JsonResponse({"available": not qs.exists()})


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
        # Fixed query count regardless of page size: routes + creators in
        # one, active drops prefetched in one, viewer's collected ids in
        # one — the old shape ran two extra queries PER ROUTE, which sat
        # directly in the map's time-to-reveal path.
        qs = (Route.objects.filter(status="published",
                                   lat__gte=lat - dlat, lat__lte=lat + dlat,
                                   lng__gte=lng - dlng, lng__lte=lng + dlng)
              .order_by("name")
              .select_related("creator")
              .prefetch_related(Prefetch(
                  "gem_drops",
                  queryset=GemDrop.objects.filter(active=True),
                  to_attr="active_drops")))
        page = list(qs)
        collected = set()
        if viewer is not None and page:
            collected = set(
                StashItem.objects.filter(profile=viewer,
                                         gem_drop__route__in=page)
                .values_list("gem_drop_id", flat=True))
        return JsonResponse({"routes": [
            route_json(r, viewer, collected_ids=collected,
                       active_drops=r.active_drops) for r in page]})
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
    # Routes must be open-ended walking paths — no loops, rings, retraces.
    if geom.distance(coords[0], coords[-1]) < 100:
        return problem(422, "Routes must be open-ended paths, not loops",
                       code="loop_rejected")

    drops = data.get("gem_drops") or []
    # Malformed drop entries (bad UUIDs, missing keys, non-numeric
    # positions) are a 422 like any other placement problem — not an
    # unlogged 500 that rolls back the publish.
    try:
        errors = validate_placement(drops, distance_m, geom)
        if errors:
            # The client enforces this same budget offline, so a hit here
            # means a tampered client OR client/server rule drift after a
            # deploy — either way, worth a trace.
            log.warning("route publish rejected for profile %s: %s",
                        profile.id, "; ".join(errors))
            return problem(422, "Gem placement rejected", code="placement",
                           detail="; ".join(errors))

        difficulty = "easy" if distance_m < 4000 else "moderate" if distance_m < 9000 else "hard"
        # Atomic: a malformed drop halfway through the list must not leave
        # a half-published route behind.
        with transaction.atomic():
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
    except (KeyError, TypeError, ValueError) as exc:
        log.warning("route publish payload malformed for profile %s: %r",
                    profile.id, exc)
        return problem(422, "Malformed route payload", code="malformed",
                       detail=repr(exc))
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
        log.warning("route modify denied: profile %s is not the creator of "
                    "route %s", profile.id if profile else None, route.id)
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

    track = clean_track(data.get("track") or [])
    try:
        claimed = [uuid.UUID(c) for c in (data.get("claimed_collections") or [])]
        started_at = (parse_iso(data["started_at"])
                      if data.get("started_at") else datetime.now(tz.utc))
    except (TypeError, ValueError, AttributeError) as exc:
        log.warning("run completion payload malformed for profile %s: %r",
                    profile.id, exc)
        return problem(400, "Malformed completion payload", code="malformed",
                       detail=repr(exc))

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
    # No active filter here either: a crossed-but-taken drop logs a losing
    # ClaimAttempt so races stay observable (see collect_drops).
    candidates = (GemDrop.objects.select_for_update()
                  .filter(route__isnull=True,
                          lat__gte=min(lats) - margin_lat, lat__lte=max(lats) + margin_lat,
                          lng__gte=min(lngs) - margin_lng, lng__lte=max(lngs) + margin_lng))
    claimed = []
    for drop in candidates:
        closest = closest_track_distance(track, drop.lat, drop.lng)
        if closest is None or closest > rules.DROP_COLLECT_RADIUS_M:
            continue   # never crossed — not an attempt, no log
        if drop.dropped_by_id == profile.id:
            log_claim(profile, drop, "route_run", "own_drop", closest)
            continue
        if not drop.active:
            log_claim(profile, drop, "route_run", "already_taken", closest)
            continue
        drop.active = False
        drop.save(update_fields=["active"])
        log_claim(profile, drop, "route_run", "awarded", closest)
        claimed.append(drop)
    return claimed


def log_claim(profile, drop, source, outcome, closest_m):
    ClaimAttempt.objects.create(profile=profile, gem_drop=drop, source=source,
                                outcome=outcome, closest_m=closest_m)


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
              "gem_drop_id": str(s.gem_drop_id or uuid.UUID(int=0)),
              "run_id": str(s.run_id or uuid.UUID(int=0)),
              "collected_at": iso(s.collected_at), "is_first_find": s.is_first_find,
              "source": s.source, "dropped": s.dropped_at is not None}
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


# ------------------------------------------------- my runs, players, friends

def _week_start():
    now = datetime.now(tz.utc)
    return now - timedelta(days=now.weekday(), hours=now.hour,
                           minutes=now.minute, seconds=now.second)


@csrf_exempt
@require_http_methods(["GET"])
def my_runs(request):
    """Completed-run history for the Compete tab's "My Routes" cards —
    server copy of what the phone also stores locally, so a fresh install
    (or second device) can show history."""
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    rows = (Run.objects.filter(profile=profile)
            .select_related("route").order_by("-started_at")[:50])
    return JsonResponse({"runs": [
        {"id": str(r.id), "route_id": str(r.route_id),
         "route_name": r.route.name, "started_at": iso(r.started_at),
         "duration_s": r.duration_s, "distance_m": r.distance_m,
         "pace_s_per_km": r.pace_s_per_km, "is_walk": r.is_walk,
         "status": r.status, "xp_earned": r.xp_earned}
        for r in rows]})


@csrf_exempt
@require_http_methods(["GET"])
def players(request):
    """Username search for the friends board. Case-insensitive substring
    on handle, excluding yourself; capped at 20."""
    profile = profile_from(request)
    query = (request.GET.get("search") or "").strip()
    if len(query) < 2:
        return JsonResponse({"players": []})
    qs = Profile.objects.filter(handle__icontains=query)
    if profile is not None:
        qs = qs.exclude(id=profile.id)
    return JsonResponse({"players": [
        {"id": str(p.id), "handle": p.handle, "level": p.level}
        for p in qs.order_by("handle")[:20]]})


@csrf_exempt
@require_http_methods(["GET", "POST"])
def friends(request):
    """GET: your friends (plus yourself) with this-week stats, ranked by
    weekly XP — the Compete tab's "This Week" board. POST {profile_id}:
    add a friend (one-directional; idempotent)."""
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")

    if request.method == "POST":
        data = body_of(request) or {}
        try:
            friend_id = uuid.UUID(str(data.get("profile_id")))
        except (ValueError, AttributeError, TypeError):
            return problem(400, "profile_id is required")
        if friend_id == profile.id:
            return problem(422, "You're already on your own board")
        friend = Profile.objects.filter(id=friend_id).first()
        if friend is None:
            return problem(404, "No such player")
        Friendship.objects.get_or_create(profile=profile, friend=friend)

    week_start = _week_start()
    members = [profile] + [f.friend for f in
                           profile.friendships.select_related("friend")
                           .order_by("created_at")]
    weekly = {m.id: {"xp": 0, "distance_m": 0, "runs": 0} for m in members}
    for run in Run.objects.filter(profile_id__in=weekly.keys(),
                                  started_at__gte=week_start):
        row = weekly[run.profile_id]
        row["xp"] += run.xp_earned
        row["distance_m"] += run.distance_m
        row["runs"] += 1
    members.sort(key=lambda m: -weekly[m.id]["xp"])
    return JsonResponse({"friends": [
        {"id": str(m.id), "handle": m.handle, "level": m.level,
         "is_me": m.id == profile.id,
         "weekly_xp": weekly[m.id]["xp"],
         "weekly_distance_m": weekly[m.id]["distance_m"],
         "weekly_runs": weekly[m.id]["runs"]}
        for m in members]})


@csrf_exempt
@require_http_methods(["DELETE"])
def friend_detail(request, friend_id):
    """Swipe-to-remove: deletes only YOUR follow row."""
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    Friendship.objects.filter(profile=profile, friend_id=friend_id).delete()
    return JsonResponse({})


# ------------------------------------------------- standalone drops

@csrf_exempt
@require_http_methods(["GET", "POST"])
def drops(request):
    if request.method == "GET":
        # No profile lookup on the read path — the GET branch never uses
        # it, and it used to cost a Token/Profile query per map open.
        try:
            lat = float(request.GET["lat"])
            lng = float(request.GET["lng"])
            radius = int(request.GET.get("radius_m", 5000))
        except (KeyError, ValueError):
            return problem(400, "lat, lng and radius_m are required")
        # Presence trigger (docs/13, docs/14 §2.1): this map query's
        # coordinates ARE the capture point. Warm miles hand rotation +
        # top-up to a background worker and answer instantly; only
        # first-contact bootstrap runs inline (budget-bounded) so the
        # first-ever answer is already stocked. Best-effort: a trigger
        # failure must never break the map read. The client's radius_m is
        # a READ radius only — the stocking budget is the per-mile
        # contract, independent of how much map the client wants to see.
        try:
            stocking = system_drops.presence_trigger(lat, lng)
        except Exception:
            # Still best-effort — the map read must survive — but never
            # silent: this swallow used to hide the entire stocking
            # pipeline (DB lock exhaustion, executor failures, placement
            # bugs) while every response stayed a clean 200.
            log.exception("presence trigger failed at (%.4f, %.4f) — "
                          "serving the map read without restocking",
                          lat, lng)
            stocking = False
        dlat = radius / 111_320
        dlng = radius / (111_320 * max(0.1, math.cos(math.radians(lat))))
        qs = GemDrop.objects.filter(route__isnull=True, active=True,
                                    lat__gte=lat - dlat, lat__lte=lat + dlat,
                                    lng__gte=lng - dlng, lng__lte=lng + dlng
                                    ).order_by("-created_at")[:200]
        # `stocking`: a background job is restocking/rotating this area
        # right now — the client shows "Stocking gems near you…" and looks
        # again in a few seconds instead of sitting on the thin answer.
        return JsonResponse({"drops": [drop_json(d, exact=True) for d in qs],
                             "stocking": stocking})

    # POST — give one of your stash gems away as a map drop. The stash row
    # stays (collection record) but is marked dropped and can't be re-spent.
    profile = profile_from(request)
    if profile is None:
        return problem(401, "Sign in required")
    data = body_of(request) or {}
    gem_id = data.get("gem_id")
    try:
        entry = catalog.entry_for(uuid.UUID(gem_id)) if gem_id else None
    except (ValueError, AttributeError, TypeError):
        entry = None
    if entry is None:
        # A well-formed UUID that isn't in the catalog means the app build
        # and server build disagree about the shared catalog — not a user
        # mistake.
        log.warning("drop rejected: unknown gem id %r from profile %s",
                    gem_id, profile.id)
        return problem(422, "Unknown gem")
    rarity = entry["rarity"]
    if rarity == "legendary":
        return problem(422, "Legendary gems cannot be dropped")
    try:
        lat, lng = float(data["lat"]), float(data["lng"])
    except (KeyError, TypeError, ValueError):
        return problem(400, "lat and lng are required")
    # Walkability downstream call (docs/13): only a definite "not walkable"
    # rejects — None (check off/unreachable) keeps drops flowing. STRICT
    # list: a player drop needs a real sidewalk/trail nearby; a residential
    # road or driveway does not count.
    if walkability.is_walkable(
            lat, lng, highways=walkability.PEDESTRIAN_HIGHWAYS) is False:
        # Only a definite "no" from OSM lands here — a spike in these is an
        # upstream data/query regression, not a user-behavior change.
        log.warning("drop rejected as not walkable at (%.5f, %.5f)", lat, lng)
        return problem(422, "Gems can only be dropped on walkable paths",
                       code="not_walkable")
    with transaction.atomic():
        # Oldest droppable copy of this gem; locked so two racing drops of
        # a player's single copy can't both spend it.
        item = (StashItem.objects.select_for_update()
                .filter(profile=profile, gem_id=entry["id"],
                        dropped_at__isnull=True)
                .order_by("collected_at").first())
        if item is None:
            # Inside the row lock: this can be a legitimately empty stash,
            # or the losing side of a double-spend race — exactly what the
            # lock exists to catch, so leave a trace either way.
            log.warning("drop rejected: gem %s not spendable in stash for "
                        "profile %s (empty or lost double-spend race)",
                        entry["id"], profile.id)
            return problem(422, "That gem isn't in your stash",
                           code="not_in_stash")
        item.dropped_at = datetime.now(tz.utc)
        item.save(update_fields=["dropped_at"])
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
    track = clean_track(data.get("track") or [])
    try:
        claimed = [uuid.UUID(c) for c in (data.get("claimed") or [])]
    except (TypeError, ValueError, AttributeError) as exc:
        log.warning("collect payload malformed for profile %s: %r",
                    profile.id, exc)
        return problem(400, "Malformed collect payload", code="malformed",
                       detail=repr(exc))
    now = datetime.now(tz.utc)
    awarded = []
    for drop_id in claimed:
        # Locked WITHOUT the active filter so a lost race is observable:
        # the loser's transaction waits on the winner's row lock, then sees
        # active=False and logs already_taken instead of vanishing silently.
        drop = (GemDrop.objects.select_for_update()
                .filter(id=drop_id, route__isnull=True).first())
        if drop is None:
            continue
        closest = closest_track_distance(track, drop.lat, drop.lng)
        if drop.dropped_by_id == profile.id:
            log_claim(profile, drop, "free_run", "own_drop", closest)
            continue
        if closest is None or closest > rules.DROP_COLLECT_RADIUS_M:
            log_claim(profile, drop, "free_run", "too_far", closest)
            continue
        if not drop.active:
            log_claim(profile, drop, "free_run", "already_taken", closest)
            continue
        drop.active = False
        drop.save(update_fields=["active"])
        StashItem.objects.create(profile=profile, gem_id=drop.gem_id,
                                 gem_drop=drop, collected_at=now,
                                 is_first_find=True)
        log_claim(profile, drop, "free_run", "awarded", closest)
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


def closest_track_distance(track, lat, lng):
    """Closest an accuracy-trusted GPS sample came to (lat, lng), in meters.
    None when no sample was accurate enough to count."""
    k = 111_320.0
    klng = k * max(0.1, math.cos(math.radians(lat)))
    best = None
    for s in track:
        if s.get("horizontal_accuracy", 0) > rules.MAX_CLAIM_ACCURACY_M:
            continue
        d = math.hypot((s["lat"] - lat) * k, (s["lng"] - lng) * klng)
        if best is None or d < best:
            best = d
    return best


def track_passes_near(track, lat, lng):
    d = closest_track_distance(track, lat, lng)
    return d is not None and d <= rules.DROP_COLLECT_RADIUS_M


@csrf_exempt
@require_http_methods(["GET"])
def gem_catalog(request):
    return JsonResponse({"gems": [
        {"id": str(e["id"]), "name": e["name"], "rarity": e["rarity"],
         "set_id": str(e["set_id"]), "icon_ref": e["icon_ref"]}
        for e in catalog.ENTRIES]})
