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

- **Auth** — `POST /v1/auth/apple|google|guest`, `GET/PATCH/DELETE /v1/users/me`.
  `AUTH_MODE` (`gemrun/settings.py`, env `GEMRUN_AUTH_MODE`) is `strict` in
  production: apple/google sign-ins are verified against the provider identity
  token (`api/identity.py`; the account subject comes from the *verified*
  token, not a client-claimed id), and guests authenticate with a
  high-entropy per-install secret. `insecure_dev` (the default while
  `DEBUG` is on) keeps the old permissive local/mock behavior — the boot
  guard forbids it when `DEBUG` is off.
- **Rate limiting** — fixed-window throttles (`api/throttle.py`) on the
  abuse-prone endpoints: sign-in/account minting, run + drop settlement, and
  username enumeration. Backed by the cache (`RATE_LIMITS` in settings); point
  `CACHES` at Redis for multi-worker prod.
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

App Attest / DeviceCheck (no genuine-build attestation yet), PostGIS-grade
geo queries (bounding box is fine at this scale), server-side token
expiry/rotation, set-completion bonus server-side (client-local for now to
avoid double-award). Production settings are env-driven now
(`GEMRUN_SECRET_KEY`, `GEMRUN_DEBUG=0`, `GEMRUN_ALLOWED_HOSTS`,
`GEMRUN_AUTH_MODE=strict`) with a boot guard that refuses to start insecure;
the real Apple/Google JWKS verification ships behind `PyJWT[crypto]` (the
tests use the `IDENTITY_VERIFIER` seam).
