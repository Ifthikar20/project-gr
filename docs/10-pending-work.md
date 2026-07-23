# 10 — Pending Work

Everything not yet done, in recommended order. Snapshot at the end of the
local-first MVP implementation (phases A–E complete, F partial).

## 1. Verify first (Xcode)
- [ ] First compile: `xcodegen` → build the GemRun scheme (code authored without a compiler; expect small fixes)
- [ ] `cd Packages/GemRunCore && swift test`
- [ ] Simulator walkthrough with simulated location (custom GPX along a seeded route)
- [ ] Physical-device run: create a short route, walk it, collect a gem

## 2. Known gaps in current code
- [ ] **Respawn enforcement** — daily / once-per-user dedupe is not checked at collection time; re-running a route re-collects everything (highest impact)
- [ ] Crash-safe append-only mid-run sample buffer + "Resume run" recovery (docs/04)
- [ ] Elevation: created routes have 0 m gain; Epic hard-segment rule approximated as "route ≥ 8 km"; no elevation profile strip
- [ ] Editor polish: undo re-snap, draggable waypoints/gems, loop-close helper
- [ ] Set-completion bonus (500 XP + badge); Legendary seeding + first-find logic
- [ ] Run Summary: splits table, share-card image export
- [ ] Next-gem bearing arrow (distance-only today)
- [ ] Adaptive GPS distance filter + battery instrumentation (< 8%/hr gate unmeasured)
- [ ] HealthKit workout write (Phase 1.5)
- [ ] Deep-link handler for `gemrun://route/{id}`
- [ ] CoreHaptics patterns (basic UIKit generators today)

## 3. Mapbox swap (docs/07 decision)
- [ ] Mapbox account + token in `Configs/Secrets.xcconfig`
- [ ] Add Mapbox v11 SPM dependency; reimplement the four views in `CoreMap` (only module that touches a map SDK)
- [ ] Author "Night Expedition" style in Mapbox Studio; switch snapping to Mapbox Directions

## 4. Backend & multi-user (Phase F proper)
- [ ] FastAPI backend per docs/05–06 (auth, routes CRUD + geo-query, catalog, stash, leaderboards)
- [ ] Server-side run validation re-running the GameKitCore rules (fixture tests = server test vectors)
- [ ] App: set `AppConfig.apiBaseURL`; Sign in with Apple; App Attest; sync queue with idempotency keys; optimistic-collection → server-verdict reconcile/revoke
- [ ] Real leaderboards, per-user gem fuzzing, moderation (report triage, blocklist zones, name checks), server-side account deletion, push notifications

## 5. App Store readiness
- [ ] App icon artwork + launch screen
- [ ] Signing, privacy nutrition labels, background-location review notes + demo video
- [ ] Real curated seed routes for the launch city (current seeds are synthetic circles); OSM ODbL attribution once OSM data is used
- [ ] TestFlight; battery measurement protocol; optional macOS CI for `swift test`

## 6. Later by design (Phases 2–3, docs/08)
Social/following, challenges/events, Live Activities, Apple Watch, audio cues,
Legendary notifications, monetization (cosmetic only), Android.
