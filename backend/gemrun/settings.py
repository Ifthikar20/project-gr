"""GemRun API settings — dev defaults, production values come from the
environment. The defaults keep local dev/CI zero-config; a production boot
(GEMRUN_DEBUG=0) refuses to start until the real secret + a secure auth mode
are supplied (see the boot guard at the bottom)."""
import os
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent

# The dev SECRET_KEY is a KNOWN sentinel: the boot guard rejects it whenever
# DEBUG is off, so it can never silently ship to production.
_DEV_SECRET_KEY = "dev-only-not-a-secret"
SECRET_KEY = os.environ.get("GEMRUN_SECRET_KEY", _DEV_SECRET_KEY)
# DEBUG defaults on for dev; production sets GEMRUN_DEBUG=0.
DEBUG = os.environ.get("GEMRUN_DEBUG", "1") == "1"
# Comma-separated hosts; "*" only survives the boot guard while DEBUG is on.
ALLOWED_HOSTS = [h.strip() for h in
                 os.environ.get("GEMRUN_ALLOWED_HOSTS", "*").split(",") if h.strip()]

# Authentication posture (replaces the old ALLOW_ALL_ACCOUNTS bool):
#   "strict"       — apple/google sign-ins require a verified identity token;
#                    guests authenticate with a high-entropy client secret;
#                    no shared dev-fallback profile. The production mode.
#   "insecure_dev" — trust any client-claimed id and fall back to one shared
#                    profile for unauthenticated calls. Local dev / the iOS
#                    mock only; the boot guard forbids it when DEBUG is off.
AUTH_MODE = os.environ.get("GEMRUN_AUTH_MODE", "insecure_dev" if DEBUG else "strict")
# Test/observability seam for identity-token verification. When set (tests do
# this via override_settings), api.identity.verify_identity_token delegates to
# it instead of the real JWKS path — so the strict-mode auth flow is testable
# without live Apple/Google keys or the cryptography backend.
IDENTITY_VERIFIER = None

# ---- Rate limiting (api/throttle.py) -------------------------------------
# Fixed-window throttles on the abuse-prone endpoints. Backed by the cache
# below — LocMemCache is per-process, fine for dev/CI and single-worker; a
# multi-worker production deploy MUST point CACHES at a shared store (Redis/
# memcached) or each worker keeps its own counter.
THROTTLE_ENABLED = os.environ.get("GEMRUN_THROTTLE", "1") == "1"
# scope -> (max_requests, window_seconds), keyed by client IP.
RATE_LIMITS = {
    "auth": (10, 60),        # account minting / sign-in
    "reward": (40, 60),      # run completion + drop collection
    "enumerate": (30, 60),   # handle + player search
}
# LocMemCache is per-process — fine for dev/CI and a single worker, but each
# gunicorn worker would then keep its own throttle counter (effective limit
# = workers × RATE_LIMITS). Set GEMRUN_REDIS_URL in production so all workers
# and boxes share one counter (and one cache).
if os.environ.get("GEMRUN_REDIS_URL"):
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.redis.RedisCache",
            "LOCATION": os.environ["GEMRUN_REDIS_URL"],
        }
    }
else:
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "gemrun-throttle",
        }
    }

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.auth",
    "api",
]

MIDDLEWARE = [
    # Routes payloads carry polylines + elevation profiles — the chunkiest
    # JSON we serve; gzip cuts them to a fraction on the wire.
    "django.middleware.gzip.GZipMiddleware",
    # Order matters: RequestLog assigns the request id on the way in and
    # logs the FINAL status on the way out; ProblemJSONError (below it)
    # turns unhandled exceptions and Django's HTML 404/405s into the
    # problem+json shape the iOS client decodes (api/middleware.py).
    "api.middleware.RequestLogMiddleware",
    "api.middleware.ProblemJSONErrorMiddleware",
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "gemrun.urls"
WSGI_APPLICATION = "gemrun.wsgi.application"

# Database: SQLite by default (zero-config dev/CI); Postgres when the
# GEMRUN_DB_* env vars are set — the required swap before real traffic
# (SQLite's single writer is the throughput ceiling; docs/16). The app is
# backend-agnostic: the gem-cap guard's correctness comes from the read-time
# `enforce_hard_max` trim, not the storage engine — SQLite serializes writes
# globally via BEGIN IMMEDIATE, Postgres uses a per-mile advisory lock
# (api/system_drops._guarded_create) to serialize only same-mile stocking.
if os.environ.get("GEMRUN_DB_HOST"):
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": os.environ.get("GEMRUN_DB_NAME", "gemrun"),
            "USER": os.environ.get("GEMRUN_DB_USER", "gemrun"),
            "PASSWORD": os.environ.get("GEMRUN_DB_PASSWORD", ""),
            "HOST": os.environ["GEMRUN_DB_HOST"],
            "PORT": os.environ.get("GEMRUN_DB_PORT", "5432"),
            # Persistent connections: reuse a pooled connection across
            # requests instead of reconnecting each time (essential under
            # gunicorn — a fresh TCP+auth per request would dominate latency).
            "CONN_MAX_AGE": int(os.environ.get("GEMRUN_DB_CONN_MAX_AGE", "60")),
            "CONN_HEALTH_CHECKS": True,
        }
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": BASE_DIR / "db.sqlite3",
            # BEGIN IMMEDIATE: transaction.atomic() takes SQLite's single
            # write lock at block entry, so the gem-cap guard's COUNT→INSERT
            # can never interleave with another writer (thread or process).
            # 10 s busy timeout queues concurrent writers instead of erroring.
            "OPTIONS": {"transaction_mode": "IMMEDIATE", "timeout": 10},
        }
    }

# Read-replica seam (tier 12k+). Set GEMRUN_DB_REPLICA_HOST to route the heavy
# read-only queries — leaderboards, search, run history — to a Postgres read
# replica via `.using(settings.READ_DB)`. With no replica configured READ_DB is
# "default", so it's a no-op; writes and read-after-write paths (auth, run
# settlement, gem claims) always stay on "default". Flipping this on is a
# config change, not a code change.
READ_DB = "default"
if os.environ.get("GEMRUN_DB_REPLICA_HOST") and os.environ.get("GEMRUN_DB_HOST"):
    DATABASES["replica"] = {
        **DATABASES["default"],
        "HOST": os.environ["GEMRUN_DB_REPLICA_HOST"],
        "PORT": os.environ.get("GEMRUN_DB_REPLICA_PORT",
                               DATABASES["default"].get("PORT", "5432")),
        # The test runner treats the replica as a mirror of default rather
        # than building a second test DB.
        "TEST": {"MIRROR": "default"},
    }
    READ_DB = "replica"

# Background gem-stocking backend (tier 12k+). "thread" (default) runs restock
# in the in-process pool; "celery" enqueues it to a shared Celery queue so
# multiple app boxes don't each duplicate the Overpass fetch + placement.
# The switch is config-only (see api/tasks.py, gemrun/celery_app.py).
STOCKING_BACKEND = os.environ.get("GEMRUN_STOCKING_BACKEND", "thread")
CELERY_BROKER_URL = os.environ.get("GEMRUN_CELERY_BROKER", "")

TIME_ZONE = "UTC"
USE_TZ = True

# Walkability downstream call (api/walkability.py, docs/13).
#   "overpass" — query OpenStreetMap's Overpass API for walkable ways.
#                System drops FAIL CLOSED in this mode (require True);
#                user drops fail open (only a definite False rejects).
#   "off"      — no external call; is_walkable() returns None (callers trust
#                route polylines, which are snapped to walking directions).
# Env-overridable so offline dev/CI can flip it without a code change.
WALKABILITY_MODE = os.environ.get("WALKABILITY_MODE", "overpass")
# Where the walkable-geometry for gem placement comes from (tier 12k+):
#   "overpass" (default) — the public Overpass API (rate-limits a shared IP).
#   "postgis"            — a locally imported OSM extract queried in PostGIS
#                          (no external dependency; see api/walkability_pg.py).
# Switching is config-only once the extract is imported.
WALKABILITY_SOURCE = os.environ.get("GEMRUN_WALKABILITY_SOURCE", "overpass")
# Tried in order until one answers — the main instance rate-limits hard.
OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
WALKABILITY_RADIUS_M = 25      # matches the gem collection radius
WALKABILITY_TIMEOUT_S = 5

# Presence-triggered system drops (api/system_drops.py, docs/13): each
# GET /v1/drops map query tops up gems around ITS OWN coordinates — user
# activity is the capture point, so regions nobody uses never get gems.
PRESENCE_DROPS = True
# The per-mile contract (docs/14 §2.1): all counts are RADIAL within
# PRESENCE_RADIUS_M of the map-open point. Below FLOOR → restock up to
# FILL_TARGET; HARD_MAX is never exceeded counting everyone's system gems
# (enforced per-insert inside a write-serialized transaction). The band
# between FLOOR and HARD_MAX is shared-world tolerance: someone else's
# gems count as stock, so overlapping users throttle each other.
PRESENCE_RADIUS_M = 1609         # "my mile"
PRESENCE_FLOOR = 20              # below this at map open → restock
PRESENCE_FILL_TARGET = 35        # restock stops here
PRESENCE_HARD_MAX = 50           # never exceeded, counting everyone's gems
# Cold-inline bootstrap deadline: the first-ever map open of an area pays
# for placement inline (the app shows its loading cover); this bounds that
# wait. Placement stops mid-pass when it expires — later opens retry.
PRESENCE_INLINE_BUDGET_S = 12
# Tier-1 candidates (points on route polylines) must snap onto a strict
# pedestrian way within this distance or be rejected — routes legally run
# along road centerlines, but gems must sit ON sidewalks/trails.
PLACEMENT_SNAP_MAX_M = 25
# Warm areas run rotation/top-up in a background thread so the map read
# answers instantly. False = inline (tests: in-memory SQLite is per-thread).
PRESENCE_ASYNC = True
# Empty-area bootstrap: when a map opens somewhere with zero system gems and
# no qualifying routes, the system still stocks the area — gems sampled on
# nearby OSM walkable ways only. No scatter fallback: with no trusted
# geometry the area stays empty (empty beats misplaced).
PRESENCE_BOOTSTRAP = True
# A route needs this many runs to count as popular. Env-overridable so local
# dev can set 0 (run.sh does) and see gems on any published route immediately.
PRESENCE_DROP_MIN_RUNS = int(os.environ.get("PRESENCE_DROP_MIN_RUNS", 3))
# DEV ONLY — never in production. When a stocking pass still has unfilled
# slots (Overpass rate-limiting this machine, offline dev), scatter the
# remainder at random points within the mile WITHOUT walkability
# verification (spacing + the per-mile caps still apply). This is the one
# deliberate breach of the fail-closed placement rule, so it hides behind
# an env flag that defaults off:  PRESENCE_DEV_SCATTER=1 ./run.sh
PRESENCE_DEV_SCATTER = os.environ.get("PRESENCE_DEV_SCATTER", "") == "1"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# Verbose app logging: every Overpass attempt (with the exact failure —
# SSL, timeout, rate limit), every gem spawn, every bootstrap decision,
# one line per request, and a traceback for every unhandled exception
# (api/middleware.py). Shows in the console / backend/.server.log.
# GEMRUN_LOG_LEVEL=DEBUG|WARNING to adjust.
_LOG_LEVEL = os.environ.get("GEMRUN_LOG_LEVEL", "INFO").upper()
if _LOG_LEVEL not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
    # A typo here used to crash dictConfig at boot; fall back loudly instead.
    import sys
    sys.stderr.write(f"GEMRUN_LOG_LEVEL={_LOG_LEVEL!r} is not a log level; "
                     "using INFO\n")
    _LOG_LEVEL = "INFO"
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "gemrun": {"format": "[{asctime}] {levelname} {name}: {message}",
                   "style": "{"},
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler", "formatter": "gemrun"},
    },
    "loggers": {
        # Children (api.views, api.request, api.system_drops, …) propagate
        # here — one handler, one format, one level knob.
        "api": {"handlers": ["console"], "level": _LOG_LEVEL},
        # Belt-and-braces for errors raised outside api.middleware's reach:
        # without this, DEBUG=False sends 500 tracebacks nowhere at all
        # (Django's default console handler is DEBUG-only and mail_admins
        # is unconfigured).
        "django.request": {"handlers": ["console"], "level": "ERROR"},
    },
}

# ---- Production boot guard ------------------------------------------------
# A production process (DEBUG off) must not run with the dev secret, a
# wildcard host, or the insecure auth mode. Failing loudly at import beats
# discovering it from a breach. Dev/CI (DEBUG on) is unaffected, and the test
# runner (which forces DEBUG off) is exempt so `manage.py test` still boots.
import sys as _sys
_RUNNING_TESTS = "test" in _sys.argv
if not DEBUG and not _RUNNING_TESTS:
    if SECRET_KEY == _DEV_SECRET_KEY:
        raise ImproperlyConfigured(
            "GEMRUN_SECRET_KEY must be set to a real secret when DEBUG is off.")
    if "*" in ALLOWED_HOSTS:
        raise ImproperlyConfigured(
            "GEMRUN_ALLOWED_HOSTS must list real hostnames when DEBUG is off.")
    if AUTH_MODE != "strict":
        raise ImproperlyConfigured(
            "GEMRUN_AUTH_MODE must be 'strict' when DEBUG is off "
            f"(got {AUTH_MODE!r}).")
