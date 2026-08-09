"""Fixed-window rate limiting for the abuse-prone endpoints (auth/account
minting, reward settlement, username enumeration).

`@throttle("auth")` reads its (limit, window_seconds) from
`settings.RATE_LIMITS[scope]` and counts per client IP in the cache. The
window resets when the cache entry expires — no wall clock needed, so it is
resume/replay safe. LocMemCache is per-process; a multi-worker production
deploy must point CACHES at a shared store or each worker counts separately.

Kept import-free of views to avoid a cycle (views imports this); the 429 body
mirrors views.problem()/middleware._problem().
"""
import functools

from django.conf import settings
from django.core.cache import cache
from django.http import JsonResponse


def _too_many(retry_after):
    resp = JsonResponse(
        {"title": "Too many requests", "detail": "Slow down and try again.",
         "code": "rate_limited"},
        status=429, content_type="application/problem+json")
    resp["Retry-After"] = str(retry_after)
    return resp


def _client_ip(request):
    # REMOTE_ADDR is the direct peer. Behind a trusted proxy you'd parse
    # X-Forwarded-For instead — deliberately not trusted here (spoofable).
    return request.META.get("REMOTE_ADDR", "unknown")


def throttle(scope):
    """Decorator: cap requests to the decorated view at
    settings.RATE_LIMITS[scope] per client IP. No-op when THROTTLE_ENABLED
    is off (tests default it off; one test flips it on)."""
    def decorator(view):
        @functools.wraps(view)
        def wrapped(request, *args, **kwargs):
            if not getattr(settings, "THROTTLE_ENABLED", False):
                return view(request, *args, **kwargs)
            limit, window = settings.RATE_LIMITS[scope]
            key = f"throttle:{scope}:{_client_ip(request)}"
            # First hit in a window creates the counter with the window TTL;
            # later hits increment it. If it expired between add and incr,
            # incr raises and we re-seed — treating this hit as the new first.
            if cache.add(key, 1, window):
                count = 1
            else:
                try:
                    count = cache.incr(key)
                except ValueError:
                    cache.add(key, 1, window)
                    count = 1
            if count > limit:
                return _too_many(window)
            return view(request, *args, **kwargs)
        return wrapped
    return decorator
