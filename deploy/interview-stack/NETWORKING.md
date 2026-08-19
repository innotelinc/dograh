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

| NPM proxy host  | Target (LAN)            | Notes                                             |
|-----------------|-------------------------|---------------------------------------------------|
| dograh UI       | `http://192.168.1.63:3010` | Main dashboard                             |
| dograh API      | `http://192.168.1.63:8000` | Needed by the UI; keep it LAN-only if possible |
| n8n             | `http://192.168.1.63:5678` | Workflow editor + webhook receive         |
| Grist           | `http://192.168.1.63:8484` | Scores/transcripts dashboard              |
| SigNoz          | `http://192.168.1.63:3301` | Traces + latency dashboards               |

Notes:
- The dograh webhook URL n8n receives on is `http://<host>:5678/webhook/interview-graded`
  — the dograh Webhook node calls it over the LAN, not through NPM.
- If you expose the dograh API through NPM, its ARI media WebSocket
  (`/api/v1/telephony/ws/ari`) becomes reachable from the internet. It's
  token-protected only if you set `TELEPHONY_WS_TOKEN_SECRET`+`_ENFORCE` — for a
  capstone, prefer keeping the API LAN-only and using NPM only for UI/n8n/Grist.

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
| 8088 (+8089 if used) | Asterisk ARI (PBX side)    |
| 3300             | SigNoz query-service API       |
| 4317, 4318       | SigNoz OTel ingest (gRPC/HTTP) |
| 8888, 8889       | otel-collector metrics         |
| 19000, 8123, 19189 | ClickHouse (native/HTTP/keeper) |
| 9093             | SigNoz alertmanager            |

> Optional hardening: change these compose mappings to `127.0.0.1:<port>:<port>`
> so they don't answer on the LAN at all. Exceptions that must stay on
> `0.0.0.0`: **20128** and **8484** (n8n reaches them via `host.docker.internal`
> = the host gateway IP, not loopback) and anything NPM proxies (3010, 5678,
> 3301, and 8000 if you proxy the API).

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
