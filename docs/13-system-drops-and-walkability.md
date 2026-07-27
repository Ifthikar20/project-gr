# 13 — System Drops on Popular Paths & the Walkability Downstream Call

The backend-initiated gem pipeline: find paths that are **walkable** and
**walked by many of our users**, drop a gem there, record its coordinates in
the master table, and award it to the **first** runner whose GPS track
crosses it. Complements the four user-facing creation paths in doc 12.

## The pipeline

```
popularity signal          walkability check           master table            first-come award
(our own run data)         (downstream call)
┌─────────────────┐   ┌───────────────────────┐   ┌──────────────────┐   ┌──────────────────────┐
│ published routes │ → │ point sampled from a  │ → │ GemDrop row       │ → │ first user whose     │
│ ranked by        │   │ walking-snapped route │   │ route=NULL        │   │ track passes within  │
│ run_count        │   │ polyline; re-checked  │   │ placed_by=system  │   │ 25 m claims it —     │
│ (min-runs gate)  │   │ via OSM Overpass when │   │ respawn=one_time  │   │ row deactivated      │
│                  │   │ enabled               │   │ active=True       │   │ atomically           │
└─────────────────┘   └───────────────────────┘   └──────────────────┘   └──────────────────────┘
```

## 1. The trigger: user presence, not a schedule

**The map query is the trigger.** When any user opens the map, the app calls
`GET /v1/drops?lat&lng&radius_m` with *their* coordinates — and that same
request tops up system gems around those coordinates first
(`system_drops.top_up_area`, called best-effort so a failure never breaks
the map read). User activity is literally the coordinate capture:

- Nobody uses the app in a region → nobody queries there, no routes exist
  there, no gems ever spawn there. (No users in Alaska = no gems in Alaska.)
- The first map open in an active area stocks it; the next one after a gem
  is collected restocks it.

The top-up is **self-limiting**, so repeated map opens never pile gems up:
the target is one active system drop per popular route in the queried area,
capped at `PRESENCE_DROP_MAX_PER_AREA` (default 3). At or above target the
trigger is two cheap count queries and exits.

### Popularity: "being walked by many people"

We already own the strongest possible signal — GemRun's run history. Both
the presence trigger and the command rank published routes by `run_count`
and only consider routes at or above the min-runs gate (default 3). A
candidate point is sampled at a random position along a qualifying route's
polyline, so system gems land exactly where our users demonstrably run.
Existing-drop spacing is enforced (100 m, the doc-02 rule) and rarity is
weighted (common 60 / uncommon 25 / rare 12 / epic 3 — legendary never).

### The global backstop command

`manage.py drop_gems` sweeps ALL popular routes regardless of who's online —
useful before an event or to stock a launch city ahead of users. Same engine
(`system_drops.drop_gem_on_route`), optional cron, safe to re-run.

```sh
python manage.py drop_gems --max-drops 5 --min-runs 3
python manage.py drop_gems --seed 42                          # reproducible
```

## 2. Walkability: the downstream call

Apple exposes **no** "list of walkable paths" API (see the research summary
in the PR discussion / doc 12 §5) — its pedestrian network is only reachable
indirectly through routing. So walkability is layered:

- **By construction** — every candidate point comes from a route polyline
  that was snapped segment-by-segment to Apple walking directions
  (`PathSnapper`, MKDirections `.walking`) when the route was created.
  Pedestrian routing never follows motorways or private roads Apple knows
  about.
- **By verification** — `api/walkability.py` queries OpenStreetMap's
  Overpass API for ways within 25 m tagged with pedestrian-legal `highway`
  values (footway, path, pedestrian, steps, residential, …), explicitly
  excluding `foot=no` and `access=private|no`; motorway/trunk/primary are
  excluded by omission. OSM is the only real "walkable path list" data
  source. ODbL attribution applies (already planned in docs/10).

`is_walkable(lat, lng)` is deliberately three-valued:

| Result | Meaning | Caller policy |
|---|---|---|
| `True` | walkable way within radius | drop / accept |
| `False` | Overpass answered: nothing walkable (highway median, private land, water) | **skip / reject 422 `not_walkable`** |
| `None` | check disabled or Overpass unreachable | trust the route snap; user drops proceed |

Configuration (`gemrun/settings.py`): `WALKABILITY_MODE` (`"off"` default,
`"overpass"` to enable), `OVERPASS_URL`, `WALKABILITY_RADIUS_M` (25, matches
the collection radius), `WALKABILITY_TIMEOUT_S`. The same check also gates
user standalone drops in `POST /v1/drops`.

A future alternative provider is the Apple Maps Server API
(`transportType=Walking`, 25k free calls/day): validate a point by routing
*to* it and checking the route terminates within the collect radius. Slot it
in as another `WALKABILITY_MODE` if OSM coverage disappoints somewhere.

## 3. The master table

`GemDrop` **is** the master coordinates table — no parallel table needed.
System drops are the rows with:

| Column | Value |
|---|---|
| `route` | `NULL` (standalone — not tied to any route) |
| `dropped_by` | `NULL` (system, not a user's wallet gem) |
| `placed_by` | `"system"` |
| `respawn_rule` | `"one_time"` |
| `active` | `True` until claimed, then `False` forever |
| `lat`, `lng`, `rarity`, `gem_id` | the drop itself |

They surface to clients through the existing geo query
`GET /v1/drops?lat&lng&radius_m` (exact coordinates), and every claim is
recorded as a `StashItem` (`is_first_find=True`) — the permanent audit trail
of who got which coordinates, when, on which run.

## 4. First come, first served

Two ways a runner's track can cross the coordinates; both award exactly once:

- **Free run** — `POST /v1/drops/collect` with the claimed ids + GPS track.
- **Route run** — `POST /v1/runs/{route_id}/complete` now *also* scans the
  master table: any active standalone drop within the track's bounding box
  whose coordinates the track passed within 25 m is claimed automatically
  (`claim_crossed_standalone_drops` in `views.py`), no client claim needed.

Shared guarantees, enforced server-side in one transaction:

1. **Atomic first-come.** `select_for_update` + the `active` flag: the first
   transaction to commit deactivates the row; every later claimant sees
   `active=False` and gets nothing.
2. **Track-verified.** The GPS track must actually pass within
   `DROP_COLLECT_RADIUS_M` (25 m) of the stored coordinates
   (`track_passes_near`); on route runs the whole track already went through
   the anti-spoof validator first — an invalid run claims nothing.
3. **Never your own.** Drops where `dropped_by == claimant` are excluded
   (moot for system drops, load-bearing for user drops).
4. **Idempotent.** Run completion retries with the same `idempotency_key`
   return the stored verdict and never re-scan.
5. **XP.** Crossed drops score plain rarity XP (same rule as
   `/drops/collect`); route-gem XP keeps its walk/streak multipliers.

## 5. Operating it

Nothing to schedule for normal operation — the presence trigger keeps every
active area stocked on its own (`PRESENCE_DROPS = True`). Run `drop_gems`
from cron only as a backstop or to pre-stock a region. Both are safe to
re-run: spacing prevents pile-ups, the area target self-limits, and claimed
drops stay inactive. To watch supply/demand:

```sql
-- unclaimed system drops
SELECT COUNT(*) FROM api_gemdrop WHERE route_id IS NULL AND placed_by='system' AND active;
-- claim latency: StashItem.collected_at minus drop creation (add created_at if needed)
```

Known gaps, on purpose: no `created_at`/expiry on drops yet (add a TTL sweep
when supply outpaces claims), popularity is per-route rather than per-segment
(raw tracks aren't persisted; doc 05 keeps them client-side), and Overpass
should be self-hosted before real launch traffic rather than hitting the
public instance.
