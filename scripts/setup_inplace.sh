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
SKIP_ASTERISK=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Dograh in-place setup — install Dograh on top of an already-running
FreePBX/Asterisk server (same box).

The script assumes Asterisk (with res_ari / chan_websocket /
res_websocket_client) is already installed and running. It:

  1. Detects FreePBX vs. vanilla Asterisk and verifies the required modules.
  2. Wires the Asterisk side: creates the `dograh` ARI user in ari.conf,
     enables the HTTP/ARI server in http.conf, writes websocket_client.conf
     for external media, and installs the Stasis(dograh) dialplan entry
     (extensions_custom.conf on FreePBX, extensions.conf on vanilla).
  3. Generates .env with fresh secrets (never overwrites an existing .env),
     self-signed certs, and the docker-compose.override.yaml build override.
  4. Builds and starts the Dograh stack, then waits for the API.

It never touches your existing PBX extensions or routes beyond adding the
dograh ARI user and the Stasis entry, and it never overwrites .env.

Usage: setup_inplace.sh [options]

Options:
  --no-build | --pull    Pull images instead of building from source
  --preflight-only       Validate the environment and config, exit without changes
  --skip-submodule       Skip git submodule init (already initialized)
  --skip-certs           Skip certificate generation (already present)
  --skip-asterisk        Skip all /etc/asterisk changes (ARI/dialplan wiring)
  -y, --yes              Non-interactive: use defaults, never prompt
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
        --skip-asterisk)
            SKIP_ASTERISK=1
            ;;
        -y|--yes)
            ASSUME_YES=1
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
echo "║            Dograh In-place Setup (on FreePBX/Asterisk)       ║"
echo "║       Install the voice-AI stack next to your PBX            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

dograh_info "Project directory: $DOGRAH_DEPLOY_PROJECT_DIR"

# ---------------------------------------------------------------------------
# Preflight 0: this script is for a box that already runs Asterisk.
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || dograh_fail "docker not found. Install Docker before running this script."
[[ -f docker-compose.yaml ]] || dograh_fail "docker-compose.yaml not found in $DOGRAH_DEPLOY_PROJECT_DIR"

ASTERISK_BIN="$(command -v asterisk || true)"
ASTERISK_ETC="/etc/asterisk"
if [[ -z "$ASTERISK_BIN" || ! -d "$ASTERISK_ETC" ]]; then
    dograh_fail "Asterisk not found on this host (/etc/asterisk missing or no asterisk binary)."
    dograh_fail "This script installs Dograh on top of an existing FreePBX/Asterisk server — run it there."
fi
if ! "$ASTERISK_BIN" -rx "core show version" >/dev/null 2>&1; then
    dograh_fail "Asterisk is installed but not running. Start it first (e.g. systemctl start asterisk)."
fi
dograh_success "✓ Asterisk detected: $("$ASTERISK_BIN" -rx 'core show version' 2>/dev/null | head -1)"

# FreePBX vs vanilla Asterisk: fwconsole is the FreePBX admin CLI.
FREEPBX=0
if command -v fwconsole >/dev/null 2>&1 || [[ -f /etc/freepbx.conf ]]; then
    FREEPBX=1
fi

# Required modules — warn, don't fail: some distros name them differently.
if [[ "$SKIP_ASTERISK" == "1" ]]; then
    dograh_info "Skipping Asterisk module checks (--skip-asterisk)"
else
    for mod in res_ari chan_websocket res_websocket_client; do
        if ! "$ASTERISK_BIN" -rx "module show like ${mod%.so}" 2>/dev/null | grep -qi "$mod"; then
            dograh_warn "Module $mod does not appear loaded — install it (Asterisk 20 LTS+ recommended) before wiring ARI."
        fi
    done
fi

# ---------------------------------------------------------------------------
# Preflight 1: port conflicts. FreePBX's web GUI normally owns 80/443; the
# Dograh stack binds 80 (nginx), 3478/5349/49152-49200 (coturn) and 8000/3010.
# ---------------------------------------------------------------------------
check_listener() {
    local port=$1
    (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print $4}' | grep -qE "(:|\.)$port\$"
}

CONFLICTS=0
for port in 80 3478 5349 49152 8000 3010; do
    if check_listener "$port"; then
        dograh_warn "Port $port is already in use — Dograh needs it (check the stack ports in docker-compose.yaml)."
        CONFLICTS=1
    fi
done
if [[ "$CONFLICTS" == "1" && "$ASSUME_YES" == "0" && -t 0 ]]; then
    echo ""
    read -p "Continue anyway? [y/N]: " continue_anyway
    [[ "$continue_anyway" =~ ^[Yy]$ ]] || dograh_fail "Aborted — free the ports above and re-run."
fi

# ---------------------------------------------------------------------------
# [1/6] Environment: reuse .env if present, else create with fresh secrets.
# Never overwrites an existing .env (keeps sessions and TURN auth stable).
# ---------------------------------------------------------------------------
if [[ -f .env ]]; then
    dograh_info "[1/6] Reusing existing .env"
    dograh_load_env_file .env
else
    dograh_info "[1/6] Creating .env with fresh secrets..."

    if [[ -n "${PUBLIC_HOST:-}" ]]; then
        PUBLIC_HOST_IN="$PUBLIC_HOST"
    elif [[ "$ASSUME_YES" == "1" || ! -t 0 ]]; then
        PUBLIC_HOST_IN="$(hostname -f 2>/dev/null || hostname)"
        dograh_warn "No TTY — defaulting PUBLIC_HOST to '$PUBLIC_HOST_IN' (set PUBLIC_HOST=... to override)."
    else
        echo ""
        echo -e "${YELLOW}Public hostname this install will be served from (e.g. vai.innotel.us):${NC}"
        read -p "> " PUBLIC_HOST_IN
    fi
    [[ -n "$PUBLIC_HOST_IN" ]] || dograh_fail "PUBLIC_HOST cannot be empty"

    if [[ -n "${SERVER_IP:-}" ]]; then
        SERVER_IP_IN="$SERVER_IP"
    elif [[ "$ASSUME_YES" == "1" || ! -t 0 ]]; then
        SERVER_IP_IN="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}')"
        dograh_warn "No TTY — defaulting SERVER_IP to '$SERVER_IP_IN' (set SERVER_IP=... to override)."
    else
        echo ""
        echo -e "${YELLOW}Public IP of this server (used by the TURN server; press Enter to auto-detect):${NC}"
        read -p "> " SERVER_IP_IN
        if [[ -z "$SERVER_IP_IN" ]]; then
            SERVER_IP_IN="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}')"
            dograh_info "Detected IP: $SERVER_IP_IN"
        fi
    fi
    dograh_is_ipv4 "$SERVER_IP_IN" || dograh_fail "SERVER_IP must be an IPv4 address (got: '$SERVER_IP_IN')"

    OSS_JWT_SECRET=$(openssl rand -hex 32)
    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    REDIS_PASSWORD=$(openssl rand -hex 32)
    MINIO_ROOT_USER="dograh$(openssl rand -hex 6)"
    MINIO_ROOT_PASSWORD=$(openssl rand -hex 32)
    TURN_SECRET=$(openssl rand -hex 32)

    cat > .env << ENV_EOF
# Generated by setup_inplace.sh — install on top of an existing FreePBX/Asterisk
# server. All secrets live here; never commit this file.
ENVIRONMENT=production

# Canonical public host/base URL for this install. SERVER_IP stays the raw IP
# (coturn external-ip and validation need it); PUBLIC_HOST is the hostname.
SERVER_IP=$SERVER_IP_IN
PUBLIC_HOST=$PUBLIC_HOST_IN
PUBLIC_BASE_URL=https://$PUBLIC_HOST_IN

# TURN Server Configuration (time-limited credentials via TURN REST API)
ENABLE_COTURN=true
TURN_SECRET=$TURN_SECRET
FORCE_TURN_RELAY=false

# JWT secret for OSS authentication
OSS_JWT_SECRET=$OSS_JWT_SECRET

# PostgreSQL password. Used by the postgres container on first init and by the
# API's DATABASE_URL. Do not change after the first start.
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# Redis password. Used by the redis container's --requirepass and the API's
# REDIS_URL. Unlike postgres, this is not baked into a volume and can be
# rotated by updating .env and recreating the redis container.
REDIS_PASSWORD=$REDIS_PASSWORD

# MinIO root credentials. Used by the MinIO container and the API's
# MINIO_ACCESS_KEY / MINIO_SECRET_KEY.
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD

# Telemetry (set to false to disable)
ENABLE_TELEMETRY=true

# Number of uvicorn worker processes; nginx load-balances across them
FASTAPI_WORKERS=2
ENV_EOF
    dograh_success "✓ .env created"
fi

# ARI password for the [dograh] user in /etc/asterisk/ari.conf. Generate on
# first run and persist to .env so re-runs stay in sync.
if [[ -z "${ARI_PASSWORD:-}" ]]; then
    ARI_PASSWORD="$(openssl rand -base64 18 | tr '+/' '-_')"
    dograh_set_env_key .env ARI_PASSWORD "$ARI_PASSWORD"
    dograh_load_env_file .env
    dograh_success "✓ Generated ARI password (also stored as ARI_PASSWORD in .env)"
fi

# ---------------------------------------------------------------------------
# [2/6] Certificates (dograh-init requires certs/local.crt + local.key)
# ---------------------------------------------------------------------------
if [[ "$SKIP_CERTS" == "1" ]]; then
    dograh_info "[2/6] Skipping certificate generation"
elif [[ -f certs/local.crt && -f certs/local.key ]]; then
    dograh_info "[2/6] Certificates already present"
else
    dograh_info "[2/6] Generating self-signed certificate..."
    mkdir -p certs
    CN="${PUBLIC_HOST:-localhost}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout certs/local.key -out certs/local.crt -days 365 \
        -subj "/CN=$CN"
    chmod 644 certs/local.crt certs/local.key
    dograh_success "✓ Certificate generated (CN=$CN)"
fi

# ---------------------------------------------------------------------------
# [3/6] Asterisk wiring (ARI user, HTTP server, media websocket, dialplan)
# ---------------------------------------------------------------------------
if [[ "$SKIP_ASTERISK" == "1" ]]; then
    dograh_info "[3/6] Skipping Asterisk configuration (--skip-asterisk)"
else
    dograh_info "[3/6] Wiring Asterisk ARI and dialplan..."

    # Back up anything we touch, then make changes idempotently.
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="/root/dograh-asterisk-backup-$TIMESTAMP"
    mkdir -p "$BACKUP_DIR"
    for f in ari.conf http.conf websocket_client.conf extensions_custom.conf extensions.conf; do
        [[ -f "$ASTERISK_ETC/$f" ]] && cp -a "$ASTERISK_ETC/$f" "$BACKUP_DIR/$f"
    done
    dograh_success "✓ Backed up Asterisk configs to $BACKUP_DIR"

    # --- ari.conf: ensure [general] enabled and a [dograh] user ---
    if ! grep -q '^\s*\[dograh\]' "$ASTERISK_ETC/ari.conf" 2>/dev/null; then
        cat >> "$ASTERISK_ETC/ari.conf" << ARI_EOF

; --- Dograh voice AI (added by setup_inplace.sh) ---
[general]
enabled = yes

[dograh]
type = user
read_only = no
password = $ARI_PASSWORD
ARI_EOF
        dograh_success "✓ ari.conf: added [dograh] user (password in .env as ARI_PASSWORD)"
    else
        dograh_info "ari.conf: [dograh] section already present — leaving as-is (update the password in .env if needed)"
    fi

    # --- http.conf: enable the HTTP/ARI server on 8088 ---
    if [[ ! -f "$ASTERISK_ETC/http.conf" ]] || ! grep -q '^\s*\[general\]' "$ASTERISK_ETC/http.conf"; then
        cat >> "$ASTERISK_ETC/http.conf" << HTTP_EOF

; --- Dograh voice AI (added by setup_inplace.sh) ---
[general]
enabled = yes
bindaddr = 0.0.0.0
bindport = 8088
HTTP_EOF
        dograh_success "✓ http.conf: enabled HTTP/ARI server on 8088"
    else
        dograh_info "http.conf: [general] present — verifying bindport 8088"
        if ! grep -qE '^\s*bindport\s*=\s*8088' "$ASTERISK_ETC/http.conf"; then
            dograh_warn "http.conf exists but does not bind 8088 — Dograh ARI needs port 8088 (edit http.conf and 'core reload')."
        fi
    fi

    # --- websocket_client.conf: external media stream to Dograh ---
    cat > "$ASTERISK_ETC/websocket_client.conf" << WS_EOF
; External media WebSocket client for Dograh (added by setup_inplace.sh).
; The section name [dograh] is the "WebSocket Client Name" in Dograh at
; /telephony-configurations.
[dograh]
type = websocket_client
uri = wss://${PUBLIC_HOST}/api/v1/telephony/ws/ari
protocols = media
tls_enabled = yes
ca_list_file = /etc/ssl/certs/ca-certificates.crt
WS_EOF
    dograh_success "✓ websocket_client.conf written (streams to wss://${PUBLIC_HOST}/api/v1/telephony/ws/ari)"

    # --- Dialplan: route calls into Stasis(dograh) ---
    # FreePBX regenerates extensions.conf on every Apply Config, so use
    # extensions_custom.conf (preserved by FreePBX) for the custom context.
    if [[ "$FREEPBX" == "1" ]]; then
        CONTEXT_FILE="$ASTERISK_ETC/extensions_custom.conf"
        if ! grep -q '^\s*\[dograh-inbound\]' "$CONTEXT_FILE" 2>/dev/null; then
            cat >> "$CONTEXT_FILE" << DIAL_EOF

; --- Dograh voice AI (added by setup_inplace.sh) ---
; Context used by inbound routes / extensions pointing at Dograh.
; Create the route in the FreePBX GUI: Admin -> Custom Destinations ->
; Add Destination -> "Dograh Voice Agent" -> dograh-inbound,8000,1
[dograh-inbound]
exten => 8000,1,NoOp(Dograh voice agent inbound)
 same => n,Stasis(dograh)
 same => n,Hangup()
DIAL_EOF
            dograh_success "✓ extensions_custom.conf: added [dograh-inbound] Stasis context"
        else
            dograh_info "extensions_custom.conf: [dograh-inbound] already present — leaving as-is"
        fi
        # Custom Destinations are GUI-managed in FreePBX; the route can't be
        # created safely from the CLI, so point the user at the GUI.
        dograh_warn "FreePBX detected — create the inbound route in the GUI:"
        dograh_warn "  Admin -> Custom Destinations -> Add -> 'Dograh Voice Agent' -> dograh-inbound,8000,1"
        dograh_warn "  Connectivity -> Inbound Routes -> Add -> DID 8000 -> Destination: Dograh Voice Agent"
    else
        CONTEXT_FILE="$ASTERISK_ETC/extensions.conf"
        if ! grep -q 'dograh' "$CONTEXT_FILE" 2>/dev/null; then
            cat >> "$CONTEXT_FILE" << DIAL_EOF

; --- Dograh voice AI (added by setup_inplace.sh) ---
[from-external]
exten => 8000,1,NoOp(Incoming call to 8000 for Dograh)
 same => n,Stasis(dograh)
 same => n,Hangup()
DIAL_EOF
            dograh_success "✓ extensions.conf: added [from-external] Stasis entry for 8000"
        else
            dograh_info "extensions.conf: dograh entries already present — leaving as-is"
        fi
    fi

    # --- Reload Asterisk so the new ARI user + dialplan are live ---
    "$ASTERISK_BIN" -rx "ari reload" >/dev/null 2>&1 || true
    "$ASTERISK_BIN" -rx "dialplan reload" >/dev/null 2>&1 || true
    "$ASTERISK_BIN" -rx "module reload res_websocket_client.so" >/dev/null 2>&1 || true
    "$ASTERISK_BIN" -rx "core reload" >/dev/null 2>&1 || true
    dograh_success "✓ Asterisk reloaded (ari/dialplan/websocket)"
fi

# ---------------------------------------------------------------------------
# [4/6] pipecat submodule (required to build the api image from source)
# ---------------------------------------------------------------------------
if [[ "$SKIP_SUBMODULE" == "1" ]]; then
    dograh_info "[4/6] Skipping submodule init"
elif [[ ! -f .gitmodules ]]; then
    dograh_info "[4/6] No submodules configured — skipping"
elif [[ -d pipecat/.git ]] || [[ -n "$(ls -A pipecat 2>/dev/null)" ]]; then
    dograh_info "[4/6] pipecat submodule already initialized"
else
    dograh_info "[4/6] Initializing pipecat submodule..."
    git submodule update --init --recursive
    dograh_success "✓ pipecat submodule initialized"
fi

# ---------------------------------------------------------------------------
# [5/6] Validate the rendered remote config
# ---------------------------------------------------------------------------
dograh_info "[5/6] Validating remote init configuration..."
dograh_prepare_remote_install "$DOGRAH_DEPLOY_PROJECT_DIR"
docker compose config -q
dograh_success "✓ Configuration validated"

if [[ "$VALIDATE_ONLY" == "1" ]]; then
    echo ""
    dograh_success "✓ Preflight passed — no changes made"
    exit 0
fi

# Build override for source builds (mirrors setup_remote.sh)
if [[ "$MODE" == "build" && ! -f docker-compose.override.yaml ]]; then
    cat > docker-compose.override.yaml << 'OVERRIDE_EOF'
# Auto-generated by setup_inplace.sh (build mode).
# Builds api and ui from local source instead of pulling prebuilt images.
# Remove this file to revert to pulling prebuilt images.
services:
  api:
    build:
      context: .
      dockerfile: api/Dockerfile
    image: dograh-local/dograh-api:local
    pull_policy: never

  ui:
    build:
      context: .
      dockerfile: ui/Dockerfile
    image: dograh-local/dograh-ui:local
    pull_policy: never
OVERRIDE_EOF
    dograh_success "✓ docker-compose.override.yaml created (build mode)"
fi

# ---------------------------------------------------------------------------
# [6/6] Start the stack
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
else
    COMPOSE_CMD=(sudo docker compose)
fi

# Reconcile the Postgres role password with .env before starting the API.
dograh_sync_postgres_password "$DOGRAH_DEPLOY_PROJECT_DIR" "${COMPOSE_CMD[@]}"

# When SERVER_IP is a private/reserved address the host has no public IP, so
# start the cloudflared service (tunnel profile) to make webhooks reachable.
PROFILE_ARGS=(--profile remote)
if dograh_is_local_ipv4 "${SERVER_IP:-}"; then
    PROFILE_ARGS+=(--profile tunnel)
fi

if [[ "$MODE" == "build" ]]; then
    dograh_info "[6/6] Building images and starting the stack (first build takes 10-20 min)..."
    "${COMPOSE_CMD[@]}" "${PROFILE_ARGS[@]}" up -d --build --force-recreate
else
    dograh_info "[6/6] Pulling images and starting the stack..."
    "${COMPOSE_CMD[@]}" "${PROFILE_ARGS[@]}" up -d --pull always --force-recreate
fi

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
dograh_info "Waiting for the API to come up..."
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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}')"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Dograh In-place Setup Complete!                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Dashboard:  ${BLUE}${PUBLIC_BASE_URL:-https://$PUBLIC_HOST}${NC}"
echo -e "  Status:     ${BLUE}docker compose --profile remote ps${NC}"
echo -e "  Logs:       ${BLUE}docker compose --profile remote logs -f api${NC}"
echo ""
echo -e "${YELLOW}Next — configure Dograh's telephony settings:${NC}"
echo ""
echo -e "  Telephony Configurations -> Add -> Asterisk ARI:"
echo -e "    ARI Endpoint URL:   ${BLUE}http://${LAN_IP:-<this-server-lan-ip>}:8088${NC}"
echo -e "    Stasis App Name:    ${BLUE}dograh${NC}"
echo -e "    App Password:       ${BLUE}$ARI_PASSWORD${NC}  (also in .env as ARI_PASSWORD)"
echo -e "    WebSocket Client:   ${BLUE}dograh${NC}"
echo ""
if [[ "$FREEPBX" == "1" ]]; then
    echo -e "${YELLOW}FreePBX inbound route (one-time, in the FreePBX GUI):${NC}"
    echo -e "  Admin -> Custom Destinations -> Add -> 'Dograh Voice Agent' -> dograh-inbound,8000,1"
    echo -e "  Connectivity -> Inbound Routes -> Add -> DID 8000 -> Destination: Dograh Voice Agent"
    echo ""
fi
echo -e "  Then open the config in Dograh, add extension(s) (e.g. ${BLUE}8000${NC}) as"
echo -e "  phone numbers with an Inbound workflow, and dial ${BLUE}8000${NC} from any phone."
echo ""
if [[ "$SKIP_ASTERISK" == "1" ]]; then
    echo -e "  (Asterisk config not touched — --skip-asterisk)"
else
    echo -e "${YELLOW}Files touched on this host:${NC}"
    echo -e "  - $ASTERISK_ETC/ari.conf, http.conf, websocket_client.conf, ${CONTEXT_FILE:-dialplan}"
    echo -e "  - backups of the originals: ${BLUE}$BACKUP_DIR${NC}"
fi
echo ""
