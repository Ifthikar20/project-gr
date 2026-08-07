"""Run validation — port of GameKitCore's CollectionEngine + RunValidator
(docs/04). The server replays the full track authoritatively (docs/06).
Track samples are dicts: {t, lat, lng, horizontal_accuracy, speed}.
"""
from . import rules
from .geometry import RouteGeometry


def replay_collections(geom: RouteGeometry, drops, track):
    """Replays the CollectionEngine: 200 ft threshold + hysteresis + monotonic
    route progress. `drops` are dicts with id, lat, lng, position_along_route_m.
    Returns the set of collectable drop ids the track actually supports.
    """
    ordered = sorted(drops, key=lambda d: d["position_along_route_m"])
    collected = set()
    max_progress = 0.0
    last_collection = None  # ((lat, lng), along_m)

    for s in track:
        pos = (s["lat"], s["lng"])
        cross, along = geom.project(*pos)
        if cross > rules.MAX_CROSS_TRACK_M:
            continue
        if along > max_progress:
            max_progress = along
        for d in ordered:
            if d["id"] in collected:
                continue
            drop_along = float(d["position_along_route_m"])
            # Monotonic-progress rule: grazing across a switchback doesn't count.
            if max_progress + rules.COLLECTION_RADIUS_M < drop_along:
                continue
            if geom.distance(pos, (d["lat"], d["lng"])) > rules.COLLECTION_RADIUS_M:
                continue
            if last_collection is not None:
                exited = geom.distance(pos, last_collection[0]) > rules.HYSTERESIS_EXIT_RADIUS_M
                advanced = drop_along - last_collection[1] >= rules.HYSTERESIS_ADVANCE_M
                if not (exited or advanced):
                    continue
            collected.add(d["id"])
            last_collection = ((d["lat"], d["lng"]), drop_along)
    return collected


def validate(track, geom: RouteGeometry):
    """Port of RunValidator.validate — adherence, coverage, pace, teleport."""
    if len(track) < 2 or geom.total_length_m <= 0:
        return {"status": "invalid", "flags": ["empty_track"], "duration_s": 0,
                "distance_m": 0, "pace_s_per_km": 0, "is_walk": False,
                "on_route_ratio": 0.0, "coverage_ratio": 0.0, "splits_s": []}

    on_route = 0
    max_progress = 0.0
    distance_m = 0.0
    teleport_run_s = 0.0
    flags = []
    # Mile splits (the app displays imperial units; models stay metric).
    splits, next_split, last_split_t = [], 1609.344, track[0]["t"]

    for i, s in enumerate(track):
        cross, along = geom.project(s["lat"], s["lng"])
        if cross <= rules.MAX_CROSS_TRACK_M:
            on_route += 1
            max_progress = max(max_progress, along)
        if i > 0:
            prev = track[i - 1]
            dt = max(0.001, s["t"] - prev["t"])
            d = geom.distance((prev["lat"], prev["lng"]), (s["lat"], s["lng"]))
            distance_m += d
            while distance_m >= next_split:
                splits.append(int(s["t"] - last_split_t))
                last_split_t = s["t"]
                next_split += 1609.344
            if d / dt > rules.TELEPORT_SPEED:
                teleport_run_s += dt
                if teleport_run_s >= rules.TELEPORT_SUSTAIN_S and "teleport" not in flags:
                    flags.append("teleport")
            else:
                teleport_run_s = 0.0

    duration_s = int(track[-1]["t"] - track[0]["t"])
    on_route_ratio = on_route / len(track)
    coverage_ratio = max_progress / geom.total_length_m
    pace = int(duration_s / (distance_m / 1000.0)) if distance_m > 50 else 0
    is_walk = rules.WALK_PACE_THRESHOLD_S_PER_KM < pace <= rules.MAX_VALID_PACE_S_PER_KM

    if on_route_ratio < rules.MIN_ON_ROUTE_SAMPLE_RATIO:
        flags.append("adherence")
    if coverage_ratio < rules.MIN_ROUTE_COVERAGE_RATIO:
        flags.append("coverage")
    if 0 < pace < rules.MIN_RUN_PACE_S_PER_KM:
        flags.append("too_fast")
    if pace > rules.MAX_VALID_PACE_S_PER_KM:
        flags.append("too_slow")

    if "too_fast" in flags or "too_slow" in flags or coverage_ratio < 0.5:
        status = "invalid"
    elif flags:
        status = "flagged"
    else:
        status = "valid"

    return {"status": status, "flags": flags, "duration_s": duration_s,
            "distance_m": int(distance_m), "pace_s_per_km": pace, "is_walk": is_walk,
            "on_route_ratio": on_route_ratio, "coverage_ratio": coverage_ratio,
            "splits_s": splits}


def xp_for(rarities, is_walk: bool, streak_days: int) -> int:
    base = sum(rules.XP_BY_RARITY[r] for r in rarities)
    factor = (rules.WALK_MULTIPLIER if is_walk else 1.0) * rules.streak_multiplier(streak_days)
    return round(base * factor)
