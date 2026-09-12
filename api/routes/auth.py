from urllib.parse import quote, unquote, urlsplit

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import RedirectResponse
from loguru import logger

from api.constants import AUTH_PROVIDER, ENABLE_SIGNUP
from api.db import db_client
from api.db.models import UserModel
from api.enums import PostHogEvent
from api.schemas.auth import AuthResponse, LoginRequest, SignupRequest, UserResponse
from api.services.auth import oidc_auth
from api.services.auth.depends import get_user, require_local_auth
from api.services.organization_bootstrap import ensure_organization_bootstrapped
from api.services.posthog_client import capture_event
from api.utils.auth import create_jwt_token, hash_password, verify_password

router = APIRouter(
    prefix="/auth",
    tags=["auth"],
)

# Absolute path the UI sends the browser to when starting OIDC sign-in. Spelled
# out rather than assembled from the router prefix because the `/api/v1` half is
# added where this router is mounted, and the UI needs the finished path to hand
# to `window.location` — a value it cannot derive from a relative route.
OIDC_LOGIN_PATH = "/api/v1/auth/oidc/login"


@router.post(
    "/signup",
    response_model=AuthResponse,
    dependencies=[Depends(require_local_auth)],
)
async def signup(request: SignupRequest):
    if not ENABLE_SIGNUP:
        raise HTTPException(status_code=403, detail="Signup is disabled")

    # Check if email is already taken
    existing_user = await db_client.get_user_by_email(request.email)
    if existing_user:
        raise HTTPException(status_code=409, detail="Email already registered")

    # Hash password and create user
    hashed = hash_password(request.password)
    user = await db_client.create_user_with_email(
        email=request.email,
        password_hash=hashed,
        name=request.name,
    )

    # Create organization for the user
    org_provider_id = f"org_{user.provider_id}"
    organization, _ = await db_client.get_or_create_organization_by_provider_id(
        org_provider_id=org_provider_id, user_id=user.id
    )

    # Link user to organization
    await db_client.add_user_to_organization(user.id, organization.id)
    await db_client.update_user_selected_organization(user.id, organization.id)

    # Create default service configuration. This never raises, so signup still
    # succeeds if MPS is down; `_handle_oss_auth` re-enters bootstrap on the
    # user's subsequent authenticated requests, so a failure here is recovered
    # rather than permanent. Doing it here anyway means the common case has a
    # model configuration and SIP connectivity by the time the UI first loads.
    await ensure_organization_bootstrapped(
        organization.id,
        created_by=user.provider_id,
    )

    # Create JWT token
    token = create_jwt_token(user.id, request.email)

    capture_event(
        distinct_id=str(user.provider_id),
        event=PostHogEvent.SIGNED_UP,
        properties={
            "organization_id": organization.id,
            "auth_provider": "local",
        },
    )

    return AuthResponse(
        token=token,
        user=UserResponse(
            id=user.id,
            email=user.email,
            name=request.name,
            organization_id=organization.id,
            provider_id=user.provider_id,
        ),
    )


@router.post(
    "/login",
    response_model=AuthResponse,
    dependencies=[Depends(require_local_auth)],
)
async def login(request: LoginRequest):
    # Look up user by email
    user = await db_client.get_user_by_email(request.email)
    if not user or not user.password_hash:
        raise HTTPException(status_code=401, detail="Invalid email or password")

    # Verify password
    if not verify_password(request.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")

    # Create JWT token
    token = create_jwt_token(user.id, user.email)

    capture_event(
        distinct_id=str(user.provider_id),
        event=PostHogEvent.SIGNED_IN,
        properties={
            "organization_id": user.selected_organization_id,
            "auth_provider": "local",
        },
    )

    return AuthResponse(
        token=token,
        user=UserResponse(
            id=user.id,
            email=user.email,
            organization_id=user.selected_organization_id,
            provider_id=user.provider_id,
        ),
    )


@router.get("/me", response_model=UserResponse)
async def get_current_user(user: UserModel = Depends(get_user)):
    return UserResponse(
        id=user.id,
        email=user.email,
        organization_id=user.selected_organization_id,
        provider_id=user.provider_id,
    )


# ── Cerulean (Authentik) OIDC ────────────────────────────────────────────────
#
# Mounted in every mode but gated like the local routes, so the OpenAPI spec and
# the generated clients do not vary with AUTH_PROVIDER.
#
# The two halves of the flow live in different processes on purpose. This module
# holds the client secret and does the token verification; the UI holds the
# session cookie, because that cookie is read by its own middleware and
# `/api/auth/oss`, and duplicating that mechanism here would mean two places to
# keep in step. The hand-off between them is a one-time fragment on the
# post-login redirect — the same token a password login already returns to the
# UI to store.


def _require_oidc() -> None:
    if AUTH_PROVIDER != "oidc":
        raise HTTPException(status_code=404, detail="Not found")
    if not oidc_auth.oidc_enabled():
        raise HTTPException(
            status_code=503, detail="OIDC is enabled but not configured"
        )


def _safe_next(next_path: str | None) -> str:
    """Only allow same-origin relative targets.

    `next` round-trips through the identity provider, so treating it as trusted
    would turn the login endpoint into an open redirect.
    """
    candidate = (next_path or "").strip()
    if candidate.startswith("/") and not candidate.startswith("//"):
        return candidate
    return "/"


def _failure_redirect(reason: str) -> RedirectResponse:
    """Send the browser back to the login screen instead of showing a 500.

    The reason is a short slug rather than the exception text: this response is
    user-visible, and OIDC errors can carry provider internals.
    """
    base = oidc_auth.post_login_redirect()
    origin = "{0.scheme}://{0.netloc}".format(urlsplit(base))
    return RedirectResponse(f"{origin}/auth/login?error={quote(reason)}")


@router.get("/oidc/login", dependencies=[Depends(_require_oidc)])
async def oidc_login(next: str | None = Query(default=None)):
    """Start the authorization-code + PKCE flow.

    `state` and the PKCE verifier travel in one short-lived httpOnly cookie.
    They have to survive the trip to Authentik and back, and the cookie is the
    only per-browser storage available across two services; a server-side store
    would need a session table for what is a ten-minute, single-use value.
    """
    state = oidc_auth.new_state()
    verifier, challenge = oidc_auth.new_pkce_pair()
    try:
        url = await oidc_auth.authorization_url(state=state, code_challenge=challenge)
    except oidc_auth.OidcError as exc:
        logger.warning(f"OIDC login could not start: {exc}")
        return _failure_redirect("unavailable")

    response = RedirectResponse(url)
    response.set_cookie(
        oidc_auth.OIDC_STATE_COOKIE,
        f"{state}.{verifier}.{quote(_safe_next(next), safe='')}",
        max_age=oidc_auth.OIDC_STATE_TTL_SECONDS,
        httponly=True,
        secure=True,
        samesite="lax",
        path="/",
    )
    return response


@router.get("/oidc/callback", dependencies=[Depends(_require_oidc)])
async def oidc_callback(
    request: Request,
    code: str | None = Query(default=None),
    state: str | None = Query(default=None),
    error: str | None = Query(default=None),
):
    """Finish the flow: verify, provision, and mint a Dograh session.

    Authentik reports a declined consent as `?error=access_denied`, which is a
    user decision rather than a fault, so it is reported as such.
    """
    if error:
        logger.info(f"OIDC sign-in declined at the provider: {error}")
        return _failure_redirect("denied" if error == "access_denied" else "failed")

    cookie = _state_cookie(request)
    if cookie is None:
        return _failure_redirect("expired")
    expected_state, verifier, next_path = cookie

    if not state or not expected_state or state != expected_state:
        # A mismatch means the callback did not originate from a login this
        # browser started — treat it as an attack, not a glitch.
        logger.warning("OIDC callback state did not match the initiating cookie")
        return _failure_redirect("failed")

    if not code:
        return _failure_redirect("failed")

    try:
        tokens = await oidc_auth.exchange_code(code, verifier)
        claims = await oidc_auth.verify_id_token(tokens["id_token"])
    except oidc_auth.OidcError as exc:
        logger.warning(f"OIDC sign-in failed verification: {exc}")
        return _failure_redirect("failed")

    if not oidc_auth.is_allowed(claims):
        # Authenticated, but not admitted to this application.
        logger.warning(
            f"OIDC sign-in denied for {oidc_auth.claims_email(claims) or '<no email>'}"
        )
        return _failure_redirect("not_allowed")

    try:
        user = await _provision_oidc_user(claims)
    except Exception:
        logger.exception("Failed to provision the OIDC user")
        return _failure_redirect("failed")

    token = create_jwt_token(user.id, user.email or oidc_auth.claims_email(claims))
    capture_event(
        distinct_id=str(user.provider_id),
        event=PostHogEvent.SIGNED_IN,
        properties={
            "organization_id": user.selected_organization_id,
            "auth_provider": "oidc",
        },
    )

    response = RedirectResponse(
        f"{oidc_auth.post_login_redirect()}#access_token={quote(token)}&next={quote(next_path)}"
    )
    response.delete_cookie(oidc_auth.OIDC_STATE_COOKIE, path="/")
    return response


def _state_cookie(request: Request) -> tuple[str, str, str] | None:
    """Parse (state, code_verifier, next_path) out of the state cookie.

    Returns None for anything malformed or absent. Every one of those cases is
    something the user can cause legitimately — an expired cookie, a bookmarked
    callback URL — so they all have to funnel into a redirect back to the login
    screen rather than an exception.
    """
    raw = request.cookies.get(oidc_auth.OIDC_STATE_COOKIE)
    if not raw:
        return None
    parts = raw.split(".", 2)
    if len(parts) != 3 or not all(parts):
        return None
    state, verifier, encoded_next = parts
    return state, verifier, unquote(encoded_next)


async def _provision_oidc_user(claims: dict) -> UserModel:
    """Map an Authentik identity onto a local user in the shared organization.

    Keyed on the Authentik subject, so the same person keeps one user row no
    matter how many times they sign in or what they change their display name
    to. Placing everyone in one organization is deliberate: this deployment is
    staff-only, so the identity provider is an authentication source, not a
    tenancy model.
    """
    provider_id = oidc_auth.subject(claims)
    user, was_created = await db_client.get_or_create_user_by_provider_id(provider_id)

    email = oidc_auth.claims_email(claims)
    if email and user.email != email:
        await db_client.update_user_email(user.id, email)
        user.email = email

    organization, _ = await db_client.get_or_create_organization_by_provider_id(
        org_provider_id=oidc_auth.organization_provider_id(), user_id=user.id
    )
    if user.selected_organization_id != organization.id:
        await db_client.add_user_to_organization(user.id, organization.id)
        await db_client.update_user_selected_organization(user.id, organization.id)
        user.selected_organization_id = organization.id

    wanted_superuser = email in oidc_auth.admin_emails()
    if bool(user.is_superuser) != wanted_superuser:
        await db_client.set_user_superuser(user.id, wanted_superuser)
        user.is_superuser = wanted_superuser

    if was_created:
        capture_event(
            distinct_id=provider_id,
            event=PostHogEvent.SIGNED_UP,
            properties={"auth_provider": "oidc"},
        )

    # Same reasoning as the local path: a provisioning failure must not block a
    # user who is already authenticated, and re-entering it per request is what
    # lets a failed attempt heal instead of stranding the organization.
    await ensure_organization_bootstrapped(
        organization.id,
        created_by=user.provider_id,
    )
    return user
