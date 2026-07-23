# 07 — iOS Architecture

Consumes docs 03 (screens), 04 (tracking pipeline), 06 (contract). Locks the stack and module seams.

## Stack decisions

| Decision | Choice | Rationale |
|---|---|---|
| UI | SwiftUI, iOS 17+ | Modern baseline; Observation framework requires 17 |
| Pattern | MVVM with `@Observable` view models | Not `ObservableObject`/Combine — Observation is simpler and faster |
| Navigation | `NavigationStack` per tab; `fullScreenCover` for Active Run & creation flow | Matches doc 03 nav map |
| Concurrency | async/await + actors throughout; no Combine except where an SDK forces it | |
| Persistence | SwiftData | + one append-only file for in-progress GPS samples (doc 04 crash-safety) |
| Maps | **Mapbox Maps SDK for iOS v11** | See below |
| Min devices | iPhone only, portrait-primary | Watch/iPad out of MVP scope |

## Maps: Mapbox v11 — rationale and trade-offs

**Why Mapbox over MapKit** (the deciding factors, per the product's needs):
- **Custom styling is the brand.** The "Night Expedition" treasure-map style (doc 03) is authored in Mapbox Studio and loaded by style URL. MapKit's styling surface is effectively zero.
- **Route creation.** First-class polyline annotation + the Directions API (walking profile) powers snap-to-path drawing and editing (doc 03 screen 4).
- **ViewAnnotations** host animated SwiftUI gem markers (idle shimmer) directly on the map.
- Offline tile packs are available later for offline Explore.

**Trade-offs, stated honestly:**
- MAU-based pricing after the free tier — a real budget line that scales with success (risk register, doc 08).
- Large SDK dependency (~tens of MB) and a third-party runtime vs MapKit's free, native, zero-download option.
- Directions API calls are metered (route drawing makes one per waypoint edit — debounced).

**Mitigation — the `MapProviding` seam:** all map usage goes through a protocol in `CoreMap` (render route, annotate gems, chase camera, snap path). Mapbox is the only implementation in MVP, but nothing outside `CoreMap` imports Mapbox. A MapKit fallback is a contained rewrite, not a rearchitecture.

## Module breakdown (local SPM packages)

```
App                     # entry point, tab shell, DI wiring, deep links
│
├── Features (one package per doc 03 area; each = Views + @Observable VMs)
│   ├── FeatureOnboarding
│   ├── FeatureExplore
│   ├── FeatureRouteCreation      # draw / place gems / publish (3-step flow)
│   ├── FeatureActiveRun
│   ├── FeatureStash
│   ├── FeatureCompete
│   └── FeatureProfile
│
└── Core
    ├── CoreModels          # domain types mirroring doc 05; no dependencies
    ├── CoreNetworking      # URLSession client for doc 06; DTO↔model mapping; auth/refresh
    ├── CorePersistence     # SwiftData stack, sync queue, append-only sample buffer
    ├── CoreLocationKit     # run recorder: CLLocationManager wrapper, filtering,
    │                       # smoothing, auto-pause (doc 04 pipeline)
    ├── CoreMap             # MapProviding protocol + MapboxMapProvider
    ├── GameKitCore         # PURE logic, zero UI/IO deps: collection engine
    │                       # (threshold+hysteresis+monotonic progress), route-adherence
    │                       # projection, XP/streak/budget calculators
    └── DesignSystem        # colors, type scale, gem icon set, haptic patterns,
                            # shared components (rarity dots, elevation strip, cards)
```

Dependency rule: Features depend on Core; Core packages depend only on `CoreModels` (and `CoreMap` on Mapbox). `GameKitCore` and `CoreModels` are pure — they compile on any platform, which is what makes them exhaustively unit-testable.

## Key runtime objects

- **`SessionStore`** (`@Observable`, in Environment): auth state, current User (xp/level/streak), reconciliation on sync. One instance, owned by App.
- **`ActiveRunEngine`** (actor, owned by App — *not* by a view): drives a run end-to-end — starts CoreLocationKit, feeds samples to GameKitCore's collection engine, appends to the sample buffer, exposes an `AsyncStream<RunState>` the Active Run screen renders. Because App owns it, **a run survives any navigation or view teardown**; the "run in progress" pill (doc 03) re-attaches the UI.
- **`SyncQueue`** (CorePersistence): drains pending run completions with backoff + idempotency keys (docs 04/06); listens for connectivity.

## Location & background execution

- Info.plist: `NSLocationWhenInUseUsageDescription` (copy from doc 03's priming screen), `UIBackgroundModes: [location]`.
- **When In Use only — never request Always.** Background updates flow because the session starts foreground and `allowsBackgroundLocationUpdates` is enabled *only* between run start and stop (doc 04). The blue "using your location" pill will show during backgrounded runs — expected and honest.
- App Store review implications (purpose-string quality, demo video in review notes) tracked in doc 08.

## HealthKit (MVP scope)

Write-only: at validated run completion, save an `HKWorkout` (running or walking per doc 02 pace) with distance + duration via `HKWorkoutBuilder`. Cheap credibility win — runs appear in the user's Health/Fitness rings. **No reads in MVP** (reads trigger heavier privacy review and add nothing to the loop). Permission requested on first run completion, not onboarding.

## State & data flow (per feature)

```
View ── observes ──▶ @Observable ViewModel ── calls ──▶ Core services
                     │                                     │
                     ◀── async results / AsyncStreams ─────┘
```
- ViewModels own screen state incl. loading/empty/error (doc 03 states); no service types leak into Views.
- Optimistic updates (collections, XP) applied to `SessionStore` immediately; server verdict reconciles (docs 03/06).

## Testing strategy

- **`GameKitCore` is the crown jewel:** unit tests with **recorded GPS fixture tracks** — a clean valid run, an urban-canyon noisy run, a switchback-graze attempt, a teleporting spoofed track, a walk-pace track. Collection, adherence, XP, and flag outputs asserted against each. Fixtures double as server-side test vectors later (same pipeline, doc 04).
- Budget/streak calculators: property-based tests (budget never exceedable; streak math across timezones/midnight).
- CoreNetworking: contract tests against recorded doc 06 fixtures.
- UI: smoke-level snapshot tests for DesignSystem components; full UI test automation deferred.
- Battery: not unit-testable — instrumented TestFlight protocol per doc 04.

## Project conventions

- Swift 5.10+, strict concurrency checking on.
- SwiftLint + swift-format from day one.
- Secrets (Mapbox token) via `.xcconfig` excluded from VCS; CI injects.
- Feature flags: a trivial local `FeatureFlags` struct in MVP (no remote config dependency yet).
