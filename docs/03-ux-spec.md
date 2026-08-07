# 03 — UX Spec

The centerpiece doc: every screen, its layout, interactions, and states. Consumes docs 01 (features/journeys) and 02 (economy → what screens must display).

## Navigation structure

```
Tab bar (4 tabs)
├── Explore  (map home)          ← "+" button opens Route Creation (modal flow)
├── Stash
├── Compete
└── Profile

Full-screen covers (hide tab bar):
├── Active Run                   ← from Route Detail "Start Run"
└── Route Creation flow          ← from Explore "+"

Push navigation within tabs:
└── Explore → Route Detail → Leaderboard (full)
```

- **Active Run is a `fullScreenCover`** — no tab bar, no accidental navigation mid-run. The run itself survives app navigation via a long-lived engine (doc 07); the cover can be dismissed to check something and re-entered from a persistent "run in progress" pill.
- **Deep links:** `gemrun://route/{id}` — used by share cards now, notifications in Phase 2.
- Route Detail is reachable from Explore (map/card), Stash (gem provenance), Compete (board row), and Profile (My Routes).

## Design language — "Daybreak Pulse" (Airbnb-style, 3 colors)

> Supersedes the original "Night Expedition" dark theme. Modeled on Airbnb's
> system: one brand color reserved for what matters, neutrals everywhere else,
> cards carrying the visual weight — soft 16pt corners, one diffuse shadow,
> hairline dividers, pill CTAs, generous whitespace.

- **Exactly two accents over the neutrals, nothing else** (opacity/tint steps of a hue count as the same color) — the same pair the landing page maintains:

| Token | Value | Role |
|---|---|---|
| Snow | #FAFAF8 bg / #FFFFFF cards | Surfaces |
| Ink | #16181D (+0.55 secondary text, +0.12 hairlines) | Text, icons |
| Map | #61FF00 map green (+ tint ramp) | Map & game graphics: route lines, pins, waypoint markers, on-map controls — always ink ON it, never white |
| Pulse | #5F40BF violet (+ tint ramp) | Chrome accent: CTAs, streaks, live pace, own rows |

- **Rarity = pulse ramp + glyph + label** (double-encoded, grayscale/color-blind safe): Common `diamond` 0.30 → Uncommon `diamond.fill` 0.50 → Rare `rhombus.fill` 0.70 → Epic `seal.fill` 0.88 → Legendary `crown.fill` 1.0.
- **Map:** light standard style, POIs suppressed; map-green polylines and glyph gem markers. *Constraint:* MapKit tiles keep Apple's own palette — the two-accent rule governs app chrome and overlays; a fully on-palette map is a benefit of the pending Mapbox custom style.
- **Cards:** Airbnb listing-card anatomy — mini map preview as the "photo" header on route cards; Route Detail is a listing page (map hero → hairline-separated sections → sticky bottom bar with facts left, pulse pill right).
- **Type:** SF Pro Rounded, display 26/semibold, heading 20/semibold — medium weights; the cards, not the type, carry the weight. Stats stay bold.
- **Gem iconography:** SF Symbol glyph per rarity tier (table above), tinted by pulse step. Silhouette (ink 12%) = uncollected.
- **Motion:** gems idle-shimmer on the map (subtle specular sweep, 4 s loop); collection is a radial burst; Stash reveals use a flip-from-silhouette.
- **Haptics are a first-class design element** (the phone is in a pocket mid-run):
  - Gem placement in editor: light tick.
  - Collection during run: `.success` notification + custom pattern scaled by rarity (Common = single thump; Legendary = escalating triple burst).
  - Streak saved by shield: distinct double-knock.
- **Accessibility:** all rarity information is double-encoded (color + gem shape + label); Dynamic Type through XL on all non-map screens; VoiceOver labels on map annotations; haptic collection cues are inherently non-visual.

## Screen inventory

### 1. Onboarding
**Purpose:** value prop → permissions → identity, in under 60 seconds.

- **Layout:** 3-page horizontal pager with full-bleed illustrations: (1) "Routes are treasure maps" (2) "Run to collect" (3) "Leave gems for others". Skip button from page 1.
- **Permission priming:** after the pager, a dedicated screen explains location in plain words ("GemRun uses your location during runs to confirm you passed each gem. While-using only — we never track you in the background outside a run."). Button triggers the real iOS dialog (**When In Use**). If denied: app remains browsable; a persistent banner on Explore explains what's off and links to Settings.
- **Sign in with Apple:** one screen, one button, "browse first" skip link (anonymous browse allowed; sign-in re-prompted at Start Run / Create).
- **Notifications prompt: deferred** — not asked during onboarding; asked after the first run summary ("Want to hear when rare gems appear nearby?" — Phase 2 functionality, permission groundwork in MVP).
- **States:** location denied (banner path), sign-in canceled (stay anonymous), restore session on reinstall.

### 2. Explore (map home)
**Purpose:** answer "what can I run right now?" in one glance.

- **Layout:** full-bleed map, user location puck center. Published routes render as gold polylines with a small origin marker showing gem count. Top-right: recenter button. Top: pill search-this-area button appears after panning. Bottom: horizontally swipeable **route cards** (snap carousel) for routes in viewport, sorted by distance from user.
- **Route card contents:** name, distance, elevation gain, gem summary as rarity-colored dots (● ● ●), top time, creator handle.
- **Interactions:** tap polyline or card → Route Detail; swipe cards ↔ highlights corresponding polyline; pinch/pan freely; **"+" FAB** (bottom-right, above cards) → Route Creation.
- **States:** empty viewport ("No routes here yet — be the first to create one" + "+" emphasis); location denied (city-level default view + banner); offline (cached routes shown, banner); loading (skeleton cards).

### 3. Route Detail
**Purpose:** everything needed to decide to run, without spoiling the hunt.

- **Layout (scrolling):**
  1. Map preview (60% height) — polyline + gem markers. **Common/Uncommon: exact positions. Rare/Epic/Legendary: a fuzzed dashed "zone" circle (~150 m radius)** until this user has collected it — finding it is the game.
  2. Stats row: distance · elevation gain · difficulty chip · run count.
  3. Elevation profile strip (sparkline with gem positions ticked; fuzzed gems tick a range).
  4. Gem manifest: rarity dots + names, collected ones checked.
  5. Leaderboard snippet: top 3 + own best if any → "View all".
  6. Creator attribution row.
  7. **Start Run** — large fixed CTA at bottom.
  8. Overflow menu: share, **report route** (safety/moderation — doc 08).
- **States:** already-collected gems dimmed with checkmark; anonymous user taps Start Run → Sign in with Apple sheet; route archived ("no longer available"); offline with cached detail (Start Run allowed — runs record offline, doc 04).

### 4. Route Creation — Step 1: Draw
**Purpose:** a drawing tool that feels like sketching, outputs a runnable path.

- **Layout:** full-screen map; top bar (Cancel · "Draw your route" · Next); bottom stats bar (live distance · elevation gain · waypoint count); floating Undo.
- **Interactions:**
  - Tap map → waypoint; **path auto-snaps between waypoints** via Mapbox Directions walking profile (roads, trails, paths — not through buildings).
  - Drag a waypoint to move it (path re-snaps); tap a waypoint → delete popover.
  - Undo steps back one waypoint; long-press Undo → clear all (confirm).
  - **Loop-close helper:** when the last waypoint is within 60 m of the start, a "Close the loop" chip snaps them together.
  - Next enabled at ≥ 1 km.
- **States:** snapping failure (dashed straight segment + "couldn't find a path here" toast, segment marked for fix before Next); draft auto-saved locally on Cancel ("Save draft / Discard").

### 5. Route Creation — Step 2: Place gems
**Purpose:** gem placement as level design, with the doc 02 budget enforced kindly.

- **Layout:** same map, route locked. Bottom **gem tray**: one row per rarity showing icon, name, point cost, and remaining slots/points ("Budget: 34/50 · Slots: 12/20"). Legendary row absent (server-only).
- **Interactions:**
  - Drag a gem from tray onto the route — it **snaps to the nearest point on the polyline**; light haptic tick on drop.
  - Placed gem: tap → remove or drag along route to reposition.
  - Invalid placements rejected with a toast explaining *why*: "Epics need a climb — this section is too flat", "Too close to another gem (100 m min)", "Rares must be at least 40% into the route".
  - Elevation strip at top mirrors placements; qualifying hard segments for Epics are highlighted gold on the strip.
- **States:** budget exhausted (tray rows dim with reason); zero gems placed (Next allowed but confirm: "Publish without gems?" — discouraged, permitted).

### 6. Route Creation — Step 3: Publish
**Purpose:** name it and ship it.

- **Layout (sheet):** route thumbnail, name field (required, 40 chars), optional description (140 chars), auto-computed difficulty chip (from distance × elevation — not editable), visibility "Public" (only option in MVP, shown so the model is explicit), **Publish** button.
- **Flow:** publish → server re-validates budget/spacing/Epic rules (doc 06) → success toast → deep-link to the new Route Detail. Validation failure returns to Step 2 with the offending gem highlighted.
- **States:** offline (queue as draft, "will publish when online"); name profanity/moderation rejection.

### 7. Active Run
**Purpose:** glanceable when looked at; fully functional in a pocket.

- **Layout:**
  - Top ~60%: map in **chase-camera** mode (course-up, runner puck centered lower-third, route ahead visible). Gems ahead shimmer; collected gems on this run turn to checkmarks.
  - Stats band: elapsed · distance · current pace (large, SF Rounded).
  - **Next-gem chip:** gem icon (rarity color), bearing arrow relative to heading, live distance countdown ("Sapphire · ↗ 240 m").
  - Bottom controls: tap-to-pause (large), **slide-to-stop** (deliberate friction against accidental stops).
- **Collection moment:** full-screen radial burst in rarity color + rarity-scaled haptic + short sound (respects silent switch). Burst auto-dismisses in 1.5 s; run never interrupts.
- **Background behavior:** screen locked → GPS and collection continue (doc 04); haptics/sounds still fire. Notification-style banner on lock screen is *not* used in MVP (Live Activities are a Phase 2 nicety).
- **States:** auto-pause (banner "Paused — resume moving", stats amber); GPS degraded (accuracy chip turns amber, "weak GPS" note); off-route > 40 m (gentle "off route" chip, no alarm — see doc 04 adherence); re-entry from the "run in progress" pill.

### 8. Run Summary
**Purpose:** the reward ceremony; also the honesty point for validation.

- **Layout (scrolling):**
  1. **Gem reveal:** collected gems flip in one by one, rarest last, with its haptic. Skippable by tap.
  2. XP breakdown: per-gem XP × streak multiplier, tier-completion bonus if any (all gems of a rarity tier collected), total. Streak flame increments here if this run extended it.
  3. Run stats: time, distance, avg pace, splits table, mini route map with collected-gem checkmarks.
  4. Leaderboard delta: "Your best on this route · #14 → #9" (or "Walk — no leaderboard time" per doc 02).
  5. **Share card:** rendered image (map thumbnail + gems + time) → share sheet.
- **Validation state:** if the server verdict is pending/flagged (doc 06): gems show as "pending verification" with a neutral, non-accusatory note ("We're confirming your run — gems will land in your stash shortly"). If revoked, gems quietly don't persist; leaderboard unaffected. Never call the user a cheater in UI copy.
- **States:** offline (everything computed optimistically, "will sync" badge); first-run special case → notification permission ask after dismissal.

### 9. Stash
**Purpose:** the collection — progress you can see, gaps you want to fill.

- **Layout:** grid grouped by **rarity tier** ("Common gems" → "Legendary gems", commonest first); within a tier, gems alphabetical. Uncollected = silhouette. Tier header shows found count ("3/7", pulse when complete). Above the grid: totals. There is NO wallet — the stash is the whole gem economy: server-truth via GET /v1/stash, seeded at signup with the welcome gift (3 common + 2 uncommon + 1 rare, deterministic), and drops on the Explore map spend actual stash gems (the row stays as the collection record, flagged dropped).
- **Gem detail sheet (tap):** gem icon, rarity tier, a rotating real-material fact (same per-gem rotation as the map's gem card — every open advances it), **provenance**: where/when collected. First-find flagged with a crown.
- **States:** empty ("Your stash is empty — run a route to start collecting" + CTA to Explore); seasonal/Founder sets show time-remaining chip.

### 10. Compete
**Purpose:** the two boards from doc 02, nothing more.

- **Layout:** segmented control — **Routes** | **Local**.
  - *Routes:* searchable list of routes the user has run (default) or any route via search; tapping → full leaderboard: all-time / this-month toggle, rank · handle · level · time. **Own row pinned** to bottom if not in view.
  - *Local:* weekly gem-score board for the user's geohash region; countdown to Monday reset; own row pinned.
- **States:** no runs yet (explainer + Explore CTA); user's run pending validation (row shows "verifying…"); walk-only runs absent by design (copy explains).

### 11. Profile
**Purpose:** identity, streak, and creations.

- **Layout:**
  1. Header: avatar, handle, level ring (XP progress to next level).
  2. **Streak module:** flame + day count, shield count (⛨ ×2), calendar strip of the current week.
  3. Lifetime stats row: total km · runs · gems · routes created.
  4. **My Routes:** list with per-route run counts and leaderboard size; tap → Route Detail; swipe → archive.
  5. Settings: units (km/mi), haptic intensity, privacy (fuzz home area toggle — on by default, doc 05), notifications (Phase 2 stub), sign out, **delete account** (required flow — doc 08).
- **States:** anonymous user (sign-in CTA replaces header); streak broken today-but-savable ("Run 1 km before midnight to keep your streak").

## Cross-cutting UX rules

- **Optimistic UI, honest reconciliation:** collections and XP display instantly; server verdicts reconcile quietly (doc 06). The app never blocks celebration on a network call.
- **Never interrupt a run:** no modals, no confirmations, no network-error dialogs during Active Run. Everything defers to the summary.
- **Empty states always point at the next action** (usually Explore or "+").
- **Copy voice:** adventurous but plain — "treasure", "hunt", "stash"; never gamer-jargon ("loot", "grind") and never fitness-shame ("only 2 km?").
