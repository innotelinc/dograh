# Networking & port map (NPM + router)

Three tiers. Rule of thumb: **only the PBX (SIP/RTP) and NPM (80/443) ever get
raw router forwards; everything else is either reverse-proxied behind NPM or
stays LAN/docker-internal.**

Host LAN IP for this deployment: `192.168.1.63` (PBX and dograh on the same
LAN — if the PBX is a separate box, substitute its IP).

## Tier 1 — Forward at the router (raw TCP/UDP)

**Only for inbound phone calls.** If callers are all on the same LAN
(softphones/SIP handsets), you don't need ANY of these — skip to Tier 2.

| Port(s)          | Proto | Target      | Purpose                          |
|------------------|-------|-------------|----------------------------------|
| 5060             | UDP   | PBX (Asterisk) | SIP signaling                |
| 5061             | TCP   | PBX         | SIP-TLS (only if you enable it)  |
| 10000–20000      | UDP   | PBX         | RTP media (match your rtp.conf)  |
| 80, 443          | TCP   | NPM host    | All web UIs via reverse proxy    |

**SIP NAT gotcha:** forwarding 5060 alone gives one-way audio. On the PBX set
`externip=<your public IP>` + `localnet=192.168.1.0/24` (and the same externip
in `rtp.conf`), or on FreePBX use the SIP Settings NAT GUI (e.g. STUN or static
externip). Skip this only if all calls stay on the LAN.

## Tier 2 — Reverse-proxy via NPM (NO raw forwarding)

Forward only 80/443 → NPM (Tier 1), then create proxy hosts in NPM. Each entry
terminates TLS; NPM reaches the service on the LAN/docker network.

**Ready-to-import file: `npm-proxy-hosts.json`** (NPM → Admin → Import/Export →
Import → select the file). It defines seven hosts:

| NPM proxy host       | Target (LAN)              | Notes                             |
|----------------------|---------------------------|-----------------------------------|
| `vai.innotel.us`     | `http://192.168.1.63:80`  | Web UI (internal nginx → ui:3010) |
| `api.vai.innotel.us` | `http://192.168.1.63:8000`| API — WebSockets **on**           |
| `ari.voice.innotel.us` | `http://192.168.1.9:8088` | Asterisk ARI REST + events WS     |
| `ws.vai.innotel.us`  | `http://192.168.1.63:8000`| ARI media WebSocket — WS **on**   |
| `n8n.vai.innotel.us`     | `http://192.168.1.63:5678`| Workflow editor + webhook receive |
| `grist.vai.innotel.us` | `http://192.168.1.63:8484`| Scores/transcripts dashboard      |
| `signoz.vai.innotel.us` | `http://192.168.1.63:3301`| Traces + latency dashboards       |

Import steps:
1. Point DNS for `api`, `ari`, `ws`, `n8n`, `grist`, `signoz` subdomains at the NPM
   box (the `vai.innotel.us` entry already exists — if NPM already has a host
   for it, delete that object from the file before importing to avoid a
   duplicate).
2. NPM → **Admin → Import/Export → Import** → select `npm-proxy-hosts.json`.
3. After import, open each host in the UI and add a **Let's Encrypt** cert
   (`SSL` tab → Request a new SSL Certificate). The file imports with
   `ssl_forced: false` / `certificate_id: 0` so import can't fail on a missing
   cert.
4. `forward_host` must be an IP (NPM validates this). If the docker host's LAN
   IP ever changes, update the forward hosts here (and re-point the DNS A
   records).

Notes:
- The dograh webhook URL n8n receives on is `http://<host>:5678/webhook/interview-graded`
  — the dograh Webhook node calls it over the LAN, not through NPM. If you
  prefer the public URL, set `N8N_WEBHOOK_URL=https://n8n.vai.innotel.us/` in
  the compose and point the dograh Webhook node there.
- `ws.vai.innotel.us` and `api.vai.innotel.us` both forward to dograh's port 8000
  (the API and its ARI media WebSocket `/api/v1/telephony/ws/ari` share the
  port). The Asterisk box connects to `wss://ws.vai.innotel.us/api/v1/telephony/ws/ari`
  (see `deploy/asterisk/websocket_client.conf`). This deployment sets
  `TELEPHONY_WS_TOKEN_SECRET` + `TELEPHONY_WS_TOKEN_ENFORCE=true` in the Dograh
  server's `.env`, so the public media socket is **HMAC-token authenticated**
  per call — the ARI manager mints the token and appends it via the `v()`
  transport params, so the static `websocket_client.conf` URI itself stays
  tokenless. Connections without a valid token are rejected (close `4401`).

## Tier 3 — LAN/docker-internal ONLY (never forward, never proxy)

All of these bind to the host but must NOT appear in the router or NPM. They
are only reachable by dograh (host mode → `127.0.0.1`) or by other containers.

| Port(s)          | Service                        |
|------------------|--------------------------------|
| 5432             | postgres (dograh DB)           |
| 6379             | redis (dograh cache)           |
| 9000, 9001       | minio API + console            |
| 8880             | kokoro-fastapi (TTS)           |
| 8001             | speaches (STT)                 |
| 20128            | 9Router (LLM)                  |
| 8088 (+8089 if used) | Asterisk ARI (PBX side; NPM forwards `ari.voice.innotel.us`) |
| 3300             | SigNoz query-service API       |
| 4317, 4318       | SigNoz OTel ingest (gRPC/HTTP) |
| 8888, 8889       | otel-collector metrics         |
| 19000, 8123, 19189 | ClickHouse (native/HTTP/keeper) |
| 9093             | SigNoz alertmanager            |

> **Hardening applied in the compose:** every Tier-3 mapping is bound to
> `127.0.0.1:<port>:<port>`, so these don't answer on the LAN at all. The only
> `0.0.0.0` bindings are the exceptions that need it: **20128** and **8484**
> (n8n reaches them via `host.docker.internal` = the host gateway IP, not
> loopback) and the NPM proxy targets **5678** (n8n) and **3301** (SigNoz UI).
> dograh-api is host-mode (port 8000) and is only exposed if you proxy it.

## The phone path (why nothing else is exposed)

```
student phone ──SIP 5060 / RTP 10000-20000──▶ Asterisk (PBX)
Asterisk ──ARI REST+WS (8088)──▶ dograh        (dograh dials out to the PBX)
Asterisk ──media WS──▶ dograh :8000 /api/v1/telephony/ws/ari   (Asterisk dials out)
dograh   ──localhost──▶ 9Router :20128, kokoro :8880, speaches :8001
dograh   ──LAN──▶ n8n :5678 (webhook), n8n ──LAN──▶ dograh :8000 (transcript)
```

Every hop is either localhost, the docker bridge, or the LAN. The only
internet-facing entry points are: **NPM (80/443)** for web UIs and **SIP/RTP**
for outside callers. Nothing else needs a router forward.
