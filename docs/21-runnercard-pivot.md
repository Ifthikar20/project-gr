# 21 — The RunnerCard pivot: zones you walk, cards you mint

**Status:** shipped client-side behind the `runner_cards` feature flag (default ON).
**Brand:** RunnerCard · runnercard.app. Landing page (project-gr-ui) is the visual spec.

GemRun's map-drop mechanic (server-stocked gems, 200 ft instant capture) becomes a
collection game: large daily zones on real walkable ground, a kilometre walked inside
one mints a collectible Runner Card. Gems live on as one of the five card kinds and as
the legacy mode behind the flag.

## The mechanic

1. Launch lands on the map (Explore). 2–4 **zones** resolve around the user: circles of
   350–500 m radius anchored on parks/green polygons, scored by area + strict-pedestrian
   trail metres inside, picked by a seeded weighted draw — random across days, identical
   within one (seed = day × ~500 m cell, `StableSeed.daily`).
2. **Never on private or government land.** Candidate anchors are vetoed fail-closed
   (centroid + 8 perimeter probes at 0.8×radius) against closed no-go polygons: the
   backend's `NO_GO_AREA_FILTERS` ported — `access=private|no`, golf courses,
   school/kindergarten/college/university, `landuse=military|industrial|railway`,
   aerodromes. Empty beats misplaced, the server's own placement rule.
3. **Walk 1 km inside a zone → mint** (`ZoneRules.mintDistanceM`). Metres accrue while
   the app is foregrounded on the map or during an active run — never in background.
   Per-segment gates (`ZoneProgressTracker`): GPS accuracy ≤ 50 m, segment ≥ 3 m,
   gap ≤ 120 s, teleport > 8 m/s re-anchors, speed cap **per source** — 3.5 m/s on the
   map, 6.0 m/s during runs (a 4:00/km runner is 4.2 m/s and must count). Both-endpoints
   inside = full credit; rim straddle = half. Overflow carries; 3 mints/zone/day cap.
4. **The mint** (`CardMinter`): one seeded uniform draw against the published odds —
   legendary 1/900, epic 1/60, rare 1/12, uncommon 1/4, common the remainder — a uniform
   type roll (Gem/Gear/Creature/Artifact/Fact), a uniform face pick within the combo
   (degrades down the rarity ladder if a combo were empty; a catalog test forbids that),
   and the walk's stats stamped on (`MintStats`: metres, steps, pace when run-sourced, XP
   from the face). Ceremony: burst + card-back flight to the top-left binder chip + "+1"
   — the gem choreography, transplanted (`MintCeremonyOverlay`).
5. **The Collection** (Stash tab, renamed): minted cards as a wall of minis, tap for the
   full nine-part card (stage, name+XP, art, rarity band, three stat tiles, ability,
   found-most, flavor, serialed footer — the landing page anatomy, one `edge` color per
   rarity driving every accent). Gem tier sets continue below; "binder" survives only
   as flavor, matching the landing page's binder wall.

## Catalog policy

`RunnerCardCatalog` (CoreModels): the landing page's 13 named cards verbatim + a derived
gem-type face for every `GemCatalog` gem (lead fact = flavor; gem referenced by `gemID`,
**never re-keyed**) + fillers so every type×rarity combo is non-empty. Card UUIDs live in
a 100+ last-byte range, disjoint from GemCatalog's 1–53 — the backend's
`test_catalog_matches_client_uuids` mirror stays untouched. `RunnerCardCatalogTests`
enforces coverage, uniqueness, disjointness and reference resolution.

## Data sources & the server seam

Zone resolution is **client-side for now**, behind a protocol the API will replace:

```swift
public protocol ZoneProviding: Sendable {   // CoreModels
    /// nil = source unreachable (try next provider); [] = answered empty (stop).
    func zones(around center: Coordinate, day: Int) async -> [RunnerZone]?
}
```

Provider chain (injected at App root into `ZoneMintEngine`):

1. **`OverpassZoneProvider`** (CoreNetworking) — one POST per refresh to the same two
   mirrors the backend uses; parks (`leisure=park|nature_reserve|garden`,
   `landuse=recreation_ground`), strict pedestrian ways (`footway|pedestrian|path`, no
   access aisles/indoor/private), and all no-go polygons in a 2.5 km circle;
   `[out:json][timeout:15]`, `out geom 1200`; per-mirror 15 s; 429/504 = failure; all-fail
   opens a 120 s breaker. **Etiquette:** identifying User-Agent with contact
   (`RunnerCard-iOS/0.1 (+https://runnercard.app; hey@runnercard.app)`); the day-cache
   means ≈1 request per user per day — acceptable for beta, not for scale; the server
   takeover (this doc's whole point) removes the on-device dependency. Multipolygon
   relations are not resolved — the same v1 limitation the backend accepts.
2. **`LocalSearchZoneProvider`** (CoreMap) — MKLocalSearch park anchors when Overpass is
   down: banned-name and forbidden-POI screens (fail closed), synthetic rings, max 3
   zones. Park pedigree is the whole safety argument, so fewer zones beat wrong zones.

State: day's zones + partial metres in UserDefaults (`gemrun.zones.v1`,
`gemrun.zoneProgress.v1` — disposable by design); minted cards in SwiftData
(`StoredRunnerCard`, registered in BOTH `GemRunApp`'s Schema and `Persistence.models`).
Runs feed the same tracker via `ActiveRunEngine.onSample`; a 10 s run-priority window in
`ZoneMintEngine.ingest` stops Explore (observing beneath the run cover) from
double-counting. XP is optimistic via `SessionStore.recordCardMint` until the API owns
minting.

## Dev switches

- `gemrun.debug.mintThresholdM` (UserDefaults) or `RUNNERCARD_MINT_M` (env): shorten the
  kilometre for testing (e.g. 100).
- Settings › Features › Runner Cards: OFF restores the gem map wholesale.

## Rename policy (deliberate)

User-facing strings only became RunnerCard. Kept unchanged: bundle id
`com.gemrun.GemRun`, `gemrun://` scheme, `gemrun.*` UserDefaults/Keychain keys, SPM
package names, `"GemRun/auto"` sentinel, `GemLog`, run.sh internals, backend names —
renaming those signs users out, breaks deep links and re-provisions the app for zero
user-visible gain. Revisit at the paid-team migration.

## Test surface

`GameKitCoreTests`: `ZoneSelectorTests` (determinism, no-go veto, trail gate, separation,
clamps), `PolygonTests` (ray-cast, bbox, shoelace), `OverpassZoneParserTests`
(classification fixtures, query contract), `ZoneProgressTrackerTests` (the gate matrix,
resume, overflow, caps, per-source speeds), `CardMinterTests` (odds over 100k seeded
mints, determinism, ladder degrade), `RunnerCardCatalogTests` (coverage/UUID policy).
All pure — CI job 1 runs them; no backend test changes.
