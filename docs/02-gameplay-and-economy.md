# 02 — Gameplay & Economy

The economy is deliberately simple in MVP: **gems → XP → levels + sets + streaks**. No currency, no trading, no crafting. Everything below is concrete enough to build from.

## Gem rarity tiers

| Tier | Name | Color | XP | Placement rule | Respawn |
|---|---|---|---|---|---|
| Common | Quartz | White | 10 | Anywhere on route | Daily, per user |
| Uncommon | Emerald | Green | 25 | Anywhere on route | Daily, per user |
| Rare | Sapphire | Blue | 75 | ≥ 40% into the route | Once per user, per route |
| Epic | Amethyst | Purple | 200 | Requires a hard segment: ≥ 4% avg grade over 200 m, **or** in the final 20% of routes ≥ 8 km | Once per user, per route |
| Legendary | Ember | Gold/Ruby | 500 | **System-seeded only** — creators cannot place | One-time. First finder gets a unique "first find" variant; subsequent finders get the standard gem until the seed expires |

Design intent:
- **Daily respawn on Common/Uncommon** makes every route worth re-running and powers streaks.
- **Once-per-user on Rare/Epic** makes them a reason to run *new* routes, not farm one.
- **Legendary is server-only** to kill self-farming (you can't place a Legendary on your own route and collect it) and to give the app a weekly event lever.

## Creator placement budget

Two constraints, both enforced client-side at placement time and re-validated server-side at publish:

1. **Slots:** 1 gem slot per 250 m of route (a 5 km route → 20 slots max).
2. **Rarity points:** budget = `distance_km × 10`, costs: Common 1 / Uncommon 3 / Rare 10 / Epic 25.

A 5 km route has 50 points: e.g. 2 Epics (50), or 1 Epic + 2 Rares + 5 fives of mixed Commons/Uncommons. A 1 km route (10 points) can hold exactly one Rare — no Epic-stuffing short routes.

Additional placement rules:
- Minimum spacing 100 m between gems (prevents cluster-grazing).
- Gems snap to the route polyline; free placement off-route is not allowed.
- Epic placement validates the hard-segment rule against the route's elevation profile at drop time, with an explanatory rejection if it fails ("This section isn't steep enough for an Epic").

## What collecting earns you

### XP and levels
- XP per gem as in the table, multiplied by the streak multiplier (below).
- Level-up threshold: `100 × current_level` XP (level 1→2 costs 100, 2→3 costs 200, …). Simple, front-loaded, tunable server-side.
- Levels are cosmetic status in MVP (shown on profile and leaderboards). They gate nothing — no pay-to-win surface, no progression wall.

### Gem sets
- Gems belong to themed **sets of 5** (e.g., "Harbor Lights", "Trailblazer", "Founder").
- Completing a set = a profile badge + **500 bonus XP**.
- The Stash displays missing set members as silhouettes — the completionist pull.

## Streaks

- **Definition:** consecutive calendar days (user's local timezone) with at least one *valid* run of ≥ 1 km.
- **Multiplier:** starts 1.0×; +0.1 per 7 consecutive days; capped at 1.5×. Applies to all gem XP.
- **Streak shields:** earn 1 per completed 7-day block; max 2 banked; auto-consumed on a missed day (streak and multiplier hold). No buying shields.
- A minimal ≥ 1 km run always has something to collect thanks to daily-respawn Commons.

## Walking rule

Pace between 10:00 and 20:00 min/km is a **walk**: gems still collect, at **0.5× XP**, and the run posts **no leaderboard time**.

Why: keeps Dev (the collector) fully in the game and makes the app usable as a walking treasure hunt, while Maya's leaderboards stay a running competition. Below 20:00/km sustained, the run is invalid for collection (see doc 04 pace bounds).

## Leaderboards

| Board | Scope | Window | Ranked by |
|---|---|---|---|
| Route best time | Per route | All-time + this month | Fastest *valid, run-pace* completion |
| Local gem score | Geohash region (~city district) | Weekly, resets Monday 00:00 local | XP earned in-region this week |

- Only server-validated runs count (doc 04/06). Flagged runs are shadow-excluded pending review — the runner still sees their time locally with a "pending verification" state, so false positives don't insult legitimate runners publicly.
- Own row always pinned in the UI (doc 03).

## Cold start: the launch-city seeding plan

An empty map is a dead app. Before public launch in the (single) launch city:

1. **Route generation:** extract 50–100 candidate routes from OpenStreetMap popular-path data — park loops, waterfronts, greenways — in 2 km / 5 km / 10 km buckets. **Every algorithmic route gets a manual curation pass** (does it cross a highway? dead-end? feel human?) before activation. OSM data requires ODbL attribution in-app (doc 08).
2. **Gem seeding:** system places gems on seeded routes using the *same* budget rules creators face, weighted so ~70% of seeded gems are Common/Uncommon (daily respawn → repeatable content).
3. **Founder set:** a time-limited 5-gem "Founder" set available only in the first 90 days — urgency + early-adopter identity.
4. **Weekly Legendary:** one Legendary seeded per week somewhere in the city, on a route whose difficulty earns it. This is the recurring local event and, in Phase 2, the notification hook.
5. **Creator handoff:** seeding tapers as user-created routes reach density thresholds per district; seeded routes are never deleted, just no longer refreshed.

## Anti-abuse notes (economy-side)

- Legendary server-only placement (above) removes the highest-value self-farm.
- Rare/Epic once-per-user-per-route caps repeat farming; daily Commons are low-value enough that farming them is just… running, which is the point.
- Creators earn no XP from collections on their own routes' gems by other users in MVP (no incentive to spam routes); creator rewards are run-counts and leaderboard prestige. Revisit in Phase 2 with moderation in place.
- All XP awards are computed server-side from validated runs (docs 04, 06).
