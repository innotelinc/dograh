# syntax=docker/dockerfile:1
# Multi-stage build
# Stage 1: Dependencies
FROM node:22-alpine AS deps
WORKDIR /app

# Install Python and build dependencies for native modules
# This helps with ARM64 builds and native module compilation
RUN apk add --no-cache python3 make g++ libc6-compat

# Copy package files
COPY ui/package*.json ./

# Clean install with proper handling of native modules.
# Heap is settable so this image can be built on a memory-constrained box:
#   docker compose ... build --build-arg NODE_BUILD_HEAP_MB=2048 dograh-ui
ARG NODE_BUILD_HEAP_MB=4096
RUN --mount=type=cache,target=/root/.npm \
    NODE_OPTIONS="--max-old-space-size=${NODE_BUILD_HEAP_MB}" npm ci

# Stage 2: Builder
FROM node:22-alpine AS builder
WORKDIR /app

# Install libc6-compat for native modules in builder stage too
RUN apk add --no-cache libc6-compat

# Copy dependencies from deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy all files needed for build
COPY ui/package*.json ./
COPY ui/tsconfig.json ./
COPY ui/next.config.ts ./
COPY ui/components.json ./
COPY ui/sentry.edge.config.ts ./
COPY ui/sentry.server.config.ts ./
COPY ui/postcss.config.mjs ./
COPY ui/public ./public
COPY ui/src ./src

# webpack's persistent cache is held in memory for the whole build and is pure
# overhead here — the layer that writes it is discarded with the image. Set
# here rather than in next.config.ts, which local builds share; see that file
# for the measured reason (this is what makes the build fit a 4 GiB host).
ENV NEXT_BUILD_FS_CACHE="0"

# Set build-time environment variables (needed for Next.js build)
ENV NEXT_PUBLIC_NODE_ENV="oss"
ENV NEXT_TELEMETRY_DISABLED="1"
ENV NEXT_PUBLIC_CHATWOOT_URL="https://chat.dograh.com"
ENV NEXT_PUBLIC_CHATWOOT_TOKEN="3fkFx2mCEjNHjM9gaNc4A82X"
ENV BACKEND_URL="http://api:8000"

# Build the application with standalone mode.
# The heap is an ARG (see the deps stage) so a build on a small host can cap it
# instead of being OOM-killed: Next's webpack pass and its type-check child both
# live under this number.
ARG NODE_BUILD_HEAP_MB=4096
ENV NODE_OPTIONS="--max-old-space-size=${NODE_BUILD_HEAP_MB}"
# Type-check first, on its own line, then build with Next's own check disabled
# (NEXT_SKIP_TYPECHECK). Same verification, but the two memory-heavy phases no
# longer overlap — running them together is what got this build OOM-killed on a
# 16 GB host. A type error still fails the image build here.
ENV NEXT_SKIP_TYPECHECK="1"
RUN npx tsc --noEmit
RUN npm run build && \
    rm -rf /tmp/* /root/.npm /root/.next/cache

# Stage 3: Runner (production image)
FROM node:22-alpine AS runner
WORKDIR /app

# Environment variables will be provided by docker-compose
ENV NODE_ENV=production

# Create a non-root user
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# Copy standalone build output
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public

# Switch to non-root user
USER nextjs

# Expose the port Next.js runs on
EXPOSE 3010

# Start the production server using the standalone Node.js server
CMD sh -c "echo '🚀 Application ready at http://localhost:3010' && PORT=3010 node server.js"
