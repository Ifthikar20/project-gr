# 15 — Completed Features, Page by Page

Everything that is **built and working** as of 2026-07-29, organized the way
the user sees it: screen by screen, then the backend systems underneath.
Docs 12–14 explain *how* the deep systems work; this doc is the flat list of
*what exists*, with the logic behind each piece and where it lives in code.

```
Tabs:  Explore  ·  Stash  ·  Compete  ·  Profile        (+ full-screen covers:
                                                          Plan Route, Active Run)
```

---

## 1. Explore (map home)

**The map is never empty and never lies.**
- First open runs a gate: location permission → GPS fix → `GET /v1/drops`
  (which stocks the area server-side) → only then is the map revealed, pins
  already in place. An opaque cover shows "Finding you…" / "Stocking gems
  near you…" states; denied permission gets a Settings call-to-action;
  a failed fetch gets Retry — a bare map never stands in for an error.
  (`FeatureExplore/ExploreRootView.swift`, `FirstLoad` enum)
- If an area legitimately has zero gems (fail-closed placement found no
  trusted walkable geometry), a banner says so honestly: "No gems in this
  area yet — check back soon."

**Location capsule.**
- Reverse-geocoded "Street · City" capsule at the top of the map (CLGeocoder,
  on-device, re-geocodes only after ~200 m of movement).
- **Tap it → the camera animates (~0.6 s) back to your current position** at
  a neighborhood zoom. Repeat taps keep working (counter-driven, not a bool).

**Gem pins.**
- Every pin renders through `GemIcon` (`CoreMap/MapProviding.swift`): if an
  asset-catalog PNG named by the catalog's `iconRef` (e.g. `gem.amber`)
  exists it is used, else an emoji fallback — the seam for the custom PNG
  art set is already in place; dropping PNGs into Assets.xcassets is all
  that's left.
- **Tap a gem → info card**: name, rarity ("Rare gem"), and a **rotating
  real fact** about the material — every open advances to the next fact
  (persisted per gem in UserDefaults), and tapping the fact advances it
  live ("Tap for another fact"). All 27 catalog gems carry 3 researched
  facts. (`GemInfoSheet.swift`, `CoreModels/GemCatalog.swift`)
- **"Walk or run to collect"** on that card snaps a real walking path from
  you to the gem (MKDirections) and starts a free run along it, named
  "Run to Amber" etc. Arriving collects it by proximity; every other gem
  on the way stays collectable.

**Recommended routes.**
- Client-side synthesis: 4 walking routes starting at your live position,
  visiting different combinations of nearby gems; regenerated after ~100 m
  of movement or via the refresh button.
- **Names are varied, not repeating**: drawn from a large pool with a
  seeded RNG (day + ~500 m cell), so names differ between routes, days,
  and places — and the chosen name carries through to the run, summary,
  share card, and stash provenance. (`RouteRecommender`)
- Route cards show miles, feet of climb, difficulty, rarity dots.

**Destination mode + drop mode.**
- Destination pin: tap the map → snapped walking path from you to the pin,
  distance label, "N gems on the way", Start Run builds a point-to-point
  route.
- Drop mode: give one of your stash gems away on the map. A validator
  gates spots — trails you've run, published routes, or runnable public
  POIs (parks, cafes, transit…) are allowed; hospitals, schools, parking,
  private-looking places are denied with a human-readable reason.

**Freshness.**
- Refetch when GPS first lands, after a >1.5 km move, every time the app
  returns to the foreground, and on a **location-capsule tap** (recenter +
  reload in one gesture — the drive-somewhere-new fix) — collected gems
  vanish, new spawns appear, no relaunch needed.
- When the server answers instantly while still restocking the area in the
  background, the response says so (`stocking: true`): the map shows
  "Stocking gems near you…" and refetches automatically a few seconds
  later, so fresh pins appear with zero user action.
- Reveal is gated only on the drops call — routes fetch concurrently, the
  routes endpoint answers in a fixed number of queries regardless of page
  size, and responses are gzipped.

## 2. Plan Route (the + button)

- Dots you drop are numbered 1, 2, 3… and every leg between consecutive
  dots is **snapped to a real walkable path** (MKDirections walking) — the
  drawn line is the path you'd actually walk, never a straight
  displacement line, and the distance shown is the walkable-path length.
- **Unwalkable dots are rejected**: if no walking route can reach a dot
  (highway median, water, private land), the dot is refused with a notice
  instead of drawing a fake segment. Fail-closed, same philosophy as gem
  placement.
- **"Another path"**: if you'd rather take an easier way, one tap cycles
  through alternate walking routes over the *same dots in the same order*
  (uses MKDirections alternates; a spinner shows while computing; Next is
  gated until every leg is snapped).
  (`FeatureRouteCreation/RouteCreationFlow.swift`, `CreationSteps.swift`)

## 3. Active Run

- **Guide line that consumes itself**: on a run with a planned path, only
  the not-yet-covered remainder of the line is drawn — the part behind you
  disappears as you cover it (75 m corridor, so running on the sidewalk
  across the street from the drawn line still counts), and your actual
  ink-colored breadcrumb takes over as the record of where you went.
  (`CoreMap` ActiveRunMapView: `consumeGuideLine`)
- **Collection at 100 ft** (30.5 m), mirrored exactly by the server so the
  client never celebrates a gem the backend would revoke.
- **Collection ceremony**: rarity-colored burst + haptic → the gem flies
  from mid-map into the **stash chip** (top-left count of this run's haul)
  → the chip does a soft catch-bounce and a small **"+1" in the gem's
  rarity color drifts up from the chip and fades** — the subtle
  "just stashed it" receipt, readable in peripheral vision.
- **Next-gem chip**: rarity, live distance in ft/mi, a bearing arrow that
  rotates with you, and an ETA at your current pace ("Rare · 240 ft ·
  ~2:15").
- Stats band: time, **miles**, live steps (pedometer), **min/mi** pace.
- **Pocket mode**: lock the screen or background the app mid-run and
  tracking + gem capture keep going (background location, on only while
  a run is live, with iOS's indicator showing; the OS auto-pause that
  silently kills backgrounded GPS is disabled — the app's own
  speed-based pause handles stops). A gem grabbed while pocketed posts
  a local notification ("Gem collected!"); permission is asked at run
  start. Just open the app, tap Start Run, pocket the phone.
- Auto-pause when you stop moving; long-press to stop (deliberate
  friction); battery drain logged per run against the docs/04 budget.

## 4. Run Summary + Run Card

- **Flippable run card**: front = the run (name carried from the route,
  date, route shape drawn from your actual track, time / distance /
  pace / steps / **calories** / gems); back = the finds — each gem with
  icon, tier, and a real-material line, grouped with ×N for repeats.
  Flip is animated; the card renders to a **shareable image** (share
  sheet).
- XP breakdown with streak multiplier; walks earn half XP and no
  leaderboard time (stated in copy, never punitive).
- **Tier-completion bonus**: collecting every gem of a rarity tier awards
  +500 XP — "All Rare gems found!" — matching what the Stash visibly
  tracks.
- Steps come from Health for the run window, falling back to the live
  pedometer count when Health hasn't flushed yet; the finished run is
  saved back to Health as a workout.

## 5. Stash

- **Grouped by rarity tier, not themed sets**: "Common gems" →
  "Legendary gems", commonest first, alphabetical within a tier, found
  count per header ("3/7", pulse-colored when complete). Uncollected gems
  are grey silhouettes named "???" — the pull to fill the grid. The old
  set names (Ancient Relics, Trailblazer…) are gone from every surface.
- **No wallet — the stash IS the gem economy**: server truth via
  `GET /v1/stash`, merged into the local cache on launch, Stash open, and
  pull-to-refresh (survives reinstalls; gems from other devices appear).
  New accounts receive a **welcome gift** at first login — a deterministic
  starter set (3 common, 2 uncommon, 1 rare) that shows in the stash like
  any find, labeled "Welcome gift" in its detail card. Dropping a gem on
  the Explore map spends an actual stash gem: the row is flagged dropped
  (server + local), can't be spent twice — even racing — and stays
  visible in the collection. Legendaries can never be given away.
- **Tap a collected gem** → detail card with the gem icon, tier, the same
  **rotating real facts** as the map card (shared rotation counter, so
  the fact advances across surfaces), first-find crown, and provenance
  (which run, what date).

## 6. Compete

- **My Routes**: your completed runs as cards — server truth
  (`GET /v1/runs/mine`) merged with local runs (local wins on conflict),
  so finished runs survive reinstalls once synced.
- **Friends**: the friends board, ranked by weekly XP (week resets
  Monday 00:00 UTC), with weekly distance and run counts. You are always
  on the board.
- **Swipe left on a friend → remove** (one-directional follow model —
  removing them from your board never touches their board).
- **Search** (magnifier, top bar): find any player by username (min 2
  chars, 300 ms debounce, up to 20 results, yourself excluded); tapping
  Add follows them and refreshes the board in place.
  (`FeatureCompete/CompeteRootView.swift`; backend `players`, `friends`,
  `friend_detail`, `my_runs` views + `Friendship` model)

## 7. Profile + Settings

- **Profile is slim by design**: identity (handle, level, XP progress) and
  streak (flame, shields, multiplier note). My Routes and Lifetime stats
  were **removed** (run history lives in Compete → My Routes); there was
  no backend for those sections to remove.
- **Settings** (under Profile):
  - **Account, spelled out**: sign-in provider, username on file, an
    explicit "Email: not stored" row, and a username editor with **live
    availability checking** (debounced `GET /v1/handles/check`, server
    enforces uniqueness with a 409 on rename races). Footer states
    exactly what's on file; sign out.
  - **Permissions, with real switches**: two in-app Apple Health toggles
    that take effect instantly (save workouts / read steps — off means
    the feature doesn't run), live status rows for Location and Motion,
    and a system-settings link only as the last resort.
  - **Your data**: the explicit page now also covers credential
    hashing — session tokens and Apple/Google sign-in IDs are stored
    only as one-way SHA-256 digests, never plaintext; no email, phone,
    or password ever stored; usernames are public by design.
  - **Legal**: full Terms and Privacy Policy as in-app sheets.
  - **About**: version + auto-incremented build number.
  - **Danger zone at the very bottom**: "Erase all local data" and
    "Delete account & data" (server delete → local erase → sign-out;
    placed gems anonymized — App Store 5.1.1(v) compliant).
  (`FeatureProfile/ProfileRootView.swift`, `SettingsView.swift`)

---

## 8. Backend: the gem-loading contract (docs 13–14 in one paragraph)

- **Works from anywhere**: the map query *is* the trigger. Log in from
  home, office, college, another city — a warm area answers instantly and
  restocks in the background; a cold area bootstraps inline so the first
  answer arrives already stocked.
- **Shared world**: gems are one pool for everyone. If someone already
  stocked your area, you see *their* world (band check makes your open a
  no-op); if not, you're the first to disperse gems there without knowing
  it.
- **Per-mile contract**, counted radially within 1 mile of the open point:
  **floor 20** (below → restock), **fill target 35**, **hard max 50** —
  counting everyone's system gems; player drops don't count. Safety beats
  floor: where geometry can't support 20 trusted placements, fewer is
  accepted (never misplaced gems), retried on later opens.
- **No overpopulation under concurrency**: every insert re-counts inside a
  write-serialized transaction (SQLite `BEGIN IMMEDIATE`) and checks both
  the requester's and the candidate's mile; a read-time trim
  (`enforce_hard_max`) catches the one spill case two simultaneous
  neighbors can cause (found by the Dallas race test: 53 → trimmed to 50).
- **Daily rotation**: uncollected system gems from before today expire on
  the next open and the area restocks at fresh positions — **gems never
  repopulate in the same spots the next day**.
- **Placement is fail-closed and snapped**: every system gem must sit
  exactly ON the strict pedestrian network (OSM sidewalks, trails,
  promenades — driveways, farm tracks, road centerlines, entrance steps,
  parking aisles all excluded). Tier 1 candidates from route polylines
  are SNAPPED onto the nearest such way within 25 m or rejected — a route
  along a bare residential street gets no gems, and nothing lands beside
  a yard. No trusted geometry → no gem; player drops need a real
  sidewalk/trail nearby too.
- **Timeout discipline**: inline bootstrap 12 s budget, background jobs
  60 s, per-mirror Overpass timeouts capped to remaining budget, a 120 s
  circuit breaker, and the iOS client at 15 s/request so the app never
  hangs on a slow area.
- **Verified**: 43 backend tests green; a 10-location Dallas simulation
  (downtown → suburbs, overlap pair, forced 2-thread race) passed the
  20–50 contract at every spot, with warm re-logins answering in ~6 ms.

## 9. Backend: everything else

- **Stash & welcome gift**: `GET /v1/stash` is the source of truth;
  `grant_welcome_gift` seeds every new profile (6 gems, deterministic);
  `POST /v1/drops` spends a locked stash row (`dropped_at`), keeping the
  collection record. The old wallet (`/v1/wallet/sync`, Health-distance
  minting) is fully removed.
- **Runs**: submit/validate (server-side splits, pace, revocation),
  `GET /v1/runs/mine` history; XP with streak multiplier.
- **Friends**: `Friendship` model (one-directional), board query ranked by
  weekly XP, username search, unfollow endpoint.
- **Accounts**: provider/guest sign-in, username change, `DELETE` account
  with gem anonymization.
- **Performance**: `GemDrop(active, lat, lng)` index (was zero indexes),
  read capped at 200 newest drops, wasted per-request profile lookup
  removed. Known capacity: public Overpass supports ≈5–8k active
  miles/day; upgrade ladder documented (per-cell ways cache → Postgres +
  PostGIS → self-hosted Overpass).

## 10. Cross-cutting

- **Imperial everywhere**: miles, feet, min/mi via one formatter
  (`CoreModels/UnitFormat.swift`, 1609.344 m/mi); models stay metric.
- **Design system**: Daybreak Pulse — snow surfaces, ink text, two
  maintained accents shared with the landing page: map green (#61FF00,
  map & game graphics) and pulse violet (#5F40BF, chrome); rarity =
  accent-opacity ramp + distinct glyphs (never color alone).
- **Custom gem art pipeline**: drop PNGs into `GEMS_REPO/` (named by
  material — "Emerald_Gem.png") and build: `scripts/import-gem-art.sh`
  downscales each once to 216 px (72 pt @3x, the largest in-app render)
  and writes the imagesets; `GemIcon` prefers the PNG, falls back to
  emoji, and caches existence verdicts per launch so missing art never
  costs repeated bundle probes.
- **No-lag practices**: warm map answers never wait on stocking; guide-line
  math is incremental; images/annotations reuse identity; network calls
  carry strict timeouts.
- **Build versioning**: `run.sh` stamps every build with the git commit
  count as its build number; Settings > About shows "0.1.0 (N)" so each
  build/release is identifiable.

## 11. Deliberately not built yet

- Custom PNG gem art: the import pipeline is built and the first material
  (emerald) is in hand — the remaining 20 materials are waiting on art
  (see GEMS_REPO/README.md for the list and naming).
- Per-cell walkable-ways cache / Postgres + PostGIS / self-hosted Overpass
  (the documented scaling ladder — not needed at current load).
- `/v1/routes` N+1 read optimization; respawn windows within a single day;
  hosting the privacy policy at a public URL.
