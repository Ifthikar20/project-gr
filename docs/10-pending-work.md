# 10 — Pending Work

Status after the completion pass (dummy API + all implementable gaps closed).
Remaining items need things only the team can provide: a Mac with Xcode, a
Mapbox token, an Apple developer account, or the Django backend.

## ✅ Done since the MVP snapshot

- Dummy API layer: full 14-endpoint contract consumed by the UI (doc 11)
- Respawn enforcement — server-side in the mock verdict **and** client-side
  (already-collected drops are stripped before a run starts)
- Crash-safe append-only run buffer + "Resume run?" recovery on relaunch
- Elevation profile strip on Route Detail (synthetic profiles from the mock;
  real terrain data arrives with the backend)
- Editor: undo now re-snaps the whole path; "Close loop" helper chip
- Set-completion bonus (+500 XP, badge state on profile)
- Legendary seeded on the hard route (one-time respawn, first-find crown)
- Run Summary: per-km splits table + shareable run-card image (ImageRenderer + ShareLink)
- Next-gem chip bearing arrow (course-relative)
- Adaptive GPS distance filter (relaxes >500 m from the next gem)
- Battery instrumentation: %/hour logged to console per run (docs/04 gate)
- HealthKit workout write on completion (entitlement + purpose strings wired;
  fails silently if declined — remove the `entitlements` block in project.yml
  if signing complains)
- CoreHaptics rarity patterns with UIKit fallback
- Deep-link handler for `gemrun://route/{id}` + URL scheme registration
- App icon (generated faceted-gem artwork)
- GitHub Actions CI: GameKitCore tests on iOS Simulator

## Auth (added after the completion pass)

Sign in with Apple (native button), Google (SDK-ready stub), and guest login
are wired through `SessionStore.signIn`. **`AuthFlags.allowAllAccounts = true`
(CoreModels/Enums.swift) temporarily accepts every account** — provider
failures and guests included, no token verification. To go strict later:
1. Flip `AuthFlags.allowAllAccounts` to `false`.
2. Django verifies Apple `identityToken` / Google `idToken` in `POST /v1/auth/*`.
3. Google: add the GoogleSignIn-iOS SPM package, set `GIDClientID` in
   Info.plist + the reversed-client-ID URL scheme, and wire `GIDSignIn` where
   the `#if canImport(GoogleSignIn)` marker sits in `OnboardingView`.
4. Apple: requires a paid developer team for the `applesignin` entitlement —
   remove that line from project.yml if signing complains meanwhile.

## ⏳ Needs your Mac / accounts

- [ ] First Xcode build (`xcodegen` → build; code authored without a compiler — expect small fixes)
- [ ] GameKitCore tests green (Xcode, or the CI workflow on push)
- [ ] Simulator walkthrough with simulated location; physical-device run
- [ ] Mapbox swap: token in `Configs/Secrets.xcconfig`, SDK via SPM, reimplement
  the four `CoreMap` views, author the "Night Expedition" Studio style
- [ ] Signing/team setup; TestFlight; battery gate measured on device

## Django backend — ✅ IMPLEMENTED (backend/, verified: 12/12 tests green)

All 14 `/v1` endpoints live in `backend/` with the GameKitCore validation
pipeline ported 1:1 (`rules.py`, `geometry.py`, `validation.py`): track
replay, respawn dedupe, idempotent completion, server-owned streaks,
server-side gem fuzzing, placement-budget re-validation, seeded demo city
(`manage.py seed`). `ALLOW_ALL_ACCOUNTS` mirrors the iOS auth dev flag.
To connect: run the server (backend/README.md) and set `AppConfig.apiBaseURL`.

Still open on the backend track:
- [ ] Real Apple/Google identity-token verification (flip both accept-all flags)
- [ ] App Attest verification; iOS offline sync-queue retry
- [ ] Production hardening (secrets, DEBUG off, hosts, rate limits) + deploy
- [ ] Real launch-city routes (OSM-derived, curated) + ODbL attribution
- [ ] Moderation: report triage, blocklist zones, name checks; push notifications

## Deliberately later (Phases 2–3, docs/08)

Social/following, challenges/events, Live Activities, Apple Watch, audio cues,
Legendary notifications, monetization (cosmetic only), Android.

## Known approximations (documented, not blocking)

- Epic "hard segment" rule ≈ "route ≥ 8 km" until real elevation data exists
- Waypoints/gems are tap-placed (drag-to-reposition is a polish item)
- Mock streak trust: `clientStreakDays` is client-supplied until Django owns it
