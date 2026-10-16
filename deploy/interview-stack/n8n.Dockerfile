# n8n + OpenTelemetry auto-instrumentation.
#
# The stock n8n image has no OTel tracing, so the grading workflow's LLM call
# is invisible to SigNoz. This adds the OTel SDK + auto-instrumentations and a
# `--require` bootstrap so outbound HTTP spans (the grading call) are exported
# to the OTLP collector.
FROM n8nio/n8n:latest

USER root
RUN npm install -g \
      @opentelemetry/api \
      @opentelemetry/sdk-node \
      @opentelemetry/auto-instrumentations-node \
      @opentelemetry/exporter-trace-otlp-http \
 && npm cache clean --force

COPY n8n-otel/tracing.js /usr/local/lib/node_modules/tracing.js

USER node

# The bootstrap reads OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_SERVICE_NAME from the
# compose environment.
ENV NODE_OPTIONS="--require /usr/local/lib/node_modules/tracing.js"
