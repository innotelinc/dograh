# About Innotel's Dograh

**Dograh** is an open-source, self-hostable voice-AI platform — a drag-and-drop
workflow builder for creating production voice agents that can answer, qualify,
and route phone calls. It's the open alternative to Vapi and Retell: you keep
your own LLM / STT / TTS keys, your own data, and your own infrastructure.

**innotelinc/dograh** is Innotel's private fork. It's the same open-source core
with a deployment tuned for Innotel's own stack:

- **Self-hosted** on Innotel infrastructure, not a third-party SaaS.
- **Fronted by Nginx Proxy Manager** — web UI at **https://vai.innotel.us** and
  the platform API at **https://api.vai.innotel.us** — TLS is handled by NPM,
  and the platform's internal nginx routes UI/API/object-storage traffic.
- **Wired into Innotel's FreePBX / Asterisk** box at **voice.innotel.us** using
  the Asterisk ARI integration. Existing PBX extensions can be answered by AI
  agents, and calls can be transferred back to human agents.

## Why fork?

The fork exists so the deployment stays reproducible and reviewable:

- Build-from-source images mean the exact code running in production is the
  code in this repository.
- Every deployment tweak (NPM port mapping, HTTP-only nginx, disabled
  cloudflared) is committed here and documented in the README.
- Secrets never live in the repo — they're generated into the gitignored
  `.env` on the server.

## Stack at a glance

| Component | Role |
|-----------|------|
| FastAPI (`api/`) | Voice pipeline orchestration, telephony, auth |
| Next.js (`ui/`) | Drag-and-drop workflow builder + dashboard |
| PostgreSQL | Application database |
| Redis | Queue / cache (ARQ background jobs) |
| MinIO | S3-compatible object storage for call recordings |
| coturn | TURN server for WebRTC NAT traversal |
| Pipecat | Real-time voice pipeline framework (submodule) |

## Contact

Innotel — infrastructure, telephony, and voice-AI operations.
