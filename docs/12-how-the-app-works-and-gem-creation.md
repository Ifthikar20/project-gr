# 12 — How the App Works & How Gems Get Created

A single orientation doc for anyone joining the project: what GemRun is, how
the pieces fit together, every path by which a gem comes into existence, and
the client → server call chains you need to understand before wiring up any
downstream call. Deep dives live in the lower-numbered docs; this one links
to them where relevant.

---

## 1. What the app is

GemRun turns a running route into a treasure hunt. A creator draws a route on
the map and places gems along it; other runners run that route with GPS
tracking, and gems they pass within 25 m of go into their stash. XP, levels,
streaks, and leaderboards sit on top to keep people coming back.

The core loop (docs/01, docs/02):

1. **Create** a route — draw a path or drop a destination pin
2. **Drop gems** along it, spending a distance-based placement budget
3. **Publish** — the route becomes visible to nearby runners
4. **Run & collect** — GPS-confirmed collection, optimistic on the client,
   authoritative on the server
5. **Compete** — per-route and weekly-local leaderboards, streaks, gem sets

## 2. System overview

Two codebases, one wire contract:

```
┌─────────────────────────── iOS app (SwiftUI, iOS 17+) ───────────────────────────┐
│  App/                    tab shell + entry point                                 │
│  Packages/GemRunFeatures one SPM target per screen (Explore, RouteCreation,      │
│                          ActiveRun, Stash, Profile, Onboarding)                  │
│  Packages/GemRunCore                                                             │
│    CoreModels      shared value types (Route, GemDrop, Rarity, …)               │
│    GameKitCore     game rules: placement budget, collection engine,             │
│                    run validator, XP/streak calculators                          │
│    CoreMap         map seam (MapKit today, Mapbox planned)                       │
│    CoreLocationKit GPS pipeline                                                  │
│    CorePersistence SwiftData, local-first (SessionStore)                         │
│    CoreNetworking  GemRunAPI protocol + MockGemRunAPI + HTTPGemRunAPI            │
└──────────────────────────────────┬───────────────────────────────────────────────┘
                                   │  /v1 JSON (snake_case, ISO-8601, Bearer token)
┌──────────────────────────────────▼───────────────────────────────────────────────┐
│  backend/ (Django)                                                               │
│    api/urls.py       the 14 /v1 endpoints                                        │
│    api/views.py      handlers (auth, routes, runs, stash, wallet, drops)         │
│    api/rules.py      1:1 port of GameKitCore constants                           │
│    api/validation.py track replay + anti-spoof verdict                           │
│    api/catalog.py    gem catalog (same fixed UUIDs as the iOS GemCatalog)        │
│    api/models.py     Profile, Token, Route, GemDrop, Run, StashItem              │
└───────────────────────────────────────────────────────────────────────────────────┘
```

Key architectural facts:

- **One API seam.** UI code only ever talks to `API.shared`
  (`Packages/GemRunCore/Sources/CoreNetworking/GemRunAPI.swift`). If
  `AppConfig.apiBaseURL` is `nil` (the current default) the in-app
  `MockGemRunAPI` serves everything from memory; set the URL and the same
  calls go over HTTP to Django. Swapping backends is a one-line change.
- **Rules are duplicated deliberately.** The client enforces game rules
  offline for instant feedback (GameKitCore); the server re-validates
  everything with the same constants (`backend/api/rules.py`). The client is
  optimistic, the server is authoritative.
- **Local-first.** Runs record into a crash-safe buffer and SwiftData; server
  sync confirms or revokes afterwards.
- **Dev auth flag.** `ALLOW_ALL_ACCOUNTS` (Django) mirrors
  `AuthFlags.allowAllAccounts` (iOS): unauthenticated calls act as a shared
  dev profile. Both must flip off before real token verification (docs/10).

## 3. The gem model

A "gem" is really three separate concepts — keep them apart when working on
any gem-related call:

| Concept | What it is | Where it lives |
|---|---|---|
| **Gem (catalog entry)** | The *kind* of gem: name, rarity, set, icon. Static, identical on both sides. | `catalog.py` / iOS `GemCatalog` |
| **GemDrop** | A *placed instance* of a gem at a lat/lng — on a route, or standalone on the open map. Has a respawn rule and an `active` flag. | `GemDrop` table / `gem_drops` in route JSON |
| **StashItem** | A *collected* gem in a runner's stash, linking profile ↔ drop ↔ run. | `StashItem` table / `GET /v1/stash` |

The catalog uses **fixed UUIDs** (`uuid.UUID(int=n)` in Python equals Swift's
`UUID` with last byte `n`), so gem ids match across client and server with no
sync step. Rarities: common, uncommon, rare, epic, legendary — legendary is
system-seeded only, never placeable or droppable by users.

Respawn rules decide who can collect a drop again:

- `daily` — each user once per calendar day (common/uncommon route gems)
- `once_per_user` — each user once, ever (rare/epic route gems)
- `one_time` — once per user, and the first collector gets the
  `is_first_find` crown (legendary, and all standalone drops)

## 4. How gems get created — all four paths

### Path A — Creator-placed route gems (the main path)

The 3-step creation flow in
`Packages/GemRunFeatures/Sources/FeatureRouteCreation/RouteCreationFlow.swift`
(draw → place gems → publish):

1. **Draw.** The user taps waypoints (or drops a destination pin); each
   segment snaps to walkable paths via `MKDirections` with a straight-line
   fallback. Routes must be ≥ 1 km.
2. **Place gems.** Each map tap is projected onto the route
   (`geometry.project`) and validated client-side against the placement
   budget (docs/02, `CreationModel.placeGem`):
   - within 60 m of the route line, then snapped exactly onto it
   - **slots**: 1 gem per 250 m of route
   - **rarity points**: route meters ÷ 100; costs — common 1, uncommon 3,
     rare 10, epic 25
   - **spacing**: ≥ 100 m between gems (along-route distance)
   - **position**: rare/epic only in the final 60 % of the route
     (≥ 40 % in); epic additionally needs a route ≥ 8 km (elevation proxy)
   - **legendary**: rejected outright
   Passing taps append a `GemDrop` with the rarity's catalog `gem_id` and a
   default respawn rule (`daily` for common/uncommon, `once_per_user` above).
3. **Publish.** `POST /v1/routes` sends the encoded polyline plus the
   `gem_drops` array. The server (`views.publish_route`) decodes the
   polyline, recomputes distance, and **re-runs the entire budget check**
   (`validate_placement`) — a tampered client gets a 422 with `code:
   "placement"`. Only then are the `GemDrop` rows created, tied to the route.

### Path B — Wallet gems, minted by running (earn-by-running)

Runners *earn* droppable gems from lifetime distance:

- The client reports total lifetime run km (Apple Health) via
  `POST /v1/wallet/sync`.
- `views.wallet_sync` mints one gem per threshold-km per tier —
  common every 2 km, uncommon 5 km, rare 15 km, epic 40 km
  (`rules.MINT_THRESHOLD_KM`; legendary is never mintable).
- `Profile.wallet_minted` records lifetime counts already minted, so
  re-syncing the same total never double-mints; new gems land in
  `Profile.wallet` (e.g. `{"common": 3, "rare": 1}`).

> ⚠️ The km total is client-reported and trusted while the dev auth flag is
> on. Server-side verification is future work (docs/10).

### Path C — Standalone drops (wallet gems placed on the open map)

A wallet gem can be dropped **anywhere**, not just on a route:

- `POST /v1/drops` with `gem_id`, `lat`, `lng`. The server checks the gem
  exists in the catalog, isn't legendary, and that the wallet has ≥ 1 of that
  rarity — then decrements the wallet and creates a `GemDrop` with
  `route=None`, `dropped_by=<profile>`, `respawn_rule="one_time"`.
- Standalone drops are one-time: the **first** collector deactivates the
  drop, and you can never collect your own.

### Path D — System-seeded gems (cold start)

`python manage.py seed --lat … --lng …` builds a demo city (docs/02):
three circular routes with gems placed at fractions along them
(`placed_by="system"`), including the only legendary in the world
(`one_time`), plus fake competitor profiles and plausible leaderboard times.
The iOS `MockGemRunAPI` ships an equivalent in-memory seed so the app is
alive with zero backend.

### Path E — System drops on popular walkable paths (doc 13)

The backend itself drops gems where people actually run — triggered by
presence, not a schedule: each `GET /v1/drops` map query tops up gems
around its own coordinates (`api/system_drops.py`; regions nobody uses
never spawn gems). It picks published routes ranked by `run_count`, samples
a point on the (walking-snapped) polyline, verifies it against the
walkability downstream call (OSM Overpass, `api/walkability.py`), and
writes a `GemDrop` master-table row (`route=NULL`, `placed_by="system"`,
`one_time`). The first runner whose GPS track crosses those coordinates —
on a free run **or** a route run — claims it. `manage.py drop_gems` remains
as a global backstop sweep. Full pipeline: doc 13.

### How drops become stash items (collection)

- **Route runs:** during a run the client collects optimistically inside a
  25 m radius (hysteresis at 40 m). On finish, `POST
  /v1/runs/{route_id}/complete` sends the full GPS track and claimed drop
  ids. The server replays the track against route geometry
  (`validation.replay_collections`), runs anti-spoof checks (pace bounds,
  teleport detection, route adherence, coverage — `rules.py`), applies
  respawn rules, and returns the authoritative verdict: `awarded_drops`
  become `StashItem`s, `revoked` ids are silently removed client-side.
  Completion is **idempotent** via `idempotency_key` — the same key returns
  the stored verdict, never double-awards.
- **Free runs:** `POST /v1/drops/collect` claims standalone drops; the server
  only checks the track passed within 100 ft (30.5 m) of each drop, deactivates it, and
  awards XP + a first-find `StashItem`.

## 5. Call chains (read before adding any downstream call)

The full endpoint contract is docs/06; mock behavior is docs/11. These are
the chains as actually implemented, i.e. what any new downstream call will
hang off:

**Session start**
```
POST /v1/auth/{apple|google}   → { token, profile }        (Bearer for everything after)
GET  /v1/users/me              → profile (xp, level, streaks)
GET  /v1/gems/catalog          → gem definitions (cacheable, static)
```

**Explore (map)**
```
GET /v1/routes?lat&lng&radius_m   → nearby routes incl. gem_drops
                                    (rare+ drop coords are FUZZED ≤150 m
                                     unless already collected by the viewer)
GET /v1/drops?lat&lng&radius_m    → standalone drops (exact coords)
```

**Create & publish (Path A)**
```
[local drawing + budget checks]
POST /v1/routes { name, polyline, gem_drops[] }  → route JSON  (422 on budget violation)
```

**Run a route**
```
POST /v1/runs { route_id }                → { run_id, exact_drops }   (exact coords for offline collection)
[GPS tracking, optimistic collection]
POST /v1/runs/{route_id}/complete
     { idempotency_key, track, claimed_collections, started_at }
                                          → { status, awarded_drops, revoked,
                                              xp_earned, leaderboard_rank, streak_extended }
```

**Earn & drop wallet gems (Paths B/C)**
```
POST /v1/wallet/sync { total_run_km }         → { wallet }
POST /v1/drops { gem_id, lat, lng }           → drop JSON   (422 wallet_empty / legendary)
POST /v1/drops/collect { claimed, track }     → { awarded_drops, xp_earned }
```

**Aftermath**
```
GET /v1/stash                                 → collected items
GET /v1/routes/{id}/leaderboard?window=all|month
GET /v1/leaderboards/local                    → weekly XP board
```

### Things a downstream call must respect

Whatever service the run-completion or drop flow calls next, these invariants
are load-bearing:

1. **Idempotency.** `complete_run` may be retried by the offline sync queue;
   the stored verdict is returned for a repeated `idempotency_key`. A
   downstream call triggered from completion must be equally safe to fire
   twice (dedupe on `run.id` or the idempotency key), or fire only on the
   first (verdict-storing) pass.
2. **The server verdict is the source of truth.** Never propagate the
   client's `claimed_collections` downstream — only `awarded_drops` after
   replay/anti-spoof. Client claims can be (and are) revoked.
3. **Fuzzing is a privacy/anti-farming feature.** Rare+ route-drop
   coordinates leaving the server via any new read path must go through
   `drop_json(d, exact=False)` semantics unless the viewer already collected
   the drop or is starting a run on that route.
4. **Wallet minting is monotonic.** Any downstream consumer of wallet events
   should key off `wallet_minted` deltas, not raw wallet counts (counts go
   *down* when gems are dropped).
5. **Transactions.** `complete_run` and `collect_drops` run inside
   `transaction.atomic` (with `select_for_update` on standalone drops).
   A downstream network call should happen **after commit** (or be queued),
   never inside the transaction.
6. **Auth posture.** Everything currently rides the accept-all dev flag;
   token verification for Apple/Google is pending (docs/10). A downstream
   call handling real user data should assume that flag flips.

## 6. Where to look next

| Question | Doc / code |
|---|---|
| Exact endpoint shapes & error codes | docs/06, `backend/api/views.py` |
| Budget/XP/streak/anti-spoof constants | docs/02, docs/04, `backend/api/rules.py` |
| Data model & relationships | docs/05, `backend/api/models.py` |
| Mock server behavior | docs/11, `CoreNetworking/MockGemRunAPI.swift` |
| iOS module layout & seams | docs/07 |
| Open work (auth, App Attest, deploy) | docs/10 |
