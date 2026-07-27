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
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "gemrun.urls"
WSGI_APPLICATION = "gemrun.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
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
PRESENCE_DROP_MAX_PER_AREA = 3   # active system drops per queried area, capped
# Empty-area bootstrap: when a map opens somewhere with zero system gems and
# no qualifying routes, the system still stocks the area — gems on nearby OSM
# walkable ways, falling back to a short-walk scatter around the user.
PRESENCE_BOOTSTRAP = True
# A route needs this many runs to count as popular. Env-overridable so local
# dev can set 0 (run.sh does) and see gems on any published route immediately.
PRESENCE_DROP_MIN_RUNS = int(os.environ.get("PRESENCE_DROP_MIN_RUNS", 3))

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
