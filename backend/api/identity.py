"""Provider identity-token verification for strict-mode sign-in (docs/06,
docs/18).

The security boundary: an Apple/Google sign-in is trusted ONLY after the
provider's signed identity token is verified here, and the account subject is
taken from the *verified* token — never from a client-supplied
`external_user_id`. Without this, knowing someone's provider id is enough to
take over their account (the old ALLOW_ALL_ACCOUNTS hole).

Two paths:
  * `settings.IDENTITY_VERIFIER` set  -> delegate to it. Tests inject a
    deterministic verifier so the strict flow is testable without live keys
    or the cryptography backend; a real deployment could also point this at a
    shared verification service.
  * otherwise                         -> verify the JWT against the provider's
    JWKS (PyJWT + cryptography). Imported lazily so this module loads even
    where those wheels aren't installed (the seam covers dev/CI).
"""
import logging

from django.conf import settings

log = logging.getLogger("api.views")

# iss / JWKS / expected-audience env var, per provider. `aud` is the app's
# client id (Apple: the bundle id; Google: the OAuth client id) and MUST be
# configured in production so a token minted for another app is rejected.
_PROVIDERS = {
    "apple": {
        "issuers": {"https://appleid.apple.com"},
        "jwks_url": "https://appleid.apple.com/auth/keys",
        "audience_env": "GEMRUN_APPLE_AUDIENCE",
    },
    "google": {
        "issuers": {"https://accounts.google.com", "accounts.google.com"},
        "jwks_url": "https://www.googleapis.com/oauth2/v3/certs",
        "audience_env": "GEMRUN_GOOGLE_AUDIENCE",
    },
}


class IdentityError(Exception):
    """Token missing, malformed, or failed verification."""


def verify_identity_token(provider, token):
    """Return the verified provider subject (the stable user id) for `token`,
    or raise IdentityError if it is missing/invalid. `provider` is
    'apple' or 'google'."""
    if provider not in _PROVIDERS:
        raise IdentityError(f"unsupported provider {provider!r}")
    if not token or not isinstance(token, str):
        raise IdentityError("identity_token is required")

    hook = getattr(settings, "IDENTITY_VERIFIER", None)
    if hook is not None:
        subject = hook(provider, token)
        if not subject:
            raise IdentityError("identity token rejected")
        return subject

    return _verify_jwt(provider, token)


def _verify_jwt(provider, token):
    """Real path: verify the JWT signature against the provider JWKS and check
    issuer/audience/expiry. Lazy imports keep the module loadable where PyJWT
    isn't installed (the test seam is used there instead)."""
    try:
        import jwt                          # PyJWT
        from jwt import PyJWKClient
    except ImportError as exc:              # pragma: no cover - env dependent
        raise IdentityError(
            "PyJWT is required for live identity verification; set "
            "settings.IDENTITY_VERIFIER or install PyJWT[crypto]") from exc

    cfg = _PROVIDERS[provider]
    import os
    audience = os.environ.get(cfg["audience_env"])
    if not audience:                        # pragma: no cover - config
        raise IdentityError(
            f"{cfg['audience_env']} must be set to verify {provider} tokens")
    try:
        signing_key = PyJWKClient(cfg["jwks_url"]).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token, signing_key.key, algorithms=["RS256", "ES256"],
            audience=audience,
            options={"require": ["exp", "iss", "sub", "aud"]})
    except Exception as exc:                # PyJWT raises a family of errors
        raise IdentityError(f"{provider} token verification failed: {exc}") from exc
    if claims.get("iss") not in cfg["issuers"]:
        raise IdentityError(f"unexpected issuer {claims.get('iss')!r}")
    subject = claims.get("sub")
    if not subject:
        raise IdentityError("verified token has no subject")
    return subject
