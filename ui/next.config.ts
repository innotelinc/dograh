import { withSentryConfig } from "@sentry/nextjs";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* config options here */
  // webpack's persistent cache holds one *in-memory* generation of every module
  // for as long as the build runs (Next sets `maxMemoryGenerations: Infinity`
  // for production, so nothing is ever evicted), and on a build host with a hard
  // memory cap that pass is what walks the build into it: on the 4 GiB
  // `development` container the peak sat at 4.4 GiB and the cgroup OOM-killed
  // `next build` right after "Creating an optimized production build". Turning
  // the cache off is what brings it under the cap.
  //
  // Opt-in, not the default: the cache is what makes a *repeat* build fast, and
  // an image build gets nothing from a cache that dies with its layer. The
  // Dockerfile sets NEXT_BUILD_FS_CACHE=0 for exactly that case; local builds
  // keep Next's default.
  webpack: (config, { dev }) => {
    if (!dev && process.env.NEXT_BUILD_FS_CACHE === '0') {
      config.cache = false;
    }
    return config;
  },
  output: 'standalone',
  experimental: {
    serverSourceMaps: true,
    // One static-generation worker instead of one per core. The default spawns
    // a Node process per CPU, and on this box that peak (workers + webpack +
    // the type-check child) is what got the build OOM-killed; the extra
    // parallelism only shaves a little wall-clock time.
    cpus: Number(process.env.NEXT_BUILD_CPUS ?? 1),
  },
  async rewrites() {
    return [
      {
        source: "/ingest/static/:path*",
        destination: "https://us-assets.i.posthog.com/static/:path*",
      },
      {
        source: "/ingest/:path*",
        destination: "https://us.i.posthog.com/:path*",
      },
      {
        source: "/ingest/decide",
        destination: "https://us.i.posthog.com/decide",
      },
    ];
  },
  // This is required to support PostHog trailing slash API requests
  skipTrailingSlashRedirect: true,

  // Next runs its type-check inside `next build`, at the same time webpack is
  // still holding the module graph — on a memory-constrained host that combined
  // peak is what gets the build OOM-killed. The image build runs
  // `tsc --noEmit` on its own line first (same check, sequential peaks) and sets
  // this flag to stop Next repeating it. Dev/CI builds are unaffected.
  typescript: {
    ignoreBuildErrors: process.env.NEXT_SKIP_TYPECHECK === '1',
  },
};

export default withSentryConfig(nextConfig, {
  // For all available options, see:
  // https://www.npmjs.com/package/@sentry/webpack-plugin#options

  org: "dograh",
  project: "javascript-nextjs",

  // Only print logs for uploading source maps in CI
  silent: !process.env.CI,

  // For all available options, see:
  // https://docs.sentry.io/platforms/javascript/guides/nextjs/manual-setup/

  // Upload a larger set of source maps for prettier stack traces (increases build time)
  widenClientFileUpload: true,

  // Route browser requests to Sentry through a Next.js rewrite to circumvent ad-blockers.
  // This can increase your server load as well as your hosting bill.
  // Note: Check that the configured route will not match with your Next.js middleware, otherwise reporting of client-
  // side errors will fail.
  tunnelRoute: "/monitoring",

  webpack: {
    // Automatically tree-shake Sentry logger statements to reduce bundle size
    treeshake: {
      removeDebugLogging: true,
    },

    // Enables automatic instrumentation of Vercel Cron Monitors. (Does not yet work with App Router route handlers.)
    // See the following for more information:
    // https://docs.sentry.io/product/crons/
    // https://vercel.com/docs/cron-jobs
    automaticVercelMonitors: true,
  },
});
