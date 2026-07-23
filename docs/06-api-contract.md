# 06 — API Contract (Lightweight)

> **Scope note:** this is *just enough contract to ground the iOS client* — not a backend spec. The backend will be Python (FastAPI assumed); its internals, infra, and full schemas are out of scope for this planning set. Shapes below are sketches, not exhaustive.

## Conventions

- Base path `/v1`, JSON bodies, ISO 8601 timestamps, encoded polylines (Google format).
- Auth: `Authorization: Bearer <JWT>` obtained from the Apple sign-in exchange. Anonymous access only where noted.
- Run completion is idempotent via client-generated `idempotency_key`.
- Errors: RFC 7807 problem+json (`type`, `title`, `detail`, plus machine-readable `code`).

## Endpoints

### Auth & user

```
POST /v1/auth/apple                      (anonymous)
  → { apple_identity_token }
  ← { jwt, refresh_token, user: {...} }   # creates user on first sign-in

GET  /v1/users/me                        ← full own-user (doc 05 User fields)
PATCH /v1/users/me                       → { handle?, avatar_url?, home_geohash?, timezone? }
DELETE /v1/users/me                      # account deletion (App Store requirement)
```

### Routes

```
GET /v1/routes?lat=&lng=&radius_m=       (anonymous OK)
  ← { routes: [RouteSummary] }           # geo-query by geohash; summary DTO:
                                         # id, name, distance_m, elevation_gain_m,
                                         # difficulty, gem_counts_by_rarity, top_time_s,
                                         # creator_handle, polyline

GET /v1/routes/{id}                      (anonymous OK)
  ← RouteDetail                          # + gem_drops. **Rare/Epic/Legendary drops the
                                         # caller hasn't collected return a fuzzed
                                         # zone (center ±, radius_m: 150) instead of
                                         # exact lat/lng** — the hunt is preserved
                                         # server-side, not by client politeness.
                                         # Exact coords for those gems are included in
                                         # the run-scoped payload below.

POST /v1/routes
  → { name, description?, polyline, gem_drops: [{gem_id, lat, lng, position_along_route_m}] }
  ← RouteDetail (status: published)
  # Server re-validates EVERYTHING client-side rules claimed: snap sanity, slot count,
  # rarity-point budget, 100 m spacing, Rare ≥40% rule, Epic hard-segment rule
  # (against server-computed elevation), no Legendary. 422 with per-gem errors on failure.

PATCH  /v1/routes/{id}                   # name/description only in MVP
DELETE /v1/routes/{id}                   # archive (soft)
```

### Runs — the critical pair

```
POST /v1/runs
  → { route_id }
  ← { run_id, gem_drops_exact: [...] }   # start intent; returns EXACT coords for all
                                         # active drops on this route (incl. fuzzed ones)
                                         # so offline collection detection works.
                                         # Short-lived server-side run session.

POST /v1/runs/{run_id}/complete          (idempotent)
  → {
      idempotency_key,
      started_at, ended_at,
      track: [[t, lat, lng, accuracy, speed], ...],
      claimed_collections: [gem_drop_id, ...],
      client_flags: [...],               # advisory (doc 04)
      app_attest: { key_id, assertion }  # binds payload hash to legit device
    }
  ← {
      validation_status: "valid" | "flagged" | "invalid",
      awarded: [ { gem_drop_id, stash_item_id, xp } ],   # may be ⊂ claimed
      revoked:  [ gem_drop_id ],                          # claimed but not awarded
      xp_earned, streak: { count, shields, multiplier },
      leaderboard: { route_rank?, best_time_s? } | null   # null for walks
    }
```

**The key contract decision:** the client shows optimistic collection during the run; **this response is the source of truth and may revoke.** Server re-runs the doc 04 pipeline on the full track (adherence, monotonic progress per gem, pace bounds, teleport detection, App Attest verification) and computes all XP/streak/leaderboard effects itself. `flagged` = shadow-excluded from boards pending review; stash items still granted unless `invalid`.

### Stash, boards, catalog

```
GET /v1/stash                            ← { items: [StashItem+Gem], sets: [progress] }
GET /v1/routes/{id}/leaderboard?window=all|month
                                         ← { entries: [...], me: {...}? }
GET /v1/leaderboards/local?geohash=      ← weekly gem-score board (doc 02)
GET /v1/gems/catalog                     (anonymous OK, cacheable)
                                         ← gems + sets incl. seasonal windows
```

## Client integration notes (doc 07 consumers)

- `CoreNetworking` maps DTOs ↔ `CoreModels`; all endpoints have offline-tolerant call sites except the run pair, which uses the sync queue (docs 04/07).
- `POST /runs` failing offline does **not** block a run: the client falls back to cached drop coordinates from the route-detail fetch and submits everything at completion; the server accepts a completion without a prior start intent (creates the run session retroactively). Fuzzed-gem exactness may be reduced offline — acceptable edge.
- Rate-limit and auth-refresh behavior standard; 401 → silent refresh → re-auth flow.
