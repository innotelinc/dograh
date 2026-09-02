# Dograh — Innotel Deployment (vai.innotel.us)

This is **innotelinc/dograh**, a fork of the open-source [Dograh](https://github.com/dograh-hq/dograh)
voice-AI platform, deployed by **Innotel** and fronted by **Nginx Proxy Manager**
(NPM): the web UI at **https://vai.innotel.us**, and the platform API at
**https://api.vai.innotel.us** (used by the UI and public transcript/recording
download links), the Asterisk ARI REST proxy at **https://ari.voice.innotel.us**,
and the external-media WebSocket at **wss://ws.vai.innotel.us**.

The platform is wired to Innotel's **FreePBX / Asterisk** box at
**voice.innotel.us** through the built-in **Asterisk ARI** integration, so
existing PBX extensions can be answered by AI voice agents.

> Upstream project: [dograh-hq/dograh](https://github.com/dograh-hq/dograh) ·
> Docs: [docs.dograh.com](https://docs.dograh.com) · License: BSD 2-Clause

---

## Architecture

```
        Internet
           │  https://vai.innotel.us   https://api.vai.innotel.us
           │                            https://ari.voice.innotel.us
           │                            wss://ws.vai.innotel.us
           ▼                               ▼
┌──────────────────────────────────────────────────────┐
│             Nginx Proxy Manager (NPM)                │
│             (proxy.innotel.us)                       │
│  vai.innotel.us → internal nginx :80                 │
│  api.vai.innotel.us → api container :8000 (WS on)    │
│  ari.voice.innotel.us → PBX 192.168.1.9:8088           │
│  ws.vai.innotel.us → api container :8000 (WS on)     │
└─────────────┬────────────────────────────┬───────────┘
              │ http://proxy.innotel.us:80 │ http://<docker-host>:8000
              ▼                            ▼
┌─────────────────────────────┐   ┌──────────────────┐
│  internal nginx (Docker)    │   │ api (uvicorn)     │
│  routes /api/v1 → api,      │   │ /api/v1/* REST    │
│  / → ui, /voice-audio→minio │   │ /ws/ari media WS  │
└──────┬──────────┬───────────┘   └──────────────────┘
       ▼          ▼
   api:8000    ui:3010        minio:9000 (private), postgres, redis, coturn
       │
       │ ARI REST via https://ari.voice.innotel.us + external media WebSocket via wss://ws.vai.innotel.us
       ▼
┌─────────────────────────────┐
│  FreePBX / Asterisk         │   voice.innotel.us
└─────────────────────────────┘
```

Key differences from the upstream remote deployment:  - **TLS is terminated by NPM**, not by the bundled nginx container. The internal
  nginx listens on plain HTTP and is published on host port **80** only.
- The **cloudflared** quick-tunnel is disabled (not needed behind NPM).
- Images are **built from this fork's source** rather than pulled from a
  registry.

---

## Deployment layout (this server)

| Path | Purpose |
|------|---------|
| `.env` | All secrets + canonical public-host settings (**gitignored**) |
| `docker-compose.yaml` | Base services (postgres, redis, minio, api, ui) |
| `docker-compose.override.yaml` | Build-from-source, NPM port mapping, cloudflared disabled |
| `deploy/templates/nginx.remote.conf.template` | HTTP-only nginx config for NPM fronting |
| `deploy/asterisk/` | Config files for the FreePBX/Asterisk box |
| `certs/` | Self-signed certs required by `dograh-init` validation (**gitignored**) |

---

## Quick start (fresh server)

On the server (this repo already checked out):

```bash
# 1. Initialize the pipecat submodule (required to build the api image)
git submodule update --init --recursive

# 2. Create .env with secrets (see "Environment" below)
cp .env.example .env   # then edit secrets

# 3. Generate the self-signed certs dograh-init validates
mkdir -p certs
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout certs/local.key -out certs/local.crt -days 365 \
  -subj "/CN=vai.innotel.us"

# 4. Build images and start the stack (first build takes 10-20 min)
./remote_up.sh --build
```

### Nginx Proxy Manager

Create **four Proxy Hosts** on your NPM machine:

**1. Web UI**

| Setting | Value |
|---------|-------|
| Domain Names | `vai.innotel.us` |
| Scheme | `http` |
| Forward Hostname / IP | `vai.innotel.us` |
| Forward Port | `80` |
| WebSockets Support | **On** |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `vai.innotel.us` |

No custom locations are needed — the internal nginx does all the routing.

**2. Platform API**

| Setting | Value |
|---------|-------|
| Domain Names | `api.vai.innotel.us` |
| Scheme | `http` |
| Forward Hostname / IP | `<docker-host LAN IP>` (e.g. `192.168.1.63`) |
| Forward Port | `8000` |
| WebSockets Support | **On** (required for `/api/v1/telephony/ws/ari`) |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `api.vai.innotel.us` |

Forwards straight to the api container's published port — the internal nginx
is not involved on this hostname.

**3. Asterisk ARI REST**

| Setting | Value |
|---------|-------|
| Domain Names | `ari.voice.innotel.us` |
| Scheme | `http` |
| Forward Hostname / IP | `192.168.1.9` |
| Forward Port | `8088` |
| WebSockets Support | **On** (required for ARI events) |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `ari.voice.innotel.us` |

Configure Dograh's ARI Endpoint URL as `https://ari.voice.innotel.us`. NPM
forwards this host to the PBX; do not expose PBX port 8088 directly at the router.

**4. Asterisk external-media WebSocket**

| Setting | Value |
|---------|-------|
| Domain Names | `ws.vai.innotel.us` |
| Scheme | `http` |
| Forward Hostname / IP | `<docker-host LAN IP>` (e.g. `192.168.1.63`) |
| Forward Port | `8000` |
| WebSockets Support | **On** (required) |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `ws.vai.innotel.us` |

Asterisk dials `wss://ws.vai.innotel.us/api/v1/telephony/ws/ari` outbound.

### Firewall

Open on this server:

- **TCP 80** — to the NPM machine only (internal nginx).
- **UDP/TCP 3478, 5349** and **UDP 49152–49200** — coturn (WebRTC browser
  calls / dashboard "Web Call" testing).

On the Asterisk box (`voice.innotel.us`):

- **TCP 8088** — to this server (`proxy.innotel.us`) only, for ARI.

---

## In-place setup (on an existing FreePBX/Asterisk server)

Already run FreePBX/Asterisk on a server and want Dograh on the same box?
`scripts/setup_inplace.sh` installs the Dograh stack **on top of your PBX** — it
wires the Asterisk side (ARI user, HTTP/ARI server, external-media websocket,
Stasis dialplan entry) and builds/starts the Docker stack:

```bash
sudo ./scripts/setup_inplace.sh              # build from source + start (first build 10-20 min)
sudo ./scripts/setup_inplace.sh --no-build   # pull prebuilt images instead
sudo ./scripts/setup_inplace.sh --preflight-only   # validate only, no changes
```

What it does:

1. Detects FreePBX vs. vanilla Asterisk and checks the required modules
   (`res_ari`, `chan_websocket`, `res_websocket_client`).
2. Backs up and wires `/etc/asterisk`: adds the `dograh` ARI user to
   `ari.conf`, enables the HTTP/ARI server on 8088 in `http.conf`, writes
   `websocket_client.conf` for external media, and adds the `Stasis(dograh)`
   dialplan entry (`extensions_custom.conf` on FreePBX, `extensions.conf` on
   vanilla), then reloads Asterisk.
3. Creates `.env` with fresh secrets (never overwrites an existing `.env`),
   generates self-signed certs, and (in build mode) a
   `docker-compose.override.yaml`.
4. Builds and starts the stack, waits for the API, and prints the telephony
   values to enter in the dashboard (ARI endpoint, app name, password) plus
   the one-time FreePBX GUI steps for the inbound route.

Your existing PBX extensions and routes are untouched beyond the added dograh
ARI user and Stasis entry. Skip the Asterisk changes with `--skip-asterisk`.
For an existing Dograh install that just needs rebuilding/restarting, use
`./remote_up.sh` instead.

## Auto-start on boot (systemd)

`deploy/systemd/dograh-stack.service` starts the stack (with the `remote`
profile, so nginx + coturn come up too) after a reboot:

```bash
sudo cp deploy/systemd/dograh-stack.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable dograh-stack.service
```

The unit waits for the Docker socket, runs `docker compose --profile remote
up -d`, and retries on failure. Private-IP installs that need the Cloudflare
tunnel should add `--profile tunnel` to `ExecStart`. To stop the stack:
`sudo systemctl stop dograh-stack.service` (this also runs on shutdown).

---

## Environment (`.env`)

All secrets live in `.env` (gitignored — never commit it). Required keys:

| Key | Purpose |
|-----|---------|
| `ENVIRONMENT` | `production` |
| `SERVER_IP` | Public IPv4 of the Docker host — set in the gitignored `.env` only (real IP never committed) |
| `PUBLIC_HOST` | `vai.innotel.us` |
| `PUBLIC_BASE_URL` | `https://vai.innotel.us` (UI origin) |
| `BACKEND_API_ENDPOINT` | `https://api.vai.innotel.us` (API origin — media WS, download links) |
| `MINIO_PUBLIC_ENDPOINT` | `https://vai.innotel.us` (served via internal nginx `/voice-audio`) |
| `TURN_HOST` | `vai.innotel.us` |
| `TURN_SECRET` | Random secret for TURN REST credentials |
| `OSS_JWT_SECRET` | Random secret signing JWT auth tokens |
| `TELEPHONY_WS_TOKEN_SECRET` | Random secret HMAC-signing each media-WebSocket URL (set — the socket is public via `ws.vai.innotel.us`) |
| `TELEPHONY_WS_TOKEN_ENFORCE` | `true` — media-WS connections without a valid per-call token are rejected (close `4401`) |
| `POSTGRES_PASSWORD` | PostgreSQL password (baked into the volume on first init) |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | MinIO credentials |
| `REDIS_PASSWORD` | Redis password |
| `FASTAPI_WORKERS` | uvicorn worker count (4 on this server) |
| `ENABLE_TELEMETRY` | `false` for this deployment |
| `ICE_INBOUND_POLICY` | `none` here — accepts private-IP ICE candidates so dashboard "Web Call" works from browsers on the same LAN/NAT as the server (hairpin NAT is unreliable on this router). Omit for pure public-internet clients. |

Generate new secrets with:

```bash
openssl rand -hex 32
```

> ⚠️ `POSTGRES_PASSWORD` cannot be changed after first boot — it is baked into
> the postgres data volume. See `docs/deployment/update.mdx` for upgrades.

---

## Wiring FreePBX / Asterisk (voice.innotel.us)

Ready-to-use config files are in **`deploy/asterisk/`** with a full walkthrough
in [`deploy/asterisk/README.md`](deploy/asterisk/README.md). In short:

1. Copy `ari.conf`, `http.conf`, `websocket_client.conf` to `/etc/asterisk/` on
   the PBX and merge `extensions.conf` into your dialplan.
2. Set the ARI password in `ari.conf`.
3. Reload Asterisk modules.
4. In Dograh (`https://vai.innotel.us/telephony-configurations`), add an
   **Asterisk ARI** configuration pointing at
   `https://ari.voice.innotel.us`, then register each extension as a phone
   number with an inbound workflow.

---

## Operations

```bash
# Status
docker compose --profile remote ps

# Logs
docker compose --profile remote logs -f api
docker compose --profile remote logs -f ui

# Restart after a code change (rebuild + recreate)
./remote_up.sh --build

# Full clean rebuild
docker compose --profile remote build --no-cache api ui
docker compose --profile remote up -d
```

Backups: the Docker volumes `postgres_data`, `redis_data`, and `minio-data`
hold all state. Snapshot them for disaster recovery.

---

## About

See [ABOUT.md](ABOUT.md) for the story behind this deployment.
