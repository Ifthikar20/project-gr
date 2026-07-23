# 08 — Roadmap & Risks

Rolls up the phased plan and every open decision/risk flagged across docs 01–07.

## Phases

### Phase 0 — Foundations (~2 weeks)
- Freeze the doc 05 data model and doc 06 contract (client + future backend both build against them).
- Author "Night Expedition" map style v1 in Mapbox Studio (doc 03).
- DesignSystem tokens: colors, type scale, rarity palette, haptic patterns.
- Gem icon set: 5 rarity tints × initial set silhouettes (SVG).
- **Pick the launch city**; run the OSM route-extraction + manual curation pass (doc 02).
- Xcode project + SPM package skeleton per doc 07.

### Phase 1 — MVP (~8 weeks)
Everything in doc 01's MVP table, built roughly in this order:
1. CoreModels, GameKitCore + fixture tests (the pure heart, no UI blockers)
2. CoreLocationKit + ActiveRunEngine (device-testable early — battery data starts accumulating)
3. Explore + Route Detail on the custom style
4. Active Run + Run Summary (the loop closes here — first dogfoodable build)
5. Route Creation flow
6. Stash, Compete, Profile, Onboarding
7. CoreNetworking against the doc 06 contract; sync queue; optimistic reconciliation

**Exit criteria (all required):**
- The doc 01 Journey 1 (first run) completes end-to-end on a device against the live backend.
- Battery < 8%/hour on a 45-minute screen-locked run, mid-tier device (doc 04 gate).
- Server-validated collection round-trip works: claim → verdict → stash/leaderboard reconcile, including a deliberately spoofed track being flagged.
- TestFlight open in the launch city with seeded content live.

### Phase 1.5 — Hardening (~3 weeks)
- Server-side anti-spoof tuning on real TestFlight tracks; App Attest enforcement on.
- Moderation: report-route triage flow, placement blocklist zones.
- HealthKit workout write.
- Crash/battery/perf polish from TestFlight telemetry.
- **Public App Store release** (launch city framing in listing).

### Phase 2 — Social & events
Following/friends + activity feed, push notifications (Legendary seeds, "someone ran your route"), challenges/events, Live Activities for Active Run, second/third city seeding.

### Phase 3 — Expansion
Apple Watch companion, monetization exploration — **cosmetic only** (gem skins, creator customization); never pay-for-XP or paid shields — and the Android go/no-go decision.

## Risk register

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | **Background GPS vs App Store review** — location background mode + gamified collection invites scrutiny; sloppy purpose strings risk rejection | Launch delay | When-In-Use only; background enabled only during runs (docs 04/07); honest priming copy (doc 03); review notes with demo video of a real run |
| 2 | **Mapbox MAU pricing** scales with success | Margin erosion | `MapProviding` seam isolates the SDK (doc 07); usage monitoring from day one; MapKit-fallback contingency documented; Directions calls debounced |
| 3 | **GPS spoofing not fully solvable client-side** (jailbroken devices can defeat attestation) | Leaderboard credibility | Accepted openly. Server-authoritative validation + App Attest + shadow-flagging (docs 04/06); flagged ≠ publicly accused (doc 03); economy caps limit farming value (doc 02) |
| 4 | **Cold-start execution quality** — algorithmic routes that feel robotic kill the first impression | Retention in launch city | Manual curation pass on every seeded route; single-city focus; Founder-set urgency; weekly Legendary as recurring event (doc 02) |
| 5 | **Safety & moderation** — creator gems could lure runners to unsafe/private locations | User harm; brand | Gems snap to routed public paths only (doc 03); placement blocklist zones (Phase 1.5); report button in MVP (doc 03); creator attribution |
| 6 | **Location privacy** — GPS tracks are sensitive personal data | Legal/trust | Home-area fuzzing default-on (docs 03/05); Local board uses ~5 km geohash only; stated retention policy + full account deletion in MVP (docs 03/06); tracks never exposed to other users |
| 7 | **OSM ODbL attribution** for seeded routes | License compliance | Attribution screen in-app settings + App Store listing credit (doc 02) |
| 8 | **Battery complaints** are the canonical 1-star review for GPS apps | Store rating | Doc 04's < 8%/hr budget is a **launch gate** in Phase 1 exit criteria; per-build TestFlight measurement protocol |
| 9 | **Empty-creation risk** — users run seeded routes but never create | Content flywheel stalls | Creation surfaced via "+" prominence and empty states (doc 03); Sam-persona creator prestige loops (run counts, boards); revisit creator XP incentives in Phase 2 with moderation live |

## Open decisions deliberately deferred

- Launch city selection (Phase 0 task — pick where the team can physically test).
- Backend stack details beyond "Python/FastAPI + the doc 06 contract" — out of scope per project direction.
- Notification strategy specifics (Phase 2).
- Monetization design (Phase 3; cosmetic-only principle already locked).
