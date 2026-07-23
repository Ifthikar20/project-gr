# GemRun

> **GemRun turns any running route into a treasure hunt.**
>
> Drop gems. Run routes. Collect what others left behind.

## What it is

Pick a route on the map, drop gems along it, and share it. Anyone who runs that route collects the gems as they pass — GPS confirms it. You're not just logging miles: you're leaving something behind for the next runner, and running someone else's route to see what they left for you.

**The core loop:**
1. **Create a route** — draw a path on the map
2. **Drop gems** — rare ones on the hard hills, easy ones near the start
3. **Publish it** — live for runners in your area
4. **Run and collect** — GPS-confirmed; gems go in your stash
5. **Compete or explore** — leaderboards, streaks, rare-gem hunts

**Why it works:** solo running is a motivation problem, not a fitness problem. Strava is social proof *after* the run; GemRun is a reason to go out in the first place — there's something waiting on the route.

## Tech snapshot

| | |
|---|---|
| Platform | Native iOS (iPhone), SwiftUI, iOS 17+ |
| Architecture | MVVM with `@Observable`, local SPM packages |
| Maps | MapKit today behind the `CoreMap` seam; Mapbox v11 + custom style is the planned swap (docs 07/09) |
| Persistence | SwiftData, local-first |
| Backend | Python (FastAPI assumed) — client ready in `CoreNetworking`, disabled until a base URL is set |
| Status | **Local-first MVP implemented (Phases A–E, F partial)** — see [doc 09](docs/09-build-plan.md) |

## Building the app

The Xcode project is generated, not committed. On a Mac:

```sh
brew install xcodegen        # once
xcodegen                     # generates GemRun.xcodeproj from project.yml
open GemRun.xcodeproj        # build & run the GemRun scheme (iOS 17+ simulator)
```

Logic tests (no simulator needed): `cd Packages/GemRunCore && swift test`

Mapbox token (needed from Phase C): copy `Configs/Secrets.example.xcconfig` → `Configs/Secrets.xcconfig` and fill in your token — the file is gitignored.

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

## The two hard problems (named up front)

1. **GPS spoofing** — people will fake runs to farm gems. The client is optimistic, the server is authoritative: full-track re-validation, pace sanity checks, route-adherence rules, and App Attest. Docs 04 & 06.
2. **Cold start** — an empty map is a dead app. One launch city gets 50–100 curated seeded routes, system-placed gems, a time-limited Founder set, and weekly Legendary events before public launch. Doc 02.
