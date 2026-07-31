"""Request logging + problem+json error handling for the /v1 API.

Two guarantees the iOS client relies on (docs/06, docs/17):

1. Every response a /v1 caller sees is JSON — including 500s, 404s and
   405s, which Django otherwise renders as text/html. The client decodes
   problem+json into HTTPError; an HTML body degrades to a bare
   "HTTP 500" with no `code` for the UI to branch on.
2. Every request leaves exactly one log line, and every unhandled
   exception leaves a full traceback tagged with the same short request
   id the client received in the X-Request-ID header — so "what broke"
   is greppable from either side of the wire.
"""
import logging
import secrets
import time

from django.http import JsonResponse

log = logging.getLogger("api.request")


def _problem(status, title, code, detail=None):
    # Mirrors views.problem() — duplicated so the middleware stays free of
    # view imports (and importable before the app registry is ready).
    return JsonResponse({"title": title, "detail": detail, "code": code},
                        status=status, content_type="application/problem+json")


class RequestLogMiddleware:
    """One INFO line per request and an X-Request-ID on every response.

    Sits ABOVE ProblemJSONErrorMiddleware so the id exists before any
    error handling runs, and the logged status is the one that actually
    went out (including converted 500s).
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        request.request_id = secrets.token_hex(4)
        started = time.monotonic()
        response = self.get_response(request)
        elapsed_ms = int((time.monotonic() - started) * 1000)
        response["X-Request-ID"] = request.request_id
        log.info("[%s] %s %s -> %d in %d ms", request.request_id,
                 request.method, request.path, response.status_code,
                 elapsed_ms)
        return response


class ProblemJSONErrorMiddleware:
    """Keeps the error contract honest when things break.

    - process_exception: an unhandled exception in any view becomes a
      logged traceback + a problem+json 500 carrying the request id, in
      DEBUG and production alike. (Without this, DEBUG=False turns every
      500 into an unlogged text/html "Server Error".)
    - response pass: Django's own text/html 404 (unknown path) and 405
      (@require_http_methods) under /v1/ are rewritten to problem+json.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if (request.path.startswith("/v1/")
                and response.status_code in (404, 405)
                and response.get("Content-Type", "").startswith("text/html")):
            if response.status_code == 404:
                converted = _problem(404, "Not found", code="not_found")
            else:
                converted = _problem(405, "Method not allowed",
                                     code="method_not_allowed")
                if response.has_header("Allow"):
                    converted["Allow"] = response["Allow"]
            return converted
        return response

    def process_exception(self, request, exception):
        request_id = getattr(request, "request_id", "no-id")
        log.exception("[%s] unhandled error in %s %s", request_id,
                      request.method, request.path)
        return _problem(500, "Internal error", code="internal",
                        detail=f"request {request_id}")
