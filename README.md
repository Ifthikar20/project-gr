# GemRun

> **GemRun turns any running route into a treasure hunt.**
>
> The system drops gems on real streets near you. Run past within 100 ft — first one there takes it.

## What it is

Open the map and there are gems waiting — placed by the system on real, walkable streets near wherever you are. Run or walk within 100 ft of one and it's yours, first come, first served. Create routes, place your own gems on them, share them; other runners collect as they pass, GPS-confirmed. You're not just logging miles: there's always something out there to go get.

**The core loop:**
1. **Open the map** — the backend stocks gems around your location automatically
2. **Run and collect** — pass within 100 ft; optimistic on the client, server-verified, one winner per gem
3. **Create routes** — draw a path snapped to real streets, place gems from your budget, publish
4. **Earn and drop** — lifetime kilometers mint wallet gems you can drop anywhere walkable
5. **Compete** — leaderboards, streaks, rare-gem hunts, first-find crowns

## Feature tour

### The gem system (all server-side, docs/12–13)
- **System-created gems** — gems are NOT dependent on users dropping them. Every
  map open (`GET /v1/drops`) triggers the backend to stock that area: on popular
  routes first, else directly on OSM walkable ways, else scattered a short walk
  from the user. An opened map is never empty; a region nobody visits never gets gems.
- **Walkability enforcement** — no gems on highways or private land: route
  polylines are snapped to Apple walking directions at creation, every system
  placement is checked against OpenStreetMap (Overpass, mirror fallback +
  circuit breaker), and user drops on non-walkable spots are rejected (422).
- **First-come-first-served** — one shared world: everyone sees the same gem;
  the first GPS track to provably pass within 100 ft claims it atomically
  (row lock), and it vanishes for everyone else.
- **Race audit** — every claim attempt (winner AND losers) is logged to
  `api_claimattempt` with outcome, closest distance, and timestamp. Bad GPS
  (>50 m accuracy) can't prove presence.
- **Earn-by-running wallet** — lifetime km (Apple Health) mint droppable gems
  at per-tier thresholds; legendary is system-seeded only.

### Explore (the map home)
- Live routes + gem pins fetched from the backend — nothing hardcoded, no
  phantom client-side gems. Auto-refetches when your location moves >1.5 km
  and every time the app returns to the foreground.
- Suggested-route cards (street-following, seeded from real OSM geometry —
  never geometric circles), destination mode (tap a point, get a snapped
  path from you to it), and the ➕ route-creation flow: draw → place gems
  under the budget rules → publish (server re-validates everything).

### Active run
- Camera starts **at your position**, tilted chase view rotated to your
  **live direction of travel** (turn-by-turn-nav feel), with a breadcrumb
  **trail of every step** drawn behind you.
- Gems pop with haptics at 100 ft; next-gem chip with bearing arrow;
  auto-pause; crash-safe run buffer with resume; per-km splits and a
  shareable run card at the end.
- The server replays your full track (anti-spoof: pace bounds, teleport
  detection, route adherence) and settles the authoritative verdict —
  awarded gems, XP with walk/streak multipliers, leaderboard rank.

### Developer experience
- **Verbose logging everywhere**: backend startup banner (Python, git commit,
  config, HTTPS probe), every Overpass attempt with its exact failure, every
  gem spawn with coordinates; client logs every HTTP call + decode outcome
  (`[API]`, `[Explore]` lines in the Xcode console).
- `manage.py diagnose` — one-shot health report of the gem chain around a
  coordinate, naming the broken link. `manage.py stock_gems` — spawn + report
  at startup. `manage.py seed [--clear]` — opt-in street-following demo data.
- Wire-format regression tests: backend-shaped JSON fixtures decoded with the
  client's exact decoder config, in CI.

## Tech snapshot

| | |
|---|---|
| Platform | Native iOS (iPhone), SwiftUI, iOS 17+ |
| Architecture | MVVM with `@Observable`, local SPM packages |
| Design | "Daybreak Pulse" — Airbnb-style light card UI, exactly 3 colors (snow / ink / race-orange pulse), rarity as accent-ramp + glyphs (docs/03) |
| Maps | MapKit (Apple Maps engine) behind the `CoreMap` seam; Mapbox v11 is the planned swap (docs 07/09) |
| Persistence | SwiftData, local-first; server-authoritative cache eviction |
| Backend | **Django, live by default** in [`backend/`](backend/README.md) — Simulator debug builds read from it automatically (`GEMRUN_API_URL` env / Info.plist key / `mock` to opt out); 32 API tests green |
| Gem data | OpenStreetMap walkable ways (Overpass + mirrors, certifi TLS, circuit breaker); ODbL attribution applies |
| Status | **End-to-end gem loop working live** — spawn → map → collect → settle → audit |

## Running everything

One command on a Mac — starts the Django API (migrates, seeds street routes,
stocks gems, prints a full startup report), builds the app, launches the Simulator:

```sh
./run.sh            # backend + app
./run.sh backend    # just the API (works on any OS)
./run.sh app        # just the iOS app
./run.sh stop       # stop the background API
```

Useful knobs (env vars): `GEMRUN_API_URL=mock` (in-app mock), `SEED_DEMO=0`
(no demo routes), `WALKABILITY_MODE=off` (no OSM calls), `PRESENCE_DROP_MIN_RUNS`
(popularity gate; run.sh defaults it to 0 for dev), `GEMRUN_LOG_LEVEL=DEBUG`.

Simulator tip: **Features → Location → Custom Location** (or City Run) — the
Simulator has no real GPS; gems spawn wherever you point it. Watch it live:
`tail -f backend/.server.log` and `(cd backend && .venv/bin/python manage.py diagnose)`.

## Building the app manually

The Xcode project is generated, not committed. On a Mac:

```sh
brew install xcodegen        # once
xcodegen                     # generates GemRun.xcodeproj from project.yml
open GemRun.xcodeproj        # build & run the GemRun scheme (iOS 17+ simulator)
```

Logic + wire-format tests:

```sh
cd Packages/GemRunCore
xcodebuild test -scheme GemRunCore-Package -destination 'platform=iOS Simulator,name=iPhone 15'
```

Backend tests: `cd backend && python manage.py test` (32 tests).

Layout: `App/` (entry + tab shell) · `Packages/GemRunCore` (CoreModels, DesignSystem, GameKitCore, CoreMap, CoreLocationKit, CoreNetworking, CorePersistence) · `Packages/GemRunFeatures` (one target per screen area).

## Documentation index

Read in order — each doc only depends on lower-numbered ones.

| Doc | Purpose |
|---|---|
| [01 — Product Spec](docs/01-product-spec.md) | Personas, user journeys, MVP vs later, non-goals |
| [02 — Gameplay & Economy](docs/02-gameplay-and-economy.md) | Gem rarities, XP, streaks, placement budget, cold-start seeding |
| [03 — UX Spec](docs/03-ux-spec.md) | All 11 screens, navigation, interactions, design language |
| [04 — Run Tracking Mechanics](docs/04-run-tracking-mechanics.md) | GPS pipeline, collection detection, anti-spoof, battery budget |
| [05 — Data Model](docs/05-data-model.md) | Entities, relationships, client-side mirror |
| [06 — API Contract](docs/06-api-contract.md) | The endpoints the iOS client needs (lightweight) |
| [07 — iOS Architecture](docs/07-ios-architecture.md) | Stack decisions, module breakdown, testing strategy |
| [08 — Roadmap & Risks](docs/08-roadmap-and-risks.md) | Phases, exit criteria, risk register |
| [09 — Build Plan](docs/09-build-plan.md) | Implementation phases A–F with per-phase checkpoints |
| [10 — Pending Work](docs/10-pending-work.md) | What's done vs still open (auth, App Attest, deploy) |
| [11 — Dummy API](docs/11-dummy-api.md) | The in-app mock + endpoint-by-endpoint contract |
| [12 — How It Works & Gem Creation](docs/12-how-the-app-works-and-gem-creation.md) | Orientation: architecture, every gem-creation path, call chains |
| [13 — System Drops & Walkability](docs/13-system-drops-and-walkability.md) | Presence-triggered spawning, walkability checks, master table, race audit |

## The two hard problems (named up front)

1. **GPS spoofing** — people will fake runs to farm gems. The client is optimistic, the server is authoritative: full-track re-validation, pace sanity checks, accuracy gating (>50 m fixes can't claim), route-adherence rules, the ClaimAttempt audit log, and App Attest (planned). Docs 04, 06, 13.
2. **Placement trust** — gems must never sit on highways or private land. Layered defense: Apple walking-directions snapping at creation, OSM walkability verification at placement, collection-behavior signals (never-collected gems flag themselves), and user reports as backstop. Doc 13.
