"""Gunicorn config for the GemRun API (production WSGI server).

Run it with:  gunicorn -c gunicorn.conf.py gemrun.wsgi:application
(dev/CI keep using `manage.py runserver`; this file is for real traffic.)

Worker sizing — the answer to "how many workers?":

  workers = GUNICORN_WORKERS  (if set)  else  (2 × CPU cores) + 1

That is gunicorn's standard formula. A worker is a full OS process with its
own Python interpreter and its own pooled DB connection, so N workers = N
requests served truly in parallel per box. `(2×cores)+1` keeps every core
busy while one worker waits on I/O (a DB round-trip, or the inline Overpass
fetch on a cold map-open). Scale OUT by adding boxes behind the load
balancer, not by piling workers past ~2–3× cores on one box (they'd just
contend for the same cores and RAM).

Threads: gthread workers each run `threads` request handlers, so a worker
blocked on the ≤12 s cold-bootstrap Overpass call (PRESENCE_INLINE_BUDGET_S)
still serves other requests on its remaining threads. Effective in-flight
capacity per box ≈ workers × threads.
"""
import multiprocessing
import os

# Where to listen. Behind a load balancer / reverse proxy in production.
bind = os.environ.get("GUNICORN_BIND", "0.0.0.0:8000")

_cores = multiprocessing.cpu_count()
workers = int(os.environ.get("GUNICORN_WORKERS", (2 * _cores) + 1))

# Threaded workers: headroom for the occasional inline Overpass wait so a
# cold map-open never blocks a whole worker.
worker_class = os.environ.get("GUNICORN_WORKER_CLASS", "gthread")
threads = int(os.environ.get("GUNICORN_THREADS", 4))

# 30 s > the 12 s inline stocking budget + margin; a request that exceeds it
# is genuinely stuck and the worker is recycled.
timeout = int(os.environ.get("GUNICORN_TIMEOUT", 30))
graceful_timeout = 30
keepalive = 5

# Recycle workers periodically so a slow leak can't accumulate; jitter avoids
# all workers restarting at once.
max_requests = int(os.environ.get("GUNICORN_MAX_REQUESTS", 1000))
max_requests_jitter = 100

# NOT preloading the app: each worker forks its own copy AFTER boot, so the
# in-process gem-stocking ThreadPoolExecutor and the persistent DB connections
# (CONN_MAX_AGE) are created per-worker rather than shared across a fork.
preload_app = False

# Access log to stdout (the platform/log shipper captures it); the app's own
# request logger already emits one structured line per request.
accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")
