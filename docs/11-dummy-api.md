# 11 — Dummy API (and the Django contract)

The UI talks to a single protocol — `GemRunAPI` in `Packages/GemRunCore/Sources/CoreNetworking/GemRunAPI.swift` — with two implementations selected by `API.shared`:

| Implementation | When active | What it is |
|---|---|---|
| `MockGemRunAPI` | `AppConfig.apiBaseURL == nil` — device builds with nothing configured, or `GEMRUN_API_URL=mock` (Simulator debug builds default to the LIVE local Django server) | In-app dummy server: in-memory actor, ~150 ms simulated latency, seeded routes, fake competitors, authoritative run validation, respawn dedupe |
| `HTTPGemRunAPI` | `AppConfig.apiBaseURL` set | URLSession client hitting the same `/v1` paths — this is what the **Python/Django** backend implements later |

**The swap is one line:** set `AppConfig.apiBaseURL` to the Django server's URL. No UI code changes.

Every mock call logs to the Xcode console with its real path, e.g. `🌐 [MockAPI] POST /v1/runs/1A2B3C4D/complete (312 samples, 3 claimed)` — run the app and watch the calls fire.

## All API calls

| # | HTTP (Django implements) | Swift call | Used by | Mock behavior |
|---|---|---|---|---|
| 1 | `POST /v1/auth/apple` | `auth(handle:)` | Onboarding (via `SessionStore.createProfile`) | Returns fake JWT + profile |
| 2 | `GET /v1/users/me` | `me()` | (available; profile is cached locally) | Returns stored profile |
| 3 | `PATCH /v1/users/me` | `updateMe(handle:)` | (available for settings) | Updates handle |
| 4 | `DELETE /v1/users/me` | `deleteAccount()` | (available for settings) | Wipes mock state |
| 5 | `GET /v1/routes?lat&lng&radius_m` | `nearbyRoutes(lat:lng:radiusM:)` | **Explore** on appear | Returns published routes only — NO demo seeding; the map shows just the routes users actually create. (Backend demo data is opt-in via `manage.py seed`, which builds street-following routes from OSM ways.) |
| 6 | `GET /v1/routes/{id}` | `route(id:)` | (available; detail uses cache) | Returns the route or 404-equivalent |
| 7 | `POST /v1/routes` | `publishRoute(_:)` | **Publish step** of route creation | **Re-validates the placement budget server-side** (slots, points, no Legendary); rejects violations |
| 8 | `DELETE /v1/routes/{id}` | `archiveRoute(id:)` | (available; Profile archives locally) | Marks archived |
| 9 | `POST /v1/runs` | `startRun(routeID:)` | (available; run uses cached drops) | Returns run session + exact drop coordinates |
| 10 | `POST /v1/runs/{id}/complete` | `completeRun(routeID:request:)` | **Run finish** (via `SessionStore.recordCompletion`) | The big one — see below |
| 11 | `GET /v1/stash` | `stash()` | (available; Stash reads local cache) | Returns awarded items |
| 12 | `GET /v1/routes/{id}/leaderboard` | `routeLeaderboard(routeID:window:)` | **Compete → Routes** | Fake competitors + your real times, ranked; your row flagged `isMe` |
| 13 | `GET /v1/leaderboards/local?geohash` | `localLeaderboard(geohash:)` | **Compete → This Week** | Fake neighborhood board with your weekly score inserted |
| 14 | `GET /v1/gems/catalog` | `gemCatalog()` | (available; catalog ships in-app) | Returns the gem catalog |

**Wallet & standalone drops (earn-by-running):**

| # | HTTP | Swift call | Used by | Behavior |
|---|---|---|---|---|
| 15 | `POST /v1/wallet/sync` | `syncWallet(totalRunKm:)` | Stash wallet card, drop sheet | Mints gems from lifetime Apple-Health km (1 per 2/5/15/40 km by tier); never double-mints; everyone starts at 0 |
| 16 | `GET /v1/drops?lat&lng&radius_m` | `nearbyDrops(...)` | Explore map | Standalone drops other runners left nearby (mock seeds three) |
| 17 | `POST /v1/drops` | `dropGem(gemID:lat:lng:)` | Explore drop mode | Places a wallet gem anywhere (consumes wallet; no Legendaries) |
| 18 | `POST /v1/drops/collect` | `collectDrops(claimed:track:)` | Free-run finish | Awards drops the track passed within 25 m; one-time (first finder); never your own |

Rows marked "(available…)" are implemented in both clients but not yet consumed by a screen — the UI intentionally prefers its offline-first local cache there; they exist so Django has the complete contract from day one.

## What the mock's `completeRun` does (the authoritative verdict, docs/06)

1. **Idempotency** — same `idempotency_key` returns the same verdict, no double awards.
2. **Replays the full GPS track** through the same `RouteGeometry` + `CollectionEngine` + `RunValidator` the client used — a claimed gem the track doesn't support is **revoked**.
3. **Enforces respawn rules** (docs/02): daily gems dedupe per calendar day, Rare+ dedupe once-per-user. *(This closes the top item on the doc 10 pending list — re-running a route no longer re-awards everything; the Run Summary shows "already collected today didn't count".)*
4. Computes XP (walk multiplier + streak multiplier) and your leaderboard rank among the fake competitors.
5. Returns `{status, awarded_drops, revoked, xp_earned, leaderboard_rank}` — the client persists **only what was awarded**.

If the API call fails entirely, `SessionStore` falls back to on-device validation, so a run is never lost.

## Why there are no bottlenecks

- **UI never blocks on the network.** Explore renders the SwiftData cache instantly; API responses upsert into it. Run recording is 100% on-device; the single API call happens after you stop.
- **Mock latency is 150 ms** (`AppConfig.mockLatencyMs`), async on an actor — nothing ever busy-waits, and no call runs on the main thread.
- **One call per screen event** — no polling, no chatty sequences; leaderboards load per tab/route selection with `.task(id:)` cancellation.

## Django implementation notes (later)

- Implement the 14 paths above under `/v1` with DRF; snake_case JSON, ISO 8601 dates (the Swift client already encodes/decodes that way).
- Port the validation pipeline from `GameKitCore` (`RouteGeometry`, `CollectionEngine`, `RunValidator`) — the constants live in `CollectionRules` and the Swift fixture tests in `GameKitCoreTests` double as server test vectors.
- Replace `clientStreakDays` (mock-only trust) with server-owned streak state.
- Auth: exchange the Sign in with Apple identity token for a JWT (docs/06); the mock's `auth(handle:)` is a stand-in.
