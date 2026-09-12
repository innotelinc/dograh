"""Tests for the Cerulean (Authentik) OIDC sign-in path.

Two layers, matching the split in the module under test:

* unit tests for the protocol pieces that are pure functions (PKCE, the
  allowlist gate, the subject namespace);
* route tests that drive the real FastAPI router with the network-facing calls
  stubbed at the module boundary, so the *wiring* is what is under test —
  `state` handling, the failure redirects, and the fact that a successful
  callback ends in a Dograh session rather than a provider token.

A note on why so many of these assert on redirects instead of status codes:
every failure in this flow is something a user can cause legitimately (expired
cookie, declined consent, a bookmarked callback URL). They all have to land back
on the login screen. A 4xx/5xx from any of them is a bug even though the flow
"failed correctly".
"""

import base64
import json
from types import SimpleNamespace

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import api.routes.auth as auth_routes
from api.constants import OSS_JWT_SECRET
from api.routes.auth import router
from api.services.auth import oidc_auth


def _make_test_app() -> FastAPI:
    app = FastAPI()
    app.include_router(router)
    return app


def _client() -> TestClient:
    """An HTTPS test client.

    The flow's state cookie is `Secure` (it carries the PKCE verifier), and a
    test client on plain http will not send it back — so every callback test
    would fail at the cookie check and prove nothing. Production sits behind a
    TLS edge proxy, so https is also the honest base URL.
    """
    return TestClient(_make_test_app(), base_url="https://testserver")


@pytest.fixture
def oidc_env(monkeypatch):
    """Configure the app for OIDC and silence the outbound calls."""
    monkeypatch.setattr(auth_routes, "AUTH_PROVIDER", "oidc")
    monkeypatch.setenv("AUTHENTIK_ISSUER_URL", "https://auth.example.test/application/o/dograh")
    monkeypatch.setenv("AUTHENTIK_CLIENT_ID", "dograh")
    monkeypatch.setenv("AUTHENTIK_CLIENT_SECRET", "secret")
    monkeypatch.setenv(
        "AUTHENTIK_REDIRECT_URI",
        "https://dograh.example.test/api/v1/auth/oidc/callback",
    )
    monkeypatch.setenv(
        "AUTHENTIK_POST_LOGIN_REDIRECT", "https://dograh.example.test/auth/callback"
    )
    monkeypatch.delenv("AUTHENTIK_ALLOWED_EMAILS", raising=False)
    monkeypatch.delenv("AUTHENTIK_ADMIN_EMAILS", raising=False)
    # Never reach out to PostHog from a test.
    monkeypatch.setattr(auth_routes, "capture_event", lambda **_: None)
    # Discovery is HTTP; stub it so authorization_url() still builds a real URL.
    async def fake_discovery(force: bool = False):
        return {
            "authorization_endpoint": "https://auth.example.test/application/o/authorize/",
            "token_endpoint": "https://auth.example.test/application/o/token/",
            "jwks_uri": "https://auth.example.test/application/o/dograh/jwks/",
        }

    monkeypatch.setattr(oidc_auth, "discovery", fake_discovery)
    return monkeypatch


# ── protocol pieces ─────────────────────────────────────────────────────────


def test_pkce_challenge_is_sha256_of_the_verifier():
    import hashlib

    verifier, challenge = oidc_auth.new_pkce_pair()
    expected = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        .decode()
        .rstrip("=")
    )
    assert challenge == expected
    # Two calls must not collide, or every browser would share a verifier.
    assert oidc_auth.new_pkce_pair()[0] != verifier


def test_subject_is_namespaced_away_from_other_providers():
    """A raw Authentik `sub` could otherwise collide with a Stack id or an
    `oss_*` provider id on a deployment that has used more than one provider."""
    assert oidc_auth.subject({"sub": "abc"}) == "oidc_abc"


def test_allowlist_is_empty_by_default(monkeypatch):
    monkeypatch.delenv("AUTHENTIK_ALLOWED_EMAILS", raising=False)
    monkeypatch.delenv("AUTHENTIK_ADMIN_EMAILS", raising=False)
    assert oidc_auth.allowed_emails() == set()
    assert oidc_auth.is_allowed({"email": "anyone@example.com"}) is True


def test_allowlist_gate_rejects_unlisted_email(monkeypatch):
    monkeypatch.setenv("AUTHENTIK_ALLOWED_EMAILS", "Boss@Example.com")
    monkeypatch.delenv("AUTHENTIK_ADMIN_EMAILS", raising=False)

    # Case-insensitive: the provider is the source of truth for the address,
    # but an operator typing a capital letter must not lock the user out.
    assert oidc_auth.is_allowed({"email": "boss@example.com"}) is True
    assert oidc_auth.is_allowed({"email": "stranger@example.com"}) is False
    # preferred_username is the fallback when the provider omits `email`.
    assert oidc_auth.is_allowed({"preferred_username": "boss@example.com"}) is True


def test_admin_list_falls_back_to_being_the_admission_list(monkeypatch):
    """One variable has to be enough to both lock an install down and grant
    rights, otherwise a strict install silently admits everyone."""
    monkeypatch.delenv("AUTHENTIK_ALLOWED_EMAILS", raising=False)
    monkeypatch.setenv("AUTHENTIK_ADMIN_EMAILS", "boss@example.com")

    assert oidc_auth.allowed_emails() == {"boss@example.com"}
    assert oidc_auth.admin_emails() == {"boss@example.com"}


# ── route gating ────────────────────────────────────────────────────────────


def test_oidc_routes_are_hidden_unless_provider_is_oidc(monkeypatch):
    monkeypatch.setattr(auth_routes, "AUTH_PROVIDER", "local")
    client = _client()

    response = client.get("/auth/oidc/login", follow_redirects=False)

    assert response.status_code == 404
    assert response.json() == {"detail": "Not found"}


def test_oidc_login_reports_503_when_enabled_but_unconfigured(monkeypatch):
    monkeypatch.setattr(auth_routes, "AUTH_PROVIDER", "oidc")
    for var in (
        "AUTHENTIK_ISSUER_URL",
        "AUTHENTIK_CLIENT_ID",
        "AUTHENTIK_CLIENT_SECRET",
    ):
        monkeypatch.delenv(var, raising=False)
    client = _client()

    response = client.get("/auth/oidc/login", follow_redirects=False)

    # A distinct code from the 404 above: "this deployment wants OIDC and is
    # misconfigured" is an operator problem, not a hidden route.
    assert response.status_code == 503


# ── login initiation ────────────────────────────────────────────────────────


def test_oidc_login_redirects_to_provider_and_stores_state(oidc_env):
    client = _client()

    response = client.get("/auth/oidc/login?next=/workflow/1", follow_redirects=False)

    assert response.status_code == 307
    location = response.headers["location"]
    assert location.startswith(
        "https://auth.example.test/application/o/authorize/?"
    )
    assert "code_challenge_method=S256" in location
    assert "client_id=dograh" in location
    assert "state=" in location
    assert response.cookies.get(oidc_auth.OIDC_STATE_COOKIE)


def test_oidc_login_refuses_to_bounce_to_another_origin(oidc_env):
    """`next` round-trips through the provider. Trusting it would turn the login
    endpoint into an open redirect."""
    client = _client()

    response = client.get(
        "/auth/oidc/login?next=https://evil.example.com/steal", follow_redirects=False
    )
    cookie = response.cookies.get(oidc_auth.OIDC_STATE_COOKIE)
    _, _, encoded_next = cookie.split(".", 2)

    assert encoded_next and encoded_next != "https%3A%2F%2Fevil.example.com%2Fsteal"


def test_oidc_login_refuses_protocol_relative_next(oidc_env):
    client = _client()

    response = client.get("/auth/oidc/login?next=//evil.example.com", follow_redirects=False)
    cookie = response.cookies.get(oidc_auth.OIDC_STATE_COOKIE)
    _, _, encoded_next = cookie.split(".", 2)

    assert encoded_next != "%2F%2Fevil.example.com"


# ── callback failure paths ──────────────────────────────────────────────────


def _start(client: TestClient) -> None:
    """Run the initiation step so the state cookie exists."""
    client.get("/auth/oidc/login", follow_redirects=False)


def test_callback_without_state_cookie_asks_for_a_fresh_login(oidc_env):
    client = _client()

    response = client.get(
        "/auth/oidc/callback?code=abc&state=whatever", follow_redirects=False
    )

    assert response.status_code == 307
    assert response.headers["location"].endswith("/auth/login?error=expired")


def test_callback_with_mismatched_state_is_rejected(oidc_env):
    client = _client()
    _start(client)

    response = client.get(
        "/auth/oidc/callback?code=abc&state=not-the-state-we-sent",
        follow_redirects=False,
    )

    assert response.status_code == 307
    assert response.headers["location"].endswith("/auth/login?error=failed")


def test_declined_consent_is_reported_as_a_decision_not_a_fault(oidc_env):
    client = _client()
    _start(client)

    response = client.get(
        "/auth/oidc/callback?error=access_denied", follow_redirects=False
    )

    assert response.status_code == 307
    assert response.headers["location"].endswith("/auth/login?error=denied")


def test_failed_token_verification_does_not_leak_the_reason(oidc_env):
    client = _client()
    _start(client)
    state = client.cookies.get(oidc_auth.OIDC_STATE_COOKIE).split(".", 1)[0]

    async def failing_exchange(code, verifier):
        raise oidc_auth.OidcError("provider said: client_secret is wrong")

    oidc_env.setattr(oidc_auth, "exchange_code", failing_exchange)

    response = client.get(
        f"/auth/oidc/callback?code=abc&state={state}", follow_redirects=False
    )

    assert response.status_code == 307
    location = response.headers["location"]
    assert location.endswith("/auth/login?error=failed")
    assert "client_secret" not in location


# ── callback success path ───────────────────────────────────────────────────


def _stub_verified_identity(monkeypatch, claims: dict):
    async def fake_exchange(code, verifier):
        return {"id_token": "stub"}

    async def fake_verify(id_token):
        return claims

    monkeypatch.setattr(oidc_auth, "exchange_code", fake_exchange)
    monkeypatch.setattr(oidc_auth, "verify_id_token", fake_verify)


def test_successful_callback_mints_a_dograh_session(oidc_env):
    client = _client()
    _start(client)
    state = client.cookies.get(oidc_auth.OIDC_STATE_COOKIE).split(".", 1)[0]

    _stub_verified_identity(oidc_env, {"sub": "user-1", "email": "Boss@Example.com"})
    provisioned = SimpleNamespace(
        id=42,
        email="boss@example.com",
        provider_id="oidc_user-1",
        selected_organization_id=7,
        is_superuser=True,
    )

    async def fake_provision(claims):
        return provisioned

    oidc_env.setattr(auth_routes, "_provision_oidc_user", fake_provision)

    response = client.get(
        f"/auth/oidc/callback?code=abc&state={state}", follow_redirects=False
    )

    assert response.status_code == 307
    location = response.headers["location"]
    assert location.startswith("https://dograh.example.test/auth/callback#access_token=")

    token = location.split("access_token=", 1)[1].split("&", 1)[0]
    from urllib.parse import unquote

    claims = jwt.decode(unquote(token), OSS_JWT_SECRET, algorithms=["HS256"])
    # The session must be keyed on the *local* user id, which is what every
    # downstream dependency already expects.
    assert claims["sub"] == "42"
    assert claims["email"] == "boss@example.com"

    # Single-use: the state cookie must not survive the callback it authorised.
    assert oidc_auth.OIDC_STATE_COOKIE not in response.cookies


def test_callback_carries_next_through_to_the_ui(oidc_env):
    client = _client()
    client.get("/auth/oidc/login?next=/workflow/9", follow_redirects=False)
    state = client.cookies.get(oidc_auth.OIDC_STATE_COOKIE).split(".", 1)[0]

    _stub_verified_identity(oidc_env, {"sub": "user-1", "email": "a@example.com"})

    async def fake_provision(claims):
        return SimpleNamespace(
            id=1,
            email="a@example.com",
            provider_id="oidc_user-1",
            selected_organization_id=1,
            is_superuser=False,
        )

    oidc_env.setattr(auth_routes, "_provision_oidc_user", fake_provision)

    response = client.get(
        f"/auth/oidc/callback?code=abc&state={state}", follow_redirects=False
    )

    # Assert on the parsed value rather than the raw text: `quote` treats `/` as
    # safe by default, so the rendered form is `next=/workflow/9` and pinning
    # that exact spelling would be testing urllib, not this route.
    from urllib.parse import parse_qs, unquote, urlsplit

    fragment = urlsplit(response.headers["location"]).fragment
    assert parse_qs(fragment)["next"] == ["/workflow/9"]
    assert unquote(fragment.split("access_token=", 1)[1].split("&", 1)[0])


def test_authenticated_but_unlisted_user_is_refused(oidc_env):
    client = _client()
    _start(client)
    state = client.cookies.get(oidc_auth.OIDC_STATE_COOKIE).split(".", 1)[0]

    oidc_env.setenv("AUTHENTIK_ALLOWED_EMAILS", "boss@example.com")
    _stub_verified_identity(oidc_env, {"sub": "user-2", "email": "stranger@example.com"})

    async def must_not_run(claims):
        raise AssertionError("provisioning must not run for a refused identity")

    oidc_env.setattr(auth_routes, "_provision_oidc_user", must_not_run)

    response = client.get(
        f"/auth/oidc/callback?code=abc&state={state}", follow_redirects=False
    )

    assert response.status_code == 307
    assert response.headers["location"].endswith("/auth/login?error=not_allowed")


def test_provisioning_failure_is_not_reported_as_a_bad_identity(oidc_env):
    """A database problem must not look like an authentication failure — the
    user would retry forever instead of anyone seeing the real error."""
    client = _client()
    _start(client)
    state = client.cookies.get(oidc_auth.OIDC_STATE_COOKIE).split(".", 1)[0]

    _stub_verified_identity(oidc_env, {"sub": "user-1", "email": "a@example.com"})

    async def broken_provision(claims):
        raise RuntimeError("database is on fire")

    oidc_env.setattr(auth_routes, "_provision_oidc_user", broken_provision)

    response = client.get(
        f"/auth/oidc/callback?code=abc&state={state}", follow_redirects=False
    )

    assert response.status_code == 307
    assert response.headers["location"].endswith("/auth/login?error=failed")


def test_state_cookie_reader_tolerates_junk():
    """The reader is fed a cookie from the browser, so every shape of junk has to
    return None rather than raise into a 500."""
    from starlette.requests import Request

    def request_with(value):
        scope = {
            "type": "http",
            "headers": [(b"cookie", f"{oidc_auth.OIDC_STATE_COOKIE}={value}".encode())],
        }
        return Request(scope)

    assert auth_routes._state_cookie(request_with("")) is None
    assert auth_routes._state_cookie(request_with("only-one-part")) is None
    assert auth_routes._state_cookie(request_with("a.b")) is None
    assert auth_routes._state_cookie(request_with("a..c")) is None
    assert auth_routes._state_cookie(request_with("s.v.%2Fnext")) == ("s", "v", "/next")


def test_json_claims_survive_the_round_trip(oidc_env):
    """Guards the shape of what `_provision_oidc_user` is handed — a dict, not a
    provider object."""
    client = _client()
    _start(client)
    state = client.cookies.get(oidc_auth.OIDC_STATE_COOKIE).split(".", 1)[0]
    captured = {}

    _stub_verified_identity(oidc_env, {"sub": "u", "email": "a@example.com"})

    async def capture(claims):
        captured.update(claims)
        return SimpleNamespace(
            id=1,
            email="a@example.com",
            provider_id="oidc_u",
            selected_organization_id=1,
            is_superuser=False,
        )

    oidc_env.setattr(auth_routes, "_provision_oidc_user", capture)
    client.get(f"/auth/oidc/callback?code=abc&state={state}", follow_redirects=False)

    assert json.dumps(captured)  # JSON-serialisable, no provider objects
    assert captured["sub"] == "u"
