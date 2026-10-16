// OpenTelemetry bootstrap for n8n.
//
// Loaded via NODE_OPTIONS=--require ... in n8n.Dockerfile. Instruments the
// Node http/express stack so the grading workflow's outbound HTTP call to the
// local LLM is exported as a span (with duration + status) to the SigNoz OTLP
// collector, alongside the dograh pipeline spans.
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');

const endpoint =
  process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://signoz-otel-collector:4318/v1/traces';

const sdk = new NodeSDK({
  serviceName: process.env.OTEL_SERVICE_NAME || 'n8n',
  traceExporter: new OTLPTraceExporter({ url: endpoint }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();

// Best-effort flush on shutdown — n8n's own signal handlers still run.
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.once(sig, () => {
    sdk.shutdown().catch(() => {});
  });
}
