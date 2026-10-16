// Shared two-column auth shell, used by BOTH the Stack Auth handler
// (/handler/[...stack], cloud) and the local/OSS auth pages (/auth/login,
// /auth/signup). LEFT: a centered card that wraps the auth form (`children`).
// RIGHT (lg+ only): the platform value proposition. Mobile collapses to the
// single card column. The form column scrolls and stays centered so tall
// (sign-up) forms never clip on short viewports.
//
// Capstone customization: the brand panel shows only "AI Voice Agent Platform"
// — no upstream logo, proof-point chips, or enterprise CTA — and the form
// column carries no dograh watermark. `enterpriseSlot` is still accepted so
// the upstream call sites keep compiling, but it is intentionally not rendered.

import type { ReactNode } from "react";

export function AuthShell({
  children,
}: {
  children: ReactNode;
  enterpriseSlot?: ReactNode;
}) {
  return (
    <div className="grid min-h-screen w-full bg-background lg:grid-cols-[55%_45%]">
      {/* Form column (LEFT) — scrolls and stays centered so tall forms never
          clip. */}
      <main className="flex min-h-screen flex-col overflow-y-auto">
        <div className="flex min-h-full items-center justify-center p-6 sm:p-10">
          <div className="w-full max-w-md space-y-6 rounded-2xl border border-border/60 bg-card p-6 shadow-lg sm:p-8">
            {/* Mobile-only wordmark (brand panel is hidden) */}
            <div className="text-center text-lg font-semibold tracking-tight lg:hidden">
              Capstone
            </div>
            {children}
          </div>
        </div>
      </main>

      {/* Value panel (RIGHT) — hidden on mobile */}
      <aside className="relative hidden flex-col items-center justify-center overflow-hidden border-l border-border/60 bg-zinc-950 p-10 lg:flex xl:p-14">
        {/* Ambient depth: soft radial glow behind the content */}
        <div
          aria-hidden
          className="pointer-events-none absolute -right-24 top-1/3 size-[28rem] rounded-full opacity-20 blur-3xl"
          style={{ background: "radial-gradient(circle, var(--cta), transparent 70%)" }}
        />

        <h1 className="relative text-center text-3xl font-semibold leading-tight tracking-tight text-zinc-50 xl:text-4xl">
          AI Voice Agent Platform
        </h1>
      </aside>
    </div>
  );
}
