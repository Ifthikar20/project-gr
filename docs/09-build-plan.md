# 09 — Build Plan (Phases A–F)

Step-by-step implementation phases for turning docs 01–08 into a shipping app. Each phase ends in a **checkpoint** you can verify.

## Status

| Phase | State |
|---|---|
| A — Skeleton | ✅ done |
| B — Game logic + tests | ✅ done (`CollectionEngine`, `RouteGeometry`, `RunValidator`, fixture tests) |
| C — Map screens | ✅ done via **MapKit** behind the `CoreMap` seam (Mapbox + custom Studio style remains the planned swap — same views, add SDK + token) |
| D — Run loop | ✅ done (`LiveRunRecorder`, `ActiveRunEngine`, Active Run + Summary screens) |
| E — All screens | ✅ done (creation flow with budget enforcement, Stash, Compete, Profile, Onboarding) |
| F — Backend wiring | 🟡 partial: SwiftData persistence + local leaderboards done; `CoreNetworking` client for the docs/06 contract written but **disabled** (`AppConfig.apiBaseURL = nil`) until the FastAPI backend exists; Sign in with Apple + App Attest + sync queue deferred with it |

The app is fully usable **local-first**: seeded routes appear around your location, you can create/publish routes, run them, collect gems, and see stash/streaks/leaderboards — all on-device, through the dummy API (doc 11). The completion pass closed the earlier simplifications: crash-safe run buffer + resume, re-snapping undo, loop-close, splits, share card, set bonuses, Legendary seeding, bearing arrow, adaptive GPS, HealthKit write, CoreHaptics, deep links, app icon, CI. Current status lives in doc 10.

> **Environment note:** app code is authored in a Linux workspace (no Xcode/Swift toolchain). The `.xcodeproj` is therefore **generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)** from `project.yml` and never committed — build/run checkpoints happen on a Mac. Pure-logic packages (`GameKitCore`) are testable with `swift test` on any Mac or in CI without a simulator.
>
> **Structure note (small deviation from doc 07):** instead of ~14 separate SPM packages, modules are targets inside two umbrella packages — `Packages/GemRunCore` and `Packages/GemRunFeatures`. Identical modularity and dependency enforcement (per-target dependencies), a fraction of the manifest boilerplate.

## Phase A — Project skeleton *(this phase)*

| Step | Deliverable |
|---|---|
| A1 | `.gitignore`, `project.yml` (XcodeGen), `.swiftlint.yml`, `Configs/*.xcconfig` with untracked `Secrets.xcconfig` for the Mapbox token |
| A2 | `CoreModels` (doc 05 types) + `DesignSystem` (rarity palette, ink/gold colors, type, haptic patterns) — real implementations |
| A3 | `CoreNetworking`, `CorePersistence`, `CoreLocationKit`, `CoreMap` (`MapProviding` + placeholder provider), `GameKitCore` — compilable stubs with the doc 02/04 constants locked in |
| A4 | Seven feature targets, each rendering a placeholder screen |
| A5 | App target: entry point, 4-tab shell, `SessionStore`, Info.plist (When-In-Use location string, `UIBackgroundModes: location`) |

**✅ Checkpoint (Mac):** `brew install xcodegen && xcodegen && open GemRun.xcodeproj` → builds and runs in the simulator showing the Explore / Stash / Compete / Profile tabs.

## Phase B — The pure heart (logic before UI)

- B1: Implement `GameKitCore` for real: collection engine (25 m threshold, hysteresis, monotonic route progress), route-adherence projection, XP/streak/budget calculators (docs 02/04).
- B2: GPS **fixture tests**: clean run, noisy urban run, switchback graze, teleport spoof, walk pace — asserted outcomes for each.
- B3 (optional): GitHub Actions macOS CI running `swift test`.

**✅ Checkpoint:** `swift test` green in `Packages/GemRunCore`.

## Phase C — The map (Explore + Route Detail)

- C1: Mapbox SDK v11 via SPM; `MapboxMapProvider` implements `MapProviding`; token from `Secrets.xcconfig`; "Night Expedition" style URL.
- C2: Explore: styled map, route polylines, route-card carousel (local fixture data).
- C3: Route Detail: map preview, gem markers with fuzzed zones, elevation strip, Start Run CTA.

**✅ Checkpoint:** simulator shows the dark map with sample routes; tap-through to detail works.

## Phase D — The run loop

- D1: `CoreLocationKit` recorder — filtering, smoothing, auto-pause, crash-safe append-only buffer (doc 04).
- D2: `ActiveRunEngine` actor wired to `GameKitCore`; run survives navigation.
- D3: Active Run screen — chase camera, stats band, next-gem chip, collection burst + rarity haptics, slide-to-stop.
- D4: Run Summary — gem reveal, XP breakdown, splits.

**✅ Checkpoint:** on a **physical iPhone**, walk a short self-made route and collect a gem. GPX playback in the simulator for desk testing.

## Phase E — Creation, Stash, Compete, Profile, Onboarding

- E1: Route Creation 3-step flow (snap-to-path drawing via Mapbox Directions, budget-enforced gem placement, publish sheet).
- E2: Stash grid + gem detail. E3: Compete boards. E4: Profile + streak module. E5: Onboarding + permission priming.

**✅ Checkpoint:** doc 01 Journeys 1 and 2 work end-to-end with on-device data.

## Phase F — Persistence & backend wiring

- F1: SwiftData models + sync queue (doc 05 client mirror). F2: `CoreNetworking` against the doc 06 contract. F3: Sign in with Apple. F4: optimistic-reconcile flow.
- The FastAPI backend is a separate effort; the app runs on fixtures until it exists.

**✅ Checkpoint:** full round-trip against a running backend: publish → run → server verdict → stash/leaderboard reconcile.
