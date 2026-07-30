# 14 — System Drop Pipeline, End to End

How a system gem goes from *nothing* to *a pin the runner can tap on the
Explore map*: the trigger, the placement algorithm, the database row, the
wire format, and every iOS layer that renders it. Complements doc 12 (user
creation paths) and doc 13 (walkability downstream call); this doc is the
single vertical slice, current as of 2026-07-27.

```
 PHONE                          BACKEND                                 PHONE
┌──────────────┐   GET /v1/drops   ┌─────────────────────────────┐   JSON    ┌───────────────────────┐
│ Explore tab   │ ────────────────▶│ views.drops()                │ ────────▶│ GemRunAPI.nearbyDrops │
│ opens / GPS   │  lat,lng,radius  │  └─ system_drops.top_up_area │  drops[] │  └─ [GemDrop] decode  │
│ fix lands     │                  │      ├─ Tier 1: routes       │          │ ExploreRootView       │
└──────────────┘                  │      └─ Tier 2: OSM ways ────┼─Overpass │  └─ nearbyDrops state │
                                  │             │                │          │ ExploreMapView        │
                                  │       GemDrop rows           │          │  └─ Annotation+DropPin│
                                  │   (route=NULL, system)       │          │ tap → GemInfoSheet    │
                                  └─────────────────────────────┘          └───────────────────────┘
```

---

## 1. Trigger: user presence, not a schedule

There is **no cron, no scheduled spawner**. The map query *is* the trigger.

`GET /v1/drops?lat&lng&radius_m` (`backend/api/views.py → drops()`) calls
`system_drops.presence_trigger(lat, lng, radius)`, wrapped in a bare
`try/except` so a trigger failure can never break the map read. The
trigger picks one of two paths:

- **Warm area** (already holds active system gems): rotation + top-up are
  handed to a small background executor (2 workers, per-cell in-flight
  dedupe on a ~550 m grid) and the request **answers immediately** — that
  one response may show yesterday's layout a final time; the next refresh
  shows the rotated world.
- **Cold area** (nothing here at all): bootstrap runs **inline**, so the
  first-ever answer for a new area arrives already stocked — the iOS
  first-load cover exists for exactly this wait.

`PRESENCE_ASYNC=False` forces inline everywhere (tests need it — their
in-memory SQLite is per-thread). Consequences:

- Gems exist only where someone has actually opened the map. A region with
  zero app usage has zero gems, forever, by design.
- The *first* map open in a new area stocks it (bootstrap); later opens
  restock freed slots in the background at zero request cost.
- **Daily rotation** (`expire_stale`): uncollected *system* gems spawned
  before today free their slots on the next map open, and the top-up that
  follows restocks the area at fresh positions — the world never repeats
  yesterday's layout. Player-placed drops are exempt: a runner chose
  those spots. `GemDrop.created_at` (migration 0004) is the input.

## 2. Placement algorithm (`backend/api/system_drops.py → top_up_area`)

### 2.1 Budget — the per-mile contract

All counts are **radial** within `PRESENCE_RADIUS_M = 1609` (one mile) of
the map-open point (`mile_count`: indexed bbox prefilter + planar
distance), over active standalone SYSTEM drops only — player wallet drops
neither satisfy the floor nor consume the cap, so littering can't suppress
system stock.

    count < PRESENCE_FLOOR (20)   → restock up to PRESENCE_FILL_TARGET (35)
    20 ≤ count ≤ HARD_MAX (50)    → do nothing (someone else's gems ARE stock)
    PRESENCE_HARD_MAX (50)        → never exceeded, counting everyone's gems

The fill target sits mid-band so two overlapping users' spawns still land
under the cap. Every insert goes through a **guarded create**: inside a
write-serialized transaction (SQLite `BEGIN IMMEDIATE`, settings OPTIONS)
it freshly re-counts BOTH the requester's mile and the candidate gem's own
mile and aborts the pass at 50 — no writer can inject rows between the
check and the insert, so the cap holds under concurrent overlapping
top-ups. Belt and suspenders: `enforce_hard_max` runs on every open
(read-time enforcement) — whatever concurrent neighbors spilled into your
mile while nobody was looking, it is trimmed back to 50 (newest system
gems first) before the restock logic runs, making the guarantee literal at
every observation. Cold-inline bootstrap is bounded by
`PRESENCE_INLINE_BUDGET_S = 12`; the budget is checked before every Overpass call and placement
attempt, and an expired budget simply leaves the mile short (later opens
retry — the floor keeps firing).

### 2.2 Tier 1 — popular routes (`drop_gem_on_route`)

Published routes in the bbox with `run_count ≥ PRESENCE_DROP_MIN_RUNS`
(env-overridable; dev runs with 0), ordered by popularity. For each, up to
`ATTEMPTS_PER_ROUTE = 8` tries:

1. Sample a uniform-random distance along the route polyline and
   interpolate the coordinate (`RouteGeometry.coordinate_at`). Route
   polylines are **walking-directions-snapped**, so the point is on a path
   humans actually walked — construction vouches for it.
2. Reject if farther than `PRESENCE_RADIUS_M = 1609` from the map-open
   point (the mile is both the counting and the placement circle — a mile
   is still a walk, not a drive).
3. Reject if within `MIN_GEM_SPACING_M = 100` of any active standalone drop
   (`near_existing_drop`, planar-meters check over a bbox prefilter).
4. Veto only on an explicit `walkability.is_walkable(...) is False`; `None`
   (check off / Overpass unreachable) is accepted because the point came
   from a trusted polyline.

One gem max per route per top-up.

### 2.3 Tier 2 — OSM sidewalks & trails (`drop_on_walkable_ways`)

Fills the remaining budget by sampling points **directly on OpenStreetMap
way geometry** — the way's node list *is* the walkable-path list, so linear
interpolation between adjacent nodes stays on the path. There is **no
random scatter tier**: a rate-limited walkability check fails open and
lands gems on private land, so empty beats misplaced (pinned by test
`test_map_open_without_walkable_geometry_spawns_nothing`).

1. **Fetch**: `walkability.fetch_walkable_ways(lat, lng,
   PRESENCE_RADIUS_M, highways=PEDESTRIAN_HIGHWAYS, deadline=…)` — one
   Overpass query, mirrors tried in order (each capped to the remaining
   placement budget), 120 s circuit breaker after total failure.
2. **Way filter** (in the Overpass query itself):
   - `highway ~ ^(footway|pedestrian|path|steps)$` — sidewalks
     (`footway`), walking/running trails (`path`), promenades
     (`pedestrian`), stairs. Driveways (`service`), farm tracks (`track`),
     cycleways, bridleways, and all road centerlines are excluded — each of
     those produced gems that read as sitting on private property.
   - `foot` and `access` must not be `no`/`private`.
   - Closed rings (park loops, roundabouts) dropped in post.
3. **Way choice**: distance-weighted toward the user —
   `weight = (250 / (250 + d_min))²` where `d_min` is the nearest node's
   planar distance. A path 100 m away is ~9× likelier than one 800 m away.
4. **Point sample**: random segment of the chosen way, random `t ∈ [0,1)`
   lerp between its endpoints.
5. **Reject** if beyond the mile (long ways can lerp past the circle —
   pinned by `test_bootstrap_never_places_beyond_near_limit`) or within
   100 m of an existing drop. Up to `count × 8` attempts total; every
   accepted point commits through the guarded create (§2.1).

Slots still empty after both tiers stay empty, with an explicit log line —
never filled by guessing.

### 2.4 Rarity & gem identity (`create_system_drop`)

- Rarity roll: `common/uncommon/rare/epic = 40/30/20/10`. Legendary never
  system-spawns. Rarer loot follows **proven foot traffic, not scenery**:
  gems placed on popular routes (Tier 1, already gated by
  `PRESENCE_DROP_MIN_RUNS`) roll the richer `HIGH_TRAFFIC_WEIGHTS =
  15/45/27/13`; every off-route sidewalk fill (Tier 2) keeps the default
  mix regardless of OSM way class. The trail-vs-sidewalk distinction is a
  placement *safety* filter only — the game stocks where people already
  walk, it does not lure them onto "nicer" paths.
- Gem identity: `catalog.random_gem_of(rarity, rng)` — a uniform pick among
  all catalog entries of that rarity (26-entry catalog incl. the Ancient
  Relics set), so the map shows ambers/pearls/fossils, not the same quartz.
- The catalog's fixed UUIDs (`uuid.UUID(int=n)`) are byte-identical to the
  iOS `GemCatalog` UUIDs — the id on the wire *is* the id the client
  already knows. No catalog sync exists or is needed.

### 2.5 The row

```
GemDrop(route=NULL, dropped_by=NULL, gem_id=<catalog uuid>, rarity,
        lat, lng, position_along_route_m=0,
        respawn_rule="one_time", placed_by="system", active=True)
```

`route=NULL` is what makes it a *standalone* drop; `placed_by="system"`
separates it from player wallet drops in every query above.

## 3. Wire format (`views.py → drop_json`)

The same `GET /v1/drops` request that triggered the top-up then reads every
active standalone drop in the bbox (system *and* player-placed) and returns:

```json
{"drops": [{"id": "...", "gem_id": "00000000-…-0028", "rarity": "uncommon",
            "lat": 32.97, "lng": -96.65, "position_along_route_m": 0,
            "respawn_rule": "one_time", "placed_by": "system",
            "fuzz_radius_m": null}],
 "stocking": false}
```

Map drops are sent `exact=True`. (Route-detail payloads use the fuzzed
variant — deterministic ≤75 m jitter — but the standalone map list does
not; you run to the true point.)

`stocking` is true when a warm answer shipped while a background job is
still restocking/rotating this mile (`presence_trigger` returns pending =
sub-floor count OR yesterday's gems still active). The client shows
"Stocking gems near you…" and automatically refetches (~4 s, once more at
~6 s if still flagged, then stops — so a geometry-poor mile that can never
reach the floor doesn't loop). Inline paths always send false: their
answer already reflects the restock.

## 4. iOS: fetch → state (`FeatureExplore/ExploreRootView.swift`)

**The map is never shown unstocked.** An opaque first-load cover
(`firstLoadCover`) sits over the map from tab-open until the first gem
fetch lands, walking `locating → stocking → ready` (or `failed`, which
keeps the cover up with a Retry). Location permission is requested up
front under the cover; a denial swaps it to a "Turn on location" +
Open-Settings prompt (`LiveLocation.isDenied`). The map and its tiles keep
loading *underneath*, so the reveal is instant — and because the reveal
happens in the same `withAnimation` block that sets the pins, an empty map
can never flash before the gems do. The old shape of this bug — open to a
bare map, close, reopen to find gems — is structurally gone.

`loadNearby()` runs on tab appear, on the first GPS fix, and on pull
refresh:

1. Gate on a real location (live fix, else `CLLocationManager.location`,
   else stay on the `locating` cover — recommendations are
   proximity-based, wrong-location fetches show wrong content; the
   first-fix `onChange` watcher re-enters the moment GPS lands).
2. `API.shared.nearbyDrops(lat:lng:radiusM: 8_000)` →
   `CoreNetworking/GemRunAPI.swift` decodes `drops[]` into `[GemDrop]`
   (snake_case CodingKeys; `gem_id` → `gemID: UUID`).
3. `withAnimation { nearbyDrops = drops; firstLoad = .ready }` — drops
   render straight from this in-memory array. They are deliberately **not**
   cached in SwiftData: first-come collection means they change hands too
   fast for a cache to ever be right.
4. The same pass feeds `RouteRecommender.recommend(from:drops:)`, which
   synthesizes the 4 suggested walking routes *through* those gems — so the
   carousel and the pins always agree.

If the first response is legitimately empty (fail-closed area: no routes,
no trusted OSM geometry), the map reveals with an honest "No gems in this
area yet" banner instead of standing silently bare. A *refresh* failure
after the first reveal keeps the existing pins — only the first load has
the hard gate.

## 5. iOS: state → pixels (`CoreMap/MapProviding.swift`)

**Explore map** (`ExploreMapView`): each drop becomes a MapKit
`Annotation` at `drop.coordinate` containing a `Button` wrapping `DropPin`:

- `DropPin` resolves the emoji via `MapPalette.emoji(forGemID:)` — the
  fixed-UUID catalog lookup again — and plays the pin-drop entrance
  (spring from `y −30`, scale 1.3 → 1).
- Tap → `onSelectDrop(drop)` → `ExploreRootView` sets `infoDrop` → a
  320 pt sheet presents **`GemInfoSheet`**: big emoji, gem name, rarity
  badge + set name, one-line real-material blurb, and a **"Walk or run to
  collect" button**. Tapping it snaps a walking path from the user to the
  gem (`PathSnapper.snap`, straight-line fallback if snapping fails) and
  starts a **free run** along it (`session.startFreeRun(drops:plannedPath:)`)
  — deliberately a free run, not a route run, because free runs are the
  mode that collects standalone drops by proximity; the tapped gem awards
  on arrival and every other nearby gem stays collectable en route. The
  planned line draws in pulse on the active-run map. Unknown `gem_id`
  degrades to "Mystery Gem" rather than crashing — the sheet never assumes
  catalog hits.

**Active-run map** (`ActiveRunMapView`): the same drops arrive as
`freeDrops` (free runs) or `route.gemDrops`. Uncollected → emoji
annotation. The moment a drop id enters `collectedDropIDs`, an `onChange`
diff plays **`SparkleBurst`** at its coordinate (six ✨ fly outward over
~1.2 s), then the pin settles into a muted checkmark.

## 6. Collection closes the loop

- **During a route run**: `CollectionEngine` awards at ≤ 100 ft / 30.5 m
  (`collectionRadiusM`) with progress + hysteresis rules.
- **During a free run**: pure proximity, the same ≤ 100 ft / 30.5 m
  (`dropCollectRadiusM`) — one capture distance everywhere, mirrored by
  the server's `COLLECTION_RADIUS_M` / `DROP_COLLECT_RADIUS_M`.
- Server side, `POST /v1/drops/collect` (or route completion crossing a
  standalone drop) validates the GPS track, awards **first-come**, and
  deactivates the row atomically. `respawn_rule="one_time"` means the row
  never comes back — but the *slot* does: the next map open in that area
  finds the budget short by one and spawns a fresh gem somewhere else
  walkable.

## 7. Failure policy summary

| Failure | Behavior |
|---|---|
| Overpass mirror down | next mirror; all down → 120 s circuit breaker |
| No walkable ways answer | Tier 2 spawns **nothing** (fail closed) |
| Background top-up job raises | logged; slot for that cell frees; next map open retries |
| Walkability check `None` on a route point | accepted (polyline is trusted) |
| top_up_area raises | swallowed; map read still answers |
| Unknown gem_id on client | "Mystery Gem" fallback in sheet & pin |
| No GPS fix on client | first-load cover stays on "Finding you…"; auto-retries on first fix |
| Location permission denied | cover becomes a "Turn on location" → Settings prompt |
| First drops fetch fails | cover stays up with Retry — a bare map never stands in for an error |
| Legitimately empty area | map reveals with a "No gems in this area yet" banner |
| Two overlapping top-ups race the cap | per-insert fresh counts + INSERT in one write-serialized transaction; any residual overshoot is trimmed at the next observation of that mile (`enforce_hard_max`) |
| Inline bootstrap budget expires | placement stops mid-pass; mile sits below floor; next open retries |

## 8. Tuning knobs

| Knob | Where | Value |
|---|---|---|
| Mile radius | `settings.PRESENCE_RADIUS_M` | 1 609 m |
| Restock floor | `settings.PRESENCE_FLOOR` | 20 / mile |
| Fill target | `settings.PRESENCE_FILL_TARGET` | 35 / mile |
| Hard max | `settings.PRESENCE_HARD_MAX` | 50 / mile, everyone's gems |
| Inline bootstrap budget | `settings.PRESENCE_INLINE_BUDGET_S` | 12 s |
| Client HTTP timeouts | `APIClient.swift` | 15 s request / 30 s resource |
| Min gem spacing | `rules.MIN_GEM_SPACING_M` | 100 m |
| Placement ways | `walkability.PEDESTRIAN_HIGHWAYS` | footway\|pedestrian\|path\|steps |
| Rarity mix | `system_drops.WEIGHTS` / `HIGH_TRAFFIC_WEIGHTS` | 40/30/20/10 (sidewalk fills) · 15/45/27/13 (popular routes) |
| Distance bias | `drop_on_walkable_ways` | (250/(250+d))² |
| Route popularity gate | `PRESENCE_DROP_MIN_RUNS` | 3 (0 in dev) |
| Client fetch radius | `ExploreRootView.loadNearby` | 8 000 m |

## 9. Known limitations (why this isn't the final design)

1. **Only first contact pays for placement.** Warm areas answer instantly
   (background top-up); a genuinely cold area still pays one inline
   Overpass round-trip, made explicit by the client's "Stocking gems near
   you…" cover. Remaining better: pre-warm cells server-side (the
   walkable-way cache of §9.2) so even first contact is a local read.
2. **Overpass is a hard dependency for Tier 2.** Keyless, aggressively
   rate-limited, and its data quality *is* our placement quality — suburbs
   with unmapped sidewalks get few or no gems. Better: pre-download way
   geometry per visited cell (cache table keyed by H3/geohash, refreshed
   weekly), so placement is a local read.
3. **~~The budget is a moving box~~ — resolved.** The budget is now the
   radial per-mile contract with per-insert guarded creates inside a
   write-serialized transaction (§2.1): overlapping users see each other's
   committed gems and throttle. Honest residual: a never-opened point
   BETWEEN two spawn centers can, in adversarial geometry, exceed 50 —
   bounded by the candidate-mile check, trimmed by `enforce_hard_max` the
   moment anyone observes that mile, and healed outright by daily
   rotation. The permanent fix (and the Postgres/MVCC requirement, where a
   COUNT inside a transaction no longer serializes) is fixed grid cells
   with a per-cell budget row.
4. **Spacing check is O(drops) per candidate** with a bbox prefilter — fine
   at 40, wrong at scale. Better: PostGIS + spatial index, or the cell
   cache above.
5. **Respawn cadence is daily-or-on-look.** Daily rotation now guarantees
   the world changes across days, and background restocks decouple the
   refill from the answering request — but within a day, a lone player
   still sees restocks land right after they look. Better: cell-level
   respawn windows (e.g. refill at most N per hour, jittered).
6. **`random.Random()` is unseeded per request** — placements are not
   reproducible for debugging. Passing a seed derived from (cell, day)
   would make spawn layouts deterministic and testable in the field.
7. **Popularity signal is thin.** `run_count` on routes is the only "walked
   by many" input; actual GPS heatmaps from completed runs (doc 04) are not
   yet used. The truest "previously walked paths" source we own is the
   `track` samples users already upload.
