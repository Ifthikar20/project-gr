"""GemRun API settings — dev defaults; harden before any real deployment."""
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
#   "off"      — no external call; is_walkable() returns None (callers trust
#                route polylines, which are snapped to walking directions).
#   "overpass" — query OpenStreetMap's Overpass API for walkable ways.
WALKABILITY_MODE = "off"
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
WALKABILITY_RADIUS_M = 25      # matches the gem collection radius
WALKABILITY_TIMEOUT_S = 5

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
