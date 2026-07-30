"""GemRun API settings — dev defaults; harden before any real deployment."""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = "dev-only-not-a-secret"          # override via env in production
DEBUG = True
ALLOWED_HOSTS = ["*"]

# TEMPORARY — mirrors the iOS AuthFlags.allowAllAccounts dev flag: every
# sign-in succeeds and no Apple/Google identity token is verified.
# Flip to False when token verification lands (docs/06 auth exchange).
ALLOW_ALL_ACCOUNTS = True

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.auth",
    "api",
]

MIDDLEWARE = [
    # Routes payloads carry polylines + elevation profiles — the chunkiest
    # JSON we serve; gzip cuts them to a fraction on the wire.
    "django.middleware.gzip.GZipMiddleware",
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "gemrun.urls"
WSGI_APPLICATION = "gemrun.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
        # BEGIN IMMEDIATE: transaction.atomic() takes SQLite's single write
        # lock at block entry, so the gem-cap guard's COUNT→INSERT can never
        # interleave with another writer (thread or process). 10 s busy
        # timeout queues concurrent writers instead of erroring.
        "OPTIONS": {"transaction_mode": "IMMEDIATE", "timeout": 10},
    }
}

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

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# Verbose app logging: every Overpass attempt (with the exact failure —
# SSL, timeout, rate limit), every gem spawn, every bootstrap decision.
# Shows in the console / backend/.server.log. GEMRUN_LOG_LEVEL=DEBUG|WARNING
# to adjust.
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
        "api": {"handlers": ["console"],
                "level": os.environ.get("GEMRUN_LOG_LEVEL", "INFO")},
    },
}
