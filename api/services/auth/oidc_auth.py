"""Cerulean (Authentik) OIDC — authorization-code + PKCE, then a Dograh session.

When ``AUTH_PROVIDER=oidc`` Cerulean's Authentik is the *only* way to obtain a
session: the local email/password routes are gated off (``require_local_auth``
404s for any non-``local`` provider), so there is no bypass to leave enabled —
an operator cannot be locked out by a stale password, and no password is ever
accepted for an SSO account. Dograh then mints its **own** JWT
(``create_jwt_token``) once Authentik has vouched for the user, which is what
keeps this change small: every existing endpoint, the WebSocket auth dependency
and the UI's cookie flow stay exactly as they are. Only the way a *session
starts* changes.

This mirrors the OIDC client in the Capstone dashboard (``dashboard-backend``
``app/auth.py``) deliberately, down to the environment variable names, so one
set of values configures both products.

Everything here runs server-side. The client secret never reaches the browser;
the browser only ever sees a short-lived ``state`` cookie and, at the end, the
session token Dograh would have issued for a password login anyway.
"""

from __future__ import annotations

import base64
import hashlib
import os
import secrets
import time
from typing import Any
from urllib.parse import urlencode, urlsplit

import aiohttp
import jwt

# Authentik's default signing algorithm for OAuth2 providers. Pinned rather than
# read from the provider's metadata: accepting whatever `id_token_signing_alg_
# values_supported` advertises would let a compromised or misconfigured
# discovery document talk us into `none` or an HMAC algorithm keyed on a public
# value.
_ID_TOKEN_ALGORITHMS = ["RS256"]

# Discovery documents change rarely and every login would otherwise pay a round
# trip for one. Cached in-process; a restart or TTL expiry refetches.
_DISCOVERY_TTL_SECONDS = 3600
_discovery_cache: dict[str, Any] | None = None
_discovery_fetched_at = 0.0

# `state` is single-use and only needs to survive the user's trip through the
# consent screen.
OIDC_STATE_COOKIE = "dograh_oidc_state"
OIDC_STATE_TTL_SECONDS = 600


class OidcError(Exception):
    """Any failure that should surface to the user as a failed sign-in."""


class OidcNotConfiguredError(OidcError):
    """Raised when the OIDC flow is used without the required configuration."""


def oidc_enabled() -> bool:
    return bool(
        os.environ.get("AUTHENTIK_ISSUER_URL")
        and os.environ.get("AUTHENTIK_CLIENT_ID")
        and os.environ.get("AUTHENTIK_CLIENT_SECRET")
    )


def issuer_base() -> str:
    return (os.environ.get("AUTHENTIK_ISSUER_URL") or "").rstrip("/")


def client_id() -> str:
    return os.environ.get("AUTHENTIK_CLIENT_ID") or ""


def redirect_uri() -> str:
    """The redirect_uri registered on the Authentik provider.

    Authentik matches this strictly, so it has to be the public URL the browser
    actually reaches — not whatever the API believes its own hostname is.
    """
    explicit = (os.environ.get("AUTHENTIK_REDIRECT_URI") or "").strip()
    if explicit:
        return explicit
    return "https://dograh.capstone.innotel.us/api/v1/auth/oidc/callback"


def post_login_redirect() -> str:
    """Where the browser lands once a session has been minted.

    The UI's own callback route, which reads the token out of the URL fragment
    and stores it through the same session mechanism a password login uses.
    """
    explicit = (os.environ.get("AUTHENTIK_POST_LOGIN_REDIRECT") or "").strip()
    if explicit:
        return explicit
    return "https://dograh.capstone.innotel.us/auth/callback"


def _registrable_parent(host: str) -> str:
    """`.capstone.innotel.us` for `dograh.capstone.innotel.us`; "" otherwise.

    A name is widened only when it has a label to drop *and* at least one label
    left under the parent — four labels or more. Below that there is nothing
    this can safely infer, and host-only is the answer:

      * a two-label name has no parent worth having;
      * a three-label one — `capstone.innotel.us` — has a parent that is the
        *organisation* domain (`innotel.us`), shared with the rest of the
        estate, so widening to it would serve the state/PKCE cookie to a dozen
        unrelated applications. Nothing is gained either, because every name
        this app answers on (the apex, `app.`, `dograh.`) is covered by the
        apex, which is exactly what the provider registers as the callback when
        the apex is the callback host. A layout that really does need a wider
        cookie (an apex callback with sign-ins also starting on `app.`/`dograh.`
        and no edge hand-off) sets `AUTHENTIK_COOKIE_DOMAIN` explicitly.

    Returns "" for an IPv4 literal too, whose "parent" would be a meaningless
    suffix of the address.
    """
    parts = (host or "").strip().strip(".").split(".")
    if len(parts) < 4 or all(part.isdigit() for part in parts):
        return ""
    return "." + ".".join(parts[1:])


def state_cookie_domain() -> str:
    """Domain the OIDC state/PKCE cookie is served to ('' = host-only).

    The state cookie is written when the browser starts a sign-in and read back
    when Authentik returns to the provider's *registered* redirect_uri. Those
    are only the same host by chance: the app answers on the apex and on both
    its `app.`/`dograh.` names, while the provider registers exactly one
    callback. A state cookie with no Domain is host-only, so a sign-in started
    on a name the callback does not return to loses it and can only answer
    `expired` — the "Sign-in could not be completed" an operator sees. Scoping
    it to a parent that covers both hosts (`.capstone.innotel.us`) lets the
    same sign-in finish on the callback host.

    Both layouts are covered: with the callback on `dograh.` the derived parent
    is `.capstone.innotel.us`, and with it on the apex the derivation returns
    "" — host-only, which is already correct there, and deliberately not
    `.innotel.us` (see `_registrable_parent`).

    ``AUTHENTIK_COOKIE_DOMAIN`` overrides the derivation for a layout whose
    names do not share a parent this can infer.
    """
    explicit = (os.environ.get("AUTHENTIK_COOKIE_DOMAIN") or "").strip()
    if explicit:
        return explicit if explicit.startswith(".") else "." + explicit
    host = (
        urlsplit(redirect_uri()).hostname
        or urlsplit(post_login_redirect()).hostname
        or ""
    )
    return _registrable_parent(host)


def organization_provider_id() -> str:
    """The single shared organization every OIDC user is placed into.

    This deployment is staff/admin-only, so tenancy is not derived from the
    identity provider — one organization holds all the call data, and adding a
    person in Authentik does not silently create a second, empty tenant.
    """
    return (os.environ.get("AUTHENTIK_ORGANIZATION_PROVIDER_ID") or "oidc-shared").strip()


def admin_emails() -> set[str]:
    """Emails that should hold superuser rights, mirroring the local admin.

    ``AUTHENTIK_ALLOWED_EMAILS`` is the admission list (empty = anyone Authentik
    authenticates); ``AUTHENTIK_ADMIN_EMAILS`` grants rights within it.
    """
    raw = os.environ.get("AUTHENTIK_ADMIN_EMAILS", "") or ""
    return {e.strip().lower() for e in raw.split(",") if e.strip()}


def allowed_emails() -> set[str]:
    """Admission list. Falls back to the admin list so a single variable can
    both restrict access and grant rights on a locked-down install."""
    raw = (os.environ.get("AUTHENTIK_ALLOWED_EMAILS") or "").strip()
    if not raw:
        return admin_emails()
    return {e.strip().lower() for e in raw.split(",") if e.strip()}


def allowed_groups() -> set[str]:
    """Groups that admit an identity (AUTHENTIK_ALLOWED_GROUPS).

    Membership is checked against the token's ``groups`` claim, which Authentik
    fills from the 'groups' scope mapping — the request has to actually ask for
    that scope (see ``authorization_url``) or the claim never arrives.
    Empty = no group-based admission."""
    raw = (os.environ.get("AUTHENTIK_ALLOWED_GROUPS") or "").strip()
    return {g.strip() for g in raw.split(",") if g.strip()}


def claims_groups(claims: dict[str, Any]) -> set[str]:
    """The identity's groups from the token, tolerating the shapes providers
    emit: a list (Authentik) or a comma-separated string."""
    raw = claims.get("groups") or []
    if isinstance(raw, str):
        raw = raw.split(",")
    return {str(g).strip() for g in raw if str(g).strip()}


async def discovery(force: bool = False) -> dict[str, Any]:
    global _discovery_cache, _discovery_fetched_at

    if not oidc_enabled():
        raise OidcNotConfiguredError("OIDC is not configured")

    fresh = (
        _discovery_cache is not None
        and (time.time() - _discovery_fetched_at) < _DISCOVERY_TTL_SECONDS
    )
    if fresh and not force:
        return _discovery_cache

    url = f"{issuer_base()}/.well-known/openid-configuration"
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, timeout=aiohttp.ClientTimeout(total=15)) as resp:
                if resp.status >= 400:
                    raise OidcError(f"OIDC discovery failed ({resp.status})")
                document = await resp.json()
    except OidcError:
        raise
    except (aiohttp.ClientError, ValueError) as exc:
        raise OidcError("OIDC discovery failed") from exc

    for required in ("authorization_endpoint", "token_endpoint", "jwks_uri"):
        if not document.get(required):
            raise OidcError(f"OIDC discovery document is missing {required}")

    _discovery_cache = document
    _discovery_fetched_at = time.time()
    return document


def new_pkce_pair() -> tuple[str, str]:
    """Return (code_verifier, code_challenge) for S256 PKCE.

    Authentik is a public-ish client here but the secret is used anyway; PKCE is
    what stops an intercepted authorization code from being redeemed by anyone
    who merely observed the redirect.
    """
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode().rstrip("=")
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
    return verifier, challenge


def new_state() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")


async def authorization_url(*, state: str, code_challenge: str) -> str:
    document = await discovery()
    params = {
        "response_type": "code",
        "client_id": client_id(),
        "redirect_uri": redirect_uri(),
        # `groups` is what makes group-based admission possible: the provider
        # carries the mapping, but the claim is only emitted when the client
        # asks for the scope.
        "scope": "openid email profile groups",
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    }
    separator = "&" if "?" in document["authorization_endpoint"] else "?"
    return f"{document['authorization_endpoint']}{separator}{urlencode(params)}"


async def exchange_code(code: str, code_verifier: str) -> dict[str, Any]:
    """Redeem the authorization code for tokens."""
    document = await discovery()
    data = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri(),
        "client_id": client_id(),
        "client_secret": os.environ.get("AUTHENTIK_CLIENT_SECRET", ""),
        "code_verifier": code_verifier,
    }
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                document["token_endpoint"],
                data=data,
                timeout=aiohttp.ClientTimeout(total=20),
            ) as resp:
                payload = await resp.json(content_type=None)
                if resp.status >= 400:
                    raise OidcError("Token exchange rejected by the identity provider")
    except OidcError:
        raise
    except (aiohttp.ClientError, ValueError) as exc:
        raise OidcError("Token exchange failed") from exc

    if not payload.get("id_token"):
        raise OidcError("Identity provider returned no id_token")
    return payload


async def verify_id_token(id_token: str) -> dict[str, Any]:
    """Verify signature + issuer + audience + expiry, and return the claims.

    The signature is checked against the provider's own JWKS, so this is a real
    verification rather than a decode.
    """
    document = await discovery()
    try:
        jwks_client = jwt.PyJWKClient(document["jwks_uri"])
        signing_key = jwks_client.get_signing_key_from_jwt(id_token)
        claims = jwt.decode(
            id_token,
            signing_key.key,
            algorithms=_ID_TOKEN_ALGORITHMS,
            audience=client_id(),
            # Authentik can run in "global" issuer mode, where the per-app
            # discovery document advertises the instance-wide issuer (with a
            # trailing slash) even though AUTHENTIK_ISSUER_URL points at the
            # per-app path. The discovery document is authoritative for what
            # `iss` will actually contain — pin to it, not to our base URL.
            issuer=document.get("issuer") or issuer_base(),
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.PyJWTError as exc:
        raise OidcError("Identity token failed verification") from exc
    return claims


def claims_email(claims: dict[str, Any]) -> str:
    email = claims.get("email") or claims.get("preferred_username") or ""
    return str(email).strip().lower()


def claims_name(claims: dict[str, Any]) -> str:
    return str(claims.get("name") or claims.get("preferred_username") or "").strip()


def is_allowed(claims: dict[str, Any]) -> bool:
    """Admission gate — who may hold a Dograh session.

    Runs *after* token verification, so it cannot be reached without a valid
    Authentik identity. An identity is admitted when EITHER:

      * its email is on the email allowlist (``AUTHENTIK_ALLOWED_EMAILS``,
        falling back to the admin list so a single variable can both restrict
        access and grant rights on a locked-down install), OR
      * it carries any of the groups in ``AUTHENTIK_ALLOWED_GROUPS`` — the SSO
        group gate, so admission follows IdP membership instead of a hand-maintained
        list of addresses.

    With neither configured, any authenticated identity is admitted. An identity
    that authenticates but satisfies neither list is rejected rather than
    admitted, which is the behaviour you want when the provider is shared with
    other applications.
    """
    emails = allowed_emails()
    if emails and claims_email(claims) in emails:
        return True
    groups = allowed_groups()
    if groups and claims_groups(claims) & groups:
        return True
    return not emails and not groups


def subject(claims: dict[str, Any]) -> str:
    """Stable identity for the local user row.

    Namespaced so an Authentik subject can never collide with a Stack Auth id or
    a locally-created ``oss_*`` provider id on a deployment that has been
    through more than one auth provider.
    """
    return f"oidc_{claims['sub']}"
