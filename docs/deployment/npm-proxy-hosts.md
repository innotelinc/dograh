---
title: "Nginx Proxy Manager (vai-platform)"
description: "Proxy host mapping for the vai-platform (vai.innotel.us) deployment fronted by Nginx Proxy Manager"
---

# Nginx Proxy Manager — vai-platform

The vai-platform deployment (repo `innotelinc/dograh`, deployed at `vai.innotel.us`)
is fronted by **Nginx Proxy Manager (NPM)** running at `proxy.innotel.us`. NPM
terminates TLS and forwards plain HTTP to the services on the docker host.

There are **six NPM proxy hosts**. Everything else in the stack binds to
`127.0.0.1` and must never appear in NPM or the router.

## Proxy host summary

| Domain | Scheme | Forward host | Forward port | WebSockets |
|---|---|---|---|---|
| `vai.innotel.us` | http | `192.168.1.63` | **80** | On |
| `api.vai.innotel.us` | http | `192.168.1.63` | **8000** | **On (required)** |
| `ws.innotel.us` | http | `192.168.1.63` | **8000** | **On (required)** |
| `n8n.innotel.us` | http | `192.168.1.63` | **5678** | On |
| `grist.innotel.us` | http | `192.168.1.63` | **8484** | On |
| `signoz.innotel.us` | http | `192.168.1.63` | **3301** | On |

> The docker host LAN IP in this deployment is `192.168.1.63`. NPM requires an
> IP (not a hostname) as the forward host. If the box's IP ever changes, update
> these forward hosts **and** re-point the DNS A records.

## Prerequisite — DNS

Point A records for the `api`, `ws`, `n8n`, `grist` and `signoz` subdomains at
the NPM box's public IP. `vai.innotel.us` should already exist.

## Step-by-step

### 1. Web UI — `vai.innotel.us`

| Setting | Value |
|---|---|
| Domain Names | `vai.innotel.us` |
| Scheme | `http` |
| Forward Host | `192.168.1.63` |
| Forward Port | `80` |
| WebSockets Support | On |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `vai.innotel.us`, Force SSL |

No custom locations are needed — the internal nginx container (published on host
port `80`) routes `/api/v1` → api, `/` → ui, and `/voice-audio` → MinIO.

### 2. Platform API — `api.vai.innotel.us`

| Setting | Value |
|---|---|
| Domain Names | `api.vai.innotel.us` |
| Scheme | `http` |
| Forward Host | `192.168.1.63` |
| Forward Port | `8000` |
| WebSockets Support | **On (required)** — `/api/v1/telephony/ws/ari` |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `api.vai.innotel.us`, Force SSL |

Forwards straight to the api container's published port — the internal nginx is
not involved on this hostname.

### 3. ARI media WebSocket — `ws.innotel.us`

| Setting | Value |
|---|---|
| Domain Names | `ws.innotel.us` |
| Scheme | `http` |
| Forward Host | `192.168.1.63` |
| Forward Port | `8000` |
| WebSockets Support | **On (critical)** |
| Block Common Exploits | On |
| SSL | Let's Encrypt for `ws.innotel.us`, Force SSL |

This is the `wss://ws.innotel.us/api/v1/telephony/ws/ari` endpoint Asterisk dials
into for external media streaming (`deploy/asterisk/websocket_client.conf`). The
socket is HMAC-token authenticated per call (`TELEPHONY_WS_TOKEN_SECRET` +
`TELEPHONY_WS_TOKEN_ENFORCE=true`).

### 4. n8n — `n8n.innotel.us`

| Setting | Value |
|---|---|
| Domain Names | `n8n.innotel.us` |
| Scheme | `http` |
| Forward Host | `192.168.1.63` |
| Forward Port | `5678` |
| WebSockets Support | On |
| Block Common Exploits | On |
| SSL | Let's Encrypt, Force SSL |

### 5. Grist — `grist.innotel.us`

| Setting | Value |
|---|---|
| Domain Names | `grist.innotel.us` |
| Scheme | `http` |
| Forward Host | `192.168.1.63` |
| Forward Port | `8484` |
| WebSockets Support | On |
| SSL | Let's Encrypt, Force SSL |

### 6. SigNoz — `signoz.innotel.us`

| Setting | Value |
|---|---|
| Domain Names | `signoz.innotel.us` |
| Scheme | `http` |
| Forward Host | `192.168.1.63` |
| Forward Port | `3301` |
| WebSockets Support | On |
| SSL | Let's Encrypt, Force SSL |

The unified `signoz` binary serves both the UI and the query API on port
`8080`; the compose publishes that to host port `3301`, which is what NPM
forwards to. There is no separate `3300` query-service port anymore.

## Fastest path — import the JSON

The file `deploy/interview-stack/npm-proxy-hosts.json` already defines all six
hosts with the correct ports and WebSockets enabled:

1. NPM → **Admin → Import/Export → Import** → select the file.
2. If NPM already has a `vai.innotel.us` host, delete that object from the file
   (or after import) to avoid a duplicate.
3. After import, open each host → **SSL tab → Request a new SSL Certificate**.
   The file imports with `ssl_forced: false` / `certificate_id: 0` so import
   can't fail on a missing cert; enable **Force SSL** after issuing the cert.

## What NOT to map in NPM (internal-only)

These bind to `127.0.0.1` on the host and must stay out of both NPM and the
router:

| Port(s) | Service |
|---|---|
| `5432` | postgres (dograh DB) |
| `6379` | redis (dograh cache) |
| `9000`, `9001` | MinIO API + console |
| `8880` | kokoro-fastapi (TTS) |
| `8001` | speaches (STT) |
| `20128` | 9Router (LLM) |
| `4317`, `4318` | SigNoz OTel ingest (gRPC/HTTP) |
| `8888`, `8889` | otel-collector metrics |
| `19000`, `8123` | ClickHouse (native/HTTP) |
| `9093` | SigNoz alertmanager |

## Router forwards (separate from NPM)

Only these get raw forwards at the router — everything else goes through NPM:

- **80 & 443 TCP** → NPM box (all web traffic)
- **5060 UDP** → PBX (SIP signaling) — only if callers are off-LAN
- **10000–20000 UDP** → PBX (RTP media) — match your `rtp.conf`
- On the docker host firewall: **3478/5349 TCP+UDP** and **49152–49200 UDP**
  (coturn for WebRTC), plus **80 TCP to the NPM machine only**

## Related

- `deploy/interview-stack/NETWORKING.md` — full three-tier networking model
- `deploy/interview-stack/npm-proxy-hosts.json` — importable NPM host definitions
- `deploy/asterisk/README.md` — Asterisk/FreePBX ARI wiring
