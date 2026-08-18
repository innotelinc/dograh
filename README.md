# Dograh — Innotel Deployment (vai.innotel.us)

This is **innotelinc/dograh**, a fork of the open-source [Dograh](https://github.com/dograh-hq/dograh)
voice-AI platform, deployed by **Innotel** and fronted by **Nginx Proxy Manager**
(NPM) at **https://vai.innotel.us**.

The platform is wired to Innotel's **FreePBX / Asterisk** box at
**voice.innotel.us** through the built-in **Asterisk ARI** integration, so
existing PBX extensions can be answered by AI voice agents.

> Upstream project: [dograh-hq/dograh](https://github.com/dograh-hq/dograh) ·
> Docs: [docs.dograh.com](https://docs.dograh.com) · License: BSD 2-Clause

---

## Architecture

```
        Internet
           │  https://vai.innotel.us
           ▼
┌─────────────────────────────┐
│  Nginx Proxy Manager (NPM)  │   terminates TLS, forwards plain HTTP
│  (proxy.innotel.us)         │
└─────────────┬───────────────┘
              │ http://proxy.innotel.us:80
              ▼
┌─────────────────────────────┐
│  internal nginx (Docker)    │   routes /api/v1 → api, / → ui, /voice-audio → minio
└──────┬──────────┬───────────┘
       ▼          ▼
   api:8000    ui:3010        minio:9000 (private), postgres, redis, coturn
       │
       │ ARI REST (http://192.168.1.9:8088, internal LAN) + external media WebSocket
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

Create a **Proxy Host** on your NPM machine:

| Setting | Value |
|---------|-------|
| Domain Names | `vai.innotel.us` |
| Scheme | `http` |
| Forward Hostname / IP | `proxy.innotel.us` |
| Forward Port | `80` |
| WebSockets Support | **On** |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `vai.innotel.us` |

No custom locations are needed — the internal nginx does all the routing.

### Firewall

Open on this server:

- **TCP 80** — to the NPM machine only (internal nginx).
- **UDP/TCP 3478, 5349** and **UDP 49152–49200** — coturn (WebRTC browser
  calls / dashboard "Web Call" testing).

On the Asterisk box (`voice.innotel.us`):

- **TCP 8088** — to this server (`proxy.innotel.us`) only, for ARI.

---

## In-place setup (existing server)

Already have this repo checked out on a server with Docker installed and `.env`
configured? `scripts/setup_inplace.sh` brings the stack up in one command — it
never prompts for IPs/secrets and never overwrites `.env`:

```bash
./scripts/setup_inplace.sh              # build from source + start (first build 10-20 min)
./scripts/setup_inplace.sh --no-build   # pull prebuilt images instead
./scripts/setup_inplace.sh --preflight-only   # validate config only, no changes
```

What it does:

1. Initializes the `pipecat` submodule (needed to build the api image).
2. Generates self-signed certs in `certs/` if missing (required by `dograh-init`).
3. Validates the rendered nginx/coturn config against `.env`.
4. Syncs the Postgres role password with `.env` (idempotent).
5. Builds and starts the stack, then waits for the API to come up.

This is the in-place counterpart to `scripts/setup_remote.sh`, which targets
fresh/remote installs and refuses to run when `.env` already exists.

---

## Environment (`.env`)

All secrets live in `.env` (gitignored — never commit it). Required keys:

| Key | Purpose |
|-----|---------|
| `ENVIRONMENT` | `production` |
| `SERVER_IP` | Public IPv4 of the Docker host — set in the gitignored `.env` only (real IP never committed) |
| `PUBLIC_HOST` | `vai.innotel.us` |
| `PUBLIC_BASE_URL` | `https://vai.innotel.us` |
| `BACKEND_API_ENDPOINT` | `https://vai.innotel.us` |
| `MINIO_PUBLIC_ENDPOINT` | `https://vai.innotel.us` |
| `TURN_HOST` | `vai.innotel.us` |
| `TURN_SECRET` | Random secret for TURN REST credentials |
| `OSS_JWT_SECRET` | Random secret signing JWT auth tokens |
| `POSTGRES_PASSWORD` | PostgreSQL password (baked into the volume on first init) |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | MinIO credentials |
| `REDIS_PASSWORD` | Redis password |
| `FASTAPI_WORKERS` | uvicorn worker count (4 on this server) |
| `ENABLE_TELEMETRY` | `false` for this deployment |

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
   `http://192.168.1.9:8088` (the PBX's internal LAN address), then register each extension as a phone
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
