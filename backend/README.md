# GemRun API (Django)

The Python/Django backend implementing the 14 `/v1` endpoints from
[doc 11](../docs/11-dummy-api.md), wire-compatible with the iOS
`HTTPGemRunAPI` client (snake_case JSON, ISO-8601, encoded polylines).

## Run it

```sh
cd backend
pip install -r requirements.txt
python manage.py migrate
# optional demo data (street-following, from OSM ways; --clear removes it):
# python manage.py seed --lat 37.7749 --lng -122.4194
python manage.py drop_gems                             # optional global backstop (docs/13)
python manage.py runserver 0.0.0.0:8000
python manage.py test                                  # 28 tests
```

## Point the iOS app at it

Nothing to hardcode — `AppConfig.apiBaseURL` resolves at launch:

1. `GEMRUN_API_URL` env var (`./run.sh` passes the local server automatically;
   `"mock"` forces the in-app mock)
2. `GemRunAPIBaseURL` Info.plist key
3. Simulator debug builds default to `http://127.0.0.1:8000`

A physical device needs your Mac's LAN IP via 1 or 2.
`NSAllowsLocalNetworking` is already set in project.yml for dev-time HTTP.

## What's implemented

- **Auth** — `POST /v1/auth/apple|google`, `GET/PATCH/DELETE /v1/users/me`.
  `ALLOW_ALL_ACCOUNTS = True` in `gemrun/settings.py` mirrors the iOS
  `AuthFlags.allowAllAccounts` dev flag: every sign-in succeeds, no identity
  token verified. Flip both together to go strict.
- **Routes** — geo-query (bounding box), detail with **server-side fuzzing**
  of uncollected Rare+ drops (deterministic jitter so the circle's center
  doesn't leak the spot), publish with full docs/02 budget re-validation,
  archive.
- **Runs** — `POST /v1/runs` (exact drops for offline collection) and the
  authoritative `POST /v1/runs/{route_id}/complete`: idempotent by key,
  **replays the full GPS track** through the ported GameKitCore pipeline
  (`geometry.py`, `validation.py`, `rules.py` — same constants), enforces
  respawn dedupe, awards/revokes, computes XP with walk + streak multipliers,
  owns streak state server-side, returns leaderboard rank.
- **Stash / leaderboards / catalog** — per-route best times, weekly XP board,
  gem catalog with UUIDs identical to the client's `GemCatalog`.

## Not yet (deliberate)

Real Apple/Google token verification, App Attest, PostGIS-grade geo queries
(bounding box is fine at this scale), rate limiting, production settings
(DEBUG off, secret key, ALLOWED_HOSTS), set-completion bonus server-side
(client-local for now to avoid double-award).
