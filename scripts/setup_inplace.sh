#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$SCRIPT_DIR/lib/setup_common.sh"
BOOTSTRAP_LIB=""

if [[ ! -f "$LIB_PATH" ]]; then
    BOOTSTRAP_LIB="$(mktemp)"
    curl -fsSL -o "$BOOTSTRAP_LIB" "https://raw.githubusercontent.com/dograh-hq/dograh/main/scripts/lib/setup_common.sh"
    LIB_PATH="$BOOTSTRAP_LIB"
fi

cleanup() {
    if [[ -n "$BOOTSTRAP_LIB" ]]; then
        rm -f "$BOOTSTRAP_LIB"
    fi
    # When run via sudo (the common case: docker access, root-owned installs),
    # the rewritten .env and freshly generated certs become root-owned, breaking
    # later sudo-less edits. Hand the install back to the user who invoked sudo;
    # a no-op for unprivileged runs and real root, where SUDO_UID is unset. Runs
    # from the EXIT trap so a mid-setup failure also leaves ownership fixed.
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" && -n "${DOGRAH_DEPLOY_PROJECT_DIR:-}" && -d "$DOGRAH_DEPLOY_PROJECT_DIR" ]]; then
        echo -e "${BLUE}Restoring ownership of $DOGRAH_DEPLOY_PROJECT_DIR to ${SUDO_USER:-uid $SUDO_UID}...${NC}"
        chown -R "$SUDO_UID:$SUDO_GID" "$DOGRAH_DEPLOY_PROJECT_DIR" || true
    fi
}
trap cleanup EXIT

# shellcheck disable=SC1090
. "$LIB_PATH"

# This script lives in scripts/, so the project root is one level up. Fall back
# to the current directory when the expected layout is absent (e.g. a
# development checkout where only the deployment files were copied).
if [[ -f "$SCRIPT_DIR/../docker-compose.yaml" ]]; then
    DOGRAH_DEPLOY_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    DOGRAH_DEPLOY_PROJECT_DIR="$(pwd)"
fi
cd "$DOGRAH_DEPLOY_PROJECT_DIR"

MODE="build"
VALIDATE_ONLY=0
SKIP_SUBMODULE=0
SKIP_CERTS=0

usage() {
    cat <<'EOF'
Dograh in-place setup — configure & start the stack on an already-installed,
already-configured server (repo checked out, .env present, Docker installed).

This is the counterpart to setup_remote.sh for existing installs: it never
prompts for IPs/secrets and never overwrites .env. It initializes the pipecat
submodule, generates certs if missing, validates the config, syncs the
Postgres password, then builds and starts the stack.

Usage: setup_inplace.sh [options]

Options:
  --no-build | --pull    Pull images instead of building from source
  --preflight-only       Validate config and exit without starting anything
  --skip-submodule       Skip git submodule init (already initialized)
  --skip-certs           Skip certificate generation (already present)
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build|--pull)
            MODE="pull"
            ;;
        --preflight-only|--validate-only)
            VALIDATE_ONLY=1
            ;;
        --skip-submodule)
            SKIP_SUBMODULE=1
            ;;
        --skip-certs)
            SKIP_CERTS=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            dograh_fail "Unknown argument: $1 (see --help)"
            ;;
    esac
    shift
done

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 Dograh In-place Setup                        ║"
echo "║  Configure & start on an already-installed server           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

dograh_info "Project directory: $DOGRAH_DEPLOY_PROJECT_DIR"

# ---------------------------------------------------------------------------
# Preflight: this script is only for an existing, configured install.
# ---------------------------------------------------------------------------
[[ -f docker-compose.yaml ]] || dograh_fail "docker-compose.yaml not found in $DOGRAH_DEPLOY_PROJECT_DIR"
if [[ ! -f .env ]]; then
    dograh_fail ".env not found — this script is for an already-configured server.\nFor a fresh install run: sudo ./scripts/setup_remote.sh"
fi
command -v docker >/dev/null 2>&1 || dograh_fail "docker not found. Install Docker before running this script."

# Load and validate the existing environment. Nothing here rewrites secrets.
dograh_load_env_file .env
dograh_validate_remote_runtime_env

# ---------------------------------------------------------------------------
# [1/5] pipecat submodule (required to build the api image from source)
# ---------------------------------------------------------------------------
if [[ "$SKIP_SUBMODULE" == "1" ]]; then
    dograh_info "[1/5] Skipping submodule init"
elif [[ ! -f .gitmodules ]]; then
    dograh_info "[1/5] No submodules configured — skipping"
elif [[ -d pipecat/.git ]] || [[ -n "$(ls -A pipecat 2>/dev/null)" ]]; then
    dograh_info "[1/5] pipecat submodule already initialized"
else
    dograh_info "[1/5] Initializing pipecat submodule..."
    git submodule update --init --recursive
    dograh_success "✓ pipecat submodule initialized"
fi

# ---------------------------------------------------------------------------
# [2/5] Certificates (dograh-init requires certs/local.crt + local.key)
# ---------------------------------------------------------------------------
if [[ "$SKIP_CERTS" == "1" ]]; then
    dograh_info "[2/5] Skipping certificate generation"
elif [[ -f certs/local.crt && -f certs/local.key ]]; then
    dograh_info "[2/5] Certificates already present"
else
    dograh_info "[2/5] Generating self-signed certificate..."
    mkdir -p certs
    CN="${PUBLIC_HOST:-localhost}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout certs/local.key -out certs/local.crt -days 365 \
        -subj "/CN=$CN"
    chmod 644 certs/local.crt certs/local.key
    dograh_success "✓ Certificate generated (CN=$CN)"
fi

# ---------------------------------------------------------------------------
# [3/5] Validate the rendered remote config
# ---------------------------------------------------------------------------
dograh_info "[3/5] Validating remote init configuration..."
dograh_prepare_remote_install "$DOGRAH_DEPLOY_PROJECT_DIR"
docker compose config -q
dograh_success "✓ Configuration validated"

if [[ "$VALIDATE_ONLY" == "1" ]]; then
    echo ""
    dograh_success "✓ Preflight passed — no changes made"
    exit 0
fi

# ---------------------------------------------------------------------------
# Start the stack
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
else
    COMPOSE_CMD=(sudo docker compose)
fi

# Reconcile the Postgres role password with .env before starting the API.
# POSTGRES_PASSWORD only applies on first volume init, so an existing volume can
# hold a stale password the API would fail to authenticate against. Idempotent.
dograh_sync_postgres_password "$DOGRAH_DEPLOY_PROJECT_DIR" "${COMPOSE_CMD[@]}"

# When SERVER_IP is a private/reserved address the host has no public IP, so
# start the cloudflared service (tunnel profile) to make webhooks reachable.
PROFILE_ARGS=(--profile remote)
if dograh_is_local_ipv4 "${SERVER_IP:-}"; then
    PROFILE_ARGS+=(--profile tunnel)
fi

if [[ "$MODE" == "build" ]]; then
    dograh_info "[4/5] Building images and starting the stack (first build takes 10-20 min)..."
    "${COMPOSE_CMD[@]}" "${PROFILE_ARGS[@]}" up -d --build --force-recreate
else
    dograh_info "[4/5] Pulling images and starting the stack..."
    "${COMPOSE_CMD[@]}" "${PROFILE_ARGS[@]}" up -d --pull always --force-recreate
fi

# ---------------------------------------------------------------------------
# [5/5] Health check
# ---------------------------------------------------------------------------
dograh_info "[5/5] Waiting for the API to come up..."
API_ID="$("${COMPOSE_CMD[@]}" "${PROFILE_ARGS[@]}" ps -q api 2>/dev/null || true)"
API_STATE=""
for ((i = 1; i <= 60; i++)); do
    if [[ -n "$API_ID" ]]; then
        API_STATE="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$API_ID" 2>/dev/null || true)"
        if [[ "$API_STATE" == "healthy" || "$API_STATE" == "running" ]]; then
            break
        fi
    fi
    sleep 5
done

echo ""
if [[ "$API_STATE" == "healthy" || "$API_STATE" == "running" ]]; then
    dograh_success "✓ API is $API_STATE"
else
    dograh_warn "API did not report healthy within the wait window — check: docker compose --profile remote logs -f api"
fi
echo ""
"${COMPOSE_CMD[@]}" "${PROFILE_ARGS[@]}" ps

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                 In-place Setup Complete!                     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Dashboard:  ${BLUE}${PUBLIC_BASE_URL:-http://localhost}${NC}"
echo -e "  Status:     ${BLUE}docker compose --profile remote ps${NC}"
echo -e "  Logs:       ${BLUE}docker compose --profile remote logs -f api${NC}"
echo ""
