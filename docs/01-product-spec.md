# 01 — Product Spec

> GemRun turns any running route into a treasure hunt.

Drop gems. Run routes. Collect what others left behind.

## The problem

Solo running is a motivation problem, not a fitness problem. Strava solved motivation with social proof *after* the run — kudos, segments, comparisons. GemRun gives you a reason to go out *in the first place*: there is something waiting on the route. That's Pokémon Go's core insight, applied to a route you'd already be running.

## The core loop

1. **Create a route** — draw or select a path on the map.
2. **Drop gems** — place collectibles along it. Rare ones on the hard hills, easy ones near the start.
3. **Publish it** — the route goes live for runners in your area.
4. **Run and collect** — GPS confirms you passed each gem; collected gems go in your stash.
5. **Compete or explore** — per-route leaderboards, streaks, rare-gem hunts.

Every runner is both a player and a level designer. You're not just logging miles — you're leaving something behind for the next runner, and running someone else's route to see what they left for you.

## Personas

### Maya, 29 — The Streak Runner
Runs 3×/week, same neighborhood loop, motivation eroding. Doesn't need a training plan; needs novelty and a reason to pick a *different* route today.
**What GemRun gives her:** a streak worth protecting, fresh gems on routes she hasn't tried, a leaderboard on her home loop.
**Success metric:** weekly runs sustained; distinct routes run per month.

### Dev, 34 — The Collector
Lapsed runner, heavy Pokémon Go history. Motivated by collection completeness and rarity, not pace. Will walk 5 km for an Epic gem.
**What GemRun gives him:** a stash with visible gaps, themed sets, rare-gem hunts that reward showing up over being fast. Walking pace still collects (at reduced XP — see doc 02).
**Success metric:** lapsed-to-active conversion; stash growth; set completions.

### Sam, 41 — The Route Creator
Organizes a local run club. Knows every good loop in the area. Wants tools to share them and proof that people use them.
**What GemRun gives them:** a satisfying route editor, gem placement as level design, run counts and leaderboards on their published routes.
**Success metric:** routes published; runs per published route.

## Core user journeys

### Journey 1 — First run (Maya, day 1)
1. Installs the app, swipes through 3 onboarding pages.
2. Sees a friendly explanation of why location is needed, then grants "While Using" location.
3. Signs in with Apple (one tap).
4. Explore map shows 3 seeded routes within 2 km of her, gold lines on a dark map.
5. Opens a 5 km loop's detail page: 6 gems, elevation chart, current best time.
6. Taps **Start Run**, pockets the phone.
7. Feels four haptic bursts during the run as she collects gems — never looks at the screen.
8. Stops; summary reveals 4 gems (one Rare), 135 XP, 14th on the leaderboard.
9. Opens her Stash: 4 gems in place, 16 silhouettes to chase.

### Journey 2 — Create and publish (Sam)
1. Taps **+** on Explore.
2. Taps waypoints along the club's Tuesday loop; the path snaps to streets and trails; distance/elevation update live.
3. Advances to gem placement: drags 2 Commons near the start, 1 Rare mid-route, 1 Epic onto the steep section (the editor confirms the grade qualifies).
4. Names it "Tuesday Torture", publishes. It's live on nearby runners' maps immediately.
5. That week, sees 9 runs on it and a leaderboard forming.

### Journey 3 — Rare-gem hunt (Dev)
1. Notification: "A Legendary gem appeared on Ridge Loop." *(Phase 2 — in MVP, Legendaries are discovered on the Explore map.)*
2. Route detail shows a fuzzed zone circle near the summit — exact spot unknown.
3. Runs (mostly hikes) the route on Saturday; collects it at the summit switchback.
4. First finder: gets the unique "first find" variant. Shares the summary card.

### Journey 4 — Streak maintenance (Maya, day 6)
1. Profile shows a 6-day flame and 1 banked streak shield.
2. It's raining; she runs a minimal valid run (≥ 1 km) around the block, collects a daily-respawn Common.
3. Streak holds; day 7 raises her XP multiplier and banks another shield.

## Feature list — MVP

| Feature | Notes |
|---|---|
| Sign in with Apple | Anonymous browsing allowed; sign-in required to run or create |
| Explore map | Nearby published routes, custom map style, route cards |
| Route detail | Polyline, gems (Rare+ fuzzed), elevation, leaderboard snippet |
| Route creation | Tap-to-draw with path snapping, live stats |
| Gem placement | Rarity budget by distance; hard-segment rule for Epics |
| Active run | Background GPS, live collection with haptics, auto-pause |
| Run summary | Gem reveal, XP breakdown, splits, share card |
| Stash | Collection grid, sets, silhouettes for missing gems |
| Leaderboards | Per-route best time; weekly local gem score |
| Streaks | Daily streak, XP multiplier, shields |
| Seeded launch city | 50–100 curated routes with system-placed gems (see doc 02) |
| Report route | Safety/moderation basic flow |
| Account deletion | In settings; App Store requirement |

## Explicitly later (Phase 2+)

- Following / friends / activity feed
- Clubs and group challenges / events
- Gem trading or crafting — **deliberately excluded from MVP**: any exchange economy multiplies the anti-cheat surface and can be added later without breaking the collection model
- Apple Watch companion app
- Audio coach cues during runs
- HealthKit *reads* (MVP only writes workouts — doc 07)
- Push notifications for Legendary seeds
- Monetization (cosmetic only — doc 08)
- Android

## Non-goals

- Fitness-tracking parity with Strava/Garmin (no training load, no segments-everywhere, no shoes tracking)
- Indoor / treadmill runs (no GPS = no gems; nothing to collect)
- Cycling (pace bounds assume foot travel; walking is allowed at reduced XP — doc 02)

## The two hard problems (addressed up front)

1. **GPS spoofing.** People will fake runs to farm gems. Client-side checks are advisory UX only; the server re-validates every track and is authoritative. Full design in docs 04 and 06.
2. **Cold start.** An empty map is a dead app. One launch city is seeded with curated routes and system-placed gems before public launch. Full design in doc 02.
