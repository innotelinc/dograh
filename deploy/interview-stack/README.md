# Interview Stack — self-hosted AI mock-interview deployment

Single `docker-compose.yml` for the capstone stack. All services are local and
open-source; nothing calls a paid SaaS.

| Service            | Host URL                      | Role                                    |
|--------------------|-------------------------------|-----------------------------------------|
| dograh-api         | host mode (port 8000)         | Orchestrator + Asterisk/ARI telephony   |
| postgres / redis / minio | 5432 / 6379 / 9000      | dograh's own DB, cache, object storage  |
| kokoro-fastapi     | http://127.0.0.1:8880         | Local TTS (Kokoro-82M, OpenAI-compatible) |
| speaches           | http://127.0.0.1:8001         | Local STT (faster-whisper, OpenAI-compatible) |
| 9Router            | http://127.0.0.1:20128        | OpenAI-compatible LLM router/failover  |
| n8n                | http://localhost:5678         | Hang-up webhook → grading workflow      |
| Grist              | http://localhost:8484         | Student / transcript / score dashboard  |
| SigNoz             | http://localhost:3301         | OTel traces + pipeline latency (ClickHouse) |

## Networking model (important)

- `dograh-api` uses `network_mode: host` so it can bind ARI media sockets and
  reach the PBX on loopback. It reaches every other service via the host's
  published ports: **127.0.0.1:8001** (STT), **127.0.0.1:8880** (TTS),
  **127.0.0.1:20128** (LLM), **127.0.0.1:4318** (OTel).
- Everything else is on the `interview-net` bridge and talks by service name.
- Containers that must call back into host-mode dograh (or a host-run 9Router)
  use `host.docker.internal` (enabled via `extra_hosts: host-gateway`).

## Quick start

```bash
cd deploy/interview-stack
# .env is pre-filled: OSS_JWT_SECRET was generated randomly and
# BACKEND_API_ENDPOINT is https://api.vai.innotel.us (NPM fronts the API).
# Review it, then:
docker compose up -d
docker compose ps           # wait for healthy
```

> `BACKEND_API_ENDPOINT` must be reachable from inside the n8n container (it
> fetches the transcript from it). For the innotel deployment it is the
> NPM-fronted `https://api.vai.innotel.us`. If this box's LAN IP ever changes,
> update the NPM forward target for `api.vai.innotel.us` (and the ARI media
> URL in `websocket_client.conf` if it uses the LAN IP) rather than the
> endpoint itself.

> **Precedence gotcha:** shell-exported variables beat the `.env` file in Docker
> Compose. If you `export BACKEND_API_ENDPOINT`/`PUBLIC_BASE_URL`/`OSS_JWT_SECRET`
> anywhere (e.g. a sourced `api/.env`), they will silently override `.env` —
> verify with `docker compose config | grep -E 'BACKEND_API_ENDPOINT|OSS_JWT_SECRET'`
> or `unset` them before `up`.

Then:
1. Open dograh UI → configure the ARI endpoint (http://127.0.0.1:8088) and set
   the interview agent's LLM + STT + TTS (values below).
2. Open n8n (http://localhost:5678) → import the workflow in `n8n-interview-grader.md`.
3. Open SigNoz (http://localhost:3301) → confirm `dograh-interview-agent` traces.
4. Open Grist (http://localhost:8484) → create the `Interviews` table.

## Model wiring inside dograh (UI config, no code changes)

All three stages use dograh's first-class **`speaches`** provider (an
OpenAI-compatible client that forwards `base_url` to whatever local server is
behind it). No code changes are needed — the provider, config schema, and
`service_factory.py` branches already ship in dograh.

| Setting  | LLM (Ollama)                         | STT (speaches)                       | TTS (kokoro-fastapi)             |
|----------|--------------------------------------|--------------------------------------|----------------------------------|
| provider | speaches                             | speaches                             | speaches                         |
| model    | llama3.2                             | Systran/faster-distil-whisper-small.en | kokoro                         |
| voice    | —                                    | —                                    | af_heart (or am_michael, ...)    |
| language | —                                    | en                                   | —                                |
| base_url | http://192.168.1.63:11434/v1         | http://speaches:8000/v1              | http://kokoro:8880/v1            |
| api_key  | (blank — self-hosted)                | (blank — self-hosted)                | (blank — self-hosted)            |

> The table's `base_url` values are the **production** URLs as seen from the
> `vai-api-1` container (which joins the interview-stack bridge and reaches
> speaches/kokoro by service name, Ollama on the host LAN IP). For the
> host-mode `dograh-api` in this compose, use `http://127.0.0.1:8001/v1` (STT),
> `http://127.0.0.1:8880/v1` (TTS), and `http://192.168.1.63:11434/v1` (LLM)
> instead.

**TTS note:** `SpeachesTTSService` (pipecat) already passes provider-specific
voices like `af_heart` through verbatim and requests `pcm` output, so Kokoro
voices work without the earlier `kokoro_tts.py` shim. That shim was removed.

> Note: `validate_user_configured_service_url` allows localhost URLs because
> `DEPLOYMENT_MODE` defaults to `oss`. The compose sets it explicitly.

## Local LLM: Ollama (host-installed, llama3.2)

The LLM runs as a **host process** (not a container) so it doesn't need the
~3 GB Ollama docker image on the already-tight 32 GB root disk — just the
binary (~1.4 GB) plus the model. Install once:

```bash
apt-get install -y zstd                       # the ollama installer needs zstd
curl -fsSL https://ollama.com/install.sh | sh # binary + ollama.service (systemd)
mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment=OLLAMA_HOST=0.0.0.0\n' \
  > /etc/systemd/system/ollama.service.d/override.conf  # reachable from docker
systemctl daemon-reload && systemctl restart ollama
ollama pull llama3.2                          # ~2 GB, CPU-only
```

Ollama serves an OpenAI-compatible API at `http://192.168.1.63:11434/v1`
(bound to all interfaces so the api and n8n containers can reach it; the host
firewall should still block 11434 from outside the LAN). Point dograh's LLM
at it in the UI:

| Setting  | Value |
|----------|-------|
| provider | speaches |
| model    | `llama3.2` |
| base_url | `http://192.168.1.63:11434/v1` |
| api_key  | (blank — self-hosted) |

n8n's grading node uses the same base URL with `model: llama3.2`.

> CPU-only: no GPU on this box, so llama3.2 (3B) runs on CPU — fine for the
> post-call grading step, slow for real-time agent turns. To move to a GPU box
> later, point `base_url` at that host's 11434 instead.

## Observability wiring (SigNoz)

**Already wired — no code change needed.** `api/services/pipecat/tracing_config.py`
now builds its default exporter from `SIGNOZ_OTLP_ENDPOINT` (added in
`api/constants.py`): when the var is set, `ensure_tracing()` exports pipeline
spans there instead of dropping them (previously spans were only exported when
Langfuse env creds existed). Precedence: an explicit `SIGNOZ_OTLP_ENDPOINT` wins
over Langfuse env creds; org-specific Langfuse projects registered at runtime
still take precedence per-org.

The compose already sets `SIGNOZ_OTLP_ENDPOINT=http://127.0.0.1:4318/v1/traces`
and the standard `OTEL_*` vars. Pipecat's `@traced_llm` / `@traced_tts` /
`@traced_stt` decorators emit one span per stage named `llm` / `tts` / `stt`,
each carrying a **`metrics.ttfb`** attribute (seconds) — time-to-first-token
for the LLM, time-to-first-byte for TTS, utterance-processing time for STT.
The spans land under `service.name = dograh-pipeline`.

### Pipeline-latency dashboard

Importable dashboard: **`signoz-pipeline-latency-dashboard.json`**

1. Open SigNoz UI → **Dashboards** → **Import dashboard** → select the file.
2. Panels:
   - `Pipeline latency per call` — table grouped by `traceID` (one row per
     call): worst LLM/TTS/STT stage latency + total.
   - `Pipeline latency p50 / p95` — per-call total latency percentiles.
   - `LLM TTFB` / `TTS TTFB` / `STT TTFB` — p50/p95 of `metrics.ttfb`.
   - `Stage duration breakdown` — avg/p95 duration per stage (bar).
3. If your SigNoz version rejects the import schema, rebuild the panels from
   the query reference below (each panel is one ClickHouse query).

Query reference (table: `signoz_traces.signoz_index_v3`):

```sql
-- per-call table (worst stage latency, total = LLM+TTS+STT)
SELECT traceID, toDateTime(timestamp) AS call_time,
  round(maxIf(durationNano/1e9, name='llm'),3) AS llm_s,
  round(maxIf(durationNano/1e9, name='tts'),3) AS tts_s,
  round(maxIf(durationNano/1e9, name='stt'),3) AS stt_s,
  round(maxIf(durationNano/1e9, name='llm')+maxIf(durationNano/1e9, name='tts')+maxIf(durationNano/1e9, name='stt'),3) AS pipeline_s
FROM signoz_traces.signoz_index_v3
WHERE serviceName='dograh-pipeline' AND timestamp >= now() - INTERVAL 24 HOUR
GROUP BY traceID, call_time ORDER BY call_time DESC LIMIT 200;

-- per-call total percentiles over time
SELECT toStartOfMinute(call_time) AS t, quantile(0.5)(pipeline_s) AS p50_s,
  quantile(0.95)(pipeline_s) AS p95_s
FROM (SELECT traceID, toDateTime(timestamp) AS call_time,
        maxIf(durationNano/1e9,name='llm')+maxIf(durationNano/1e9,name='tts')+maxIf(durationNano/1e9,name='stt') AS pipeline_s
      FROM signoz_traces.signoz_index_v3
      WHERE serviceName='dograh-pipeline' AND timestamp >= now() - INTERVAL 1 HOUR
      GROUP BY traceID, call_time)
GROUP BY t ORDER BY t;

-- TTFB for one stage (repeat for name='llm' | 'tts' | 'stt')
SELECT toStartOfMinute(timestamp) AS t,
  quantile(0.5)(attributesNumber['metrics.ttfb']) AS p50_s,
  quantile(0.95)(attributesNumber['metrics.ttfb']) AS p95_s
FROM signoz_traces.signoz_index_v3
WHERE serviceName='dograh-pipeline' AND name='llm'
  AND has(attributesNumber, 'metrics.ttfb')
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY t ORDER BY t;
```

## n8n grading workflow

Full spec + the IT Help Desk Tier 1 rubric system prompt:
**`n8n-interview-grader.md`**.

Key data-flow facts to design against:

- dograh's **Webhook node** (workflow graph → "Webhook") fires after the call
  completes. Its Jinja payload has access to `workflow_run_id`,
  `initial_context`, `gathered_context`, `annotations`, `call_time`, and a
  **`transcript_url`** (a public download link) — the transcript text is NOT
  inlined, so n8n must fetch it.
- `BACKEND_API_ENDPOINT` must be reachable from inside the n8n container (host
  LAN IP or public URL, not `localhost`). The pre-filled `.env` uses the host's
  LAN IP, so the `transcript_url` works as-is. If you ever switch it back to
  `localhost`, rewrite the host to `host.docker.internal` in the n8n HTTP node.

## Verification checklist

```bash
# 1. All containers up
docker compose ps

# 2. TTS round-trip (from the host, dograh's host-mode view)
curl -s http://127.0.0.1:8880/health
curl -s http://127.0.0.1:8880/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"kokoro","input":"Welcome to your technical interview.","voice":"af_heart","response_format":"wav"}' \
  -o /tmp/kokoro.wav && file /tmp/kokoro.wav

# 3. STT round-trip through speaches (OpenAI-compatible, needs an audio file)
#    Generate one with kokoro (step 2), then transcribe it back:
curl -s http://127.0.0.1:8001/v1/audio/transcriptions \
  -F file=@/tmp/kokoro.wav \
  -F model=Systran/faster-distil-whisper-small.en \
  -F language=en

# 4. LLM round-trip through 9Router (OpenAI-compatible)
curl -s http://127.0.0.1:20128/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Say hello"}]}'

# 5. SigNoz ingest
curl -s http://127.0.0.1:4318/v1/traces -o /dev/null -w '%{http_code}\n'   # expect 200 (rejects bad payload, accepts OTLP)
curl -s http://127.0.0.1:3301/api/v1/health   # unified signoz UI+API

# 6. n8n + Grist reachable
curl -s http://127.0.0.1:5678/healthz
curl -s http://127.0.0.1:8484 -o /dev/null -w '%{http_code}\n'
```

> **100% offline:** with speaches (STT), 9Router (LLM) and kokoro-fastapi (TTS)
> the whole media pipeline runs locally. The only internet access is a one-time
> model download on first start (Whisper + Kokoro), cached in the
> `speaches_models` / `kokoro_models` volumes — after that, disconnect and it
> still works.

### Known caveats / verify before relying on them

- **9Router image** — I could not reach the web to confirm the exact image /
  interface while writing this. It's behind a `nine-router` compose profile.
  If it runs on the host, delete that service; dograh still reaches it at
  `127.0.0.1:20128` and n8n at `host.docker.internal:20128`.
- **kokoro-fastapi image tag** — `remarker/kokoro-fastapi:latest` (CPU) and
  `-cuda` (GPU) are the published tags; confirm they still exist on Docker Hub.
- **SigNoz versions** — the compose pins the v0.138 "Foundry" topology
  (separate ClickHouse Keeper, Postgres metastore, unified `signoz` binary,
  schema created by the collector's `migrate` command). The old
  `clickhouse-setup` + `query-service`/`frontend` split is deprecated; keep the
  SigNoz images on a single version tag rather than `latest` to avoid skew.
- **speaches image / env vars** — `ghcr.io/speaches-ai/speaches:latest` and the
  `SPEACHES_*` env vars match the project's documented interface (dograh's
  registry even links to `github.com/speaches-ai/speaches`). Confirm the tag
  and env names on first pull; the STT is async (VAD-segmented), so there's a
  short pause after each utterance before the transcript lands — normal for
  this provider and for dograh's other async STT providers.
