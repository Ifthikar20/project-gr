# 20 — Scaling Runbook

Growing GemRun from a private beta to 50,000 users is a series of **config
changes**, not code changes. The seams are already built into the backend;
this doc says which env vars to set (see `backend/.env.example`) and which
services to stand up at each tier. Capacity math is in the capacity artifact;
this is the operator's checklist.

The golden rule: **workers = (2 × CPU cores) + 1 per box; scale out by adding
boxes behind a load balancer.** The shared bottlenecks — the Postgres primary,
gem-population's map data, and rate-limit state — are what each tier below
addresses.

---

## Tier 0 — local dev / CI  (what runs today)

SQLite + `manage.py runserver`, zero config. `AUTH_MODE` defaults to
`insecure_dev`, throttling on, mock-friendly. Nothing to set.

## Tier 1 — ~50 users (private beta / first deploy)

The only real gap is that nothing is deployed yet. Stand up **one small box**
and run the real server:

```sh
cp .env.example .env                     # set GEMRUN_SECRET_KEY, hosts
gunicorn -c gunicorn.conf.py gemrun.wsgi:application
```

- `GEMRUN_DEBUG=0`, `GEMRUN_SECRET_KEY=…`, `GEMRUN_ALLOWED_HOSTS=…`,
  `GEMRUN_AUTH_MODE=strict` (the boot guard enforces these).
- SQLite is genuinely fine at this size; Postgres optional for parity.

## Tier 2 — ~500 users (open beta)

SQLite's single writer starts queuing at evening peak. Switch to Postgres and
add Redis — **both are just env vars**:

```env
GEMRUN_DB_HOST=…  GEMRUN_DB_NAME=…  GEMRUN_DB_USER=…  GEMRUN_DB_PASSWORD=…
GEMRUN_REDIS_URL=redis://…:6379/0
```

- Postgres selected automatically when `GEMRUN_DB_HOST` is set.
- Redis makes the rate-limit counter shared across gunicorn workers.
- Redis also backs the **read-through cache** (on by default): the static gem
  catalog (1 h), the map-read drop list (~5 s), and the advisory mile-count
  (~5 s) are served from cache, offloading the hottest reads from the DB. The
  cap-guard's own count is never cached. Tunable via `GEMRUN_CACHE_TTL_*` /
  `GEMRUN_READ_CACHE=0`.
- One 2-vCPU app box (≈5 workers) still carries the load.
- `docker compose up --build` brings up this exact stack locally to validate.

## Tier 3 — ~12,000 users (launched)

Now a fleet. Provision infra, then flip config:

1. **Load balancer + ~3 app boxes.** Each computes its own worker count; set
   `GUNICORN_WORKERS` only to override.
2. **Postgres read replica** — set `GEMRUN_DB_REPLICA_HOST`. Leaderboards,
   search, and run-history reads route to it via `settings.READ_DB`
   automatically; writes and read-after-write paths stay on the primary. No
   code change.
3. **Self-hosted OSM in PostGIS** — the make-or-break piece for gem
   population (public Overpass dies at this egress volume). Import an extract
   (`api/walkability_pg.py` documents the one-time `osm2pgsql` step), wire the
   two queries in that module, then set `GEMRUN_WALKABILITY_SOURCE=postgis`.
4. **Celery stocking** — set `GEMRUN_STOCKING_BACKEND=celery` +
   `GEMRUN_CELERY_BROKER=redis://…/1` on the web boxes, and run workers:
   `celery -A gemrun.celery_app worker -l info`. Background restock moves off
   the in-process pool so boxes stop duplicating Overpass/placement work.

## Tier 4 — ~50,000 users (scaling)

Horizontal everything:

- **Autoscale the app fleet** (≈8 boxes at peak) behind the load balancer.
- **PgBouncer** in front of Postgres — ~72 workers would otherwise exhaust
  Postgres's connection limit; the pooler multiplexes them. (App points at
  PgBouncer's host/port via the same `GEMRUN_DB_HOST`.)
- **Postgres replica cluster** (`GEMRUN_DB_REPLICA_HOST` → the replica LB) and
  **clustered Redis**.
- **Gem-table partitioning** — daily rotation accumulates inactive rows;
  partition `GemDrop` by `created_at` and archive old partitions. *(This one
  is a migration, the only non-config item at this tier.)*
- Rate-limit at the edge (load balancer / CDN) in addition to the app.

---

## What's a config flip vs. still code

| Lever | Mechanism | Config-only? |
|---|---|---|
| SQLite → Postgres | `GEMRUN_DB_HOST` | ✅ |
| Shared rate-limit / cache | `GEMRUN_REDIS_URL` | ✅ |
| Worker count | `GUNICORN_WORKERS` (default auto) | ✅ |
| Read replica routing | `GEMRUN_DB_REPLICA_HOST` | ✅ |
| Celery stocking | `GEMRUN_STOCKING_BACKEND=celery` + worker | ✅ (run a worker) |
| PostGIS walkability | `GEMRUN_WALKABILITY_SOURCE=postgis` | ⚙️ config + wire one function (`walkability_pg`) after the OSM import |
| Gem-table partitioning | migration | ❌ code (migration) at ~50k |

Everything above the last two rows is a value in `.env`. The gem-cap guarantee
holds on either database (`enforce_hard_max` is the read-time backstop; on
Postgres a per-mile advisory lock reduces contention).
