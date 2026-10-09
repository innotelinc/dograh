"use client";

import { Loader2 } from "lucide-react";
import { useEffect, useRef } from "react";

import { AuthShell } from "@/components/auth/AuthShell";
import logger from "@/lib/logger";

const SESSION_ROUTE = "/api/auth/session";

/**
 * Finishes a Cerulean (Authentik) sign-in.
 *
 * The API does all of the OIDC work — discovery, PKCE, the code exchange and
 * ID-token verification — and then sends the browser here with the Dograh
 * session it minted for the verified user. That token arrives in the URL
 * *fragment*, not a query string, so it is never sent to a server, never lands
 * in an access log and never leaks through a `Referer` header.
 *
 * This page then stores it exactly the way a password login does, through
 * `/api/auth/session`. That is deliberate: the cookie it sets is the one the
 * middleware, `/api/auth/oss` and the provider wrapper already read, so SSO
 * needs no second notion of "signed in".
 *
 * The JWT payload is decoded (not verified) purely to populate the display copy
 * of the user cookie. Nothing is authorized on the client — every request is
 * re-validated by the API against the same token.
 */
export function OidcCallback() {
  // React 18 runs effects twice in development; without this guard the session
  // POST and the redirect would both fire twice.
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;

    const finish = async () => {
      const fragment = new URLSearchParams(
        window.location.hash.replace(/^#/, "")
      );
      const token = fragment.get("access_token");
      const next = fragment.get("next") || "/after-sign-in";

      if (!token) {
        // No token means the redirect was truncated or hand-crafted. Send them
        // back to sign in rather than leaving a spinner on screen forever.
        window.location.replace("/auth/login?error=failed");
        return;
      }

      try {
        const payload = decodeJwtPayload(token);
        const response = await fetch(SESSION_ROUTE, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            token,
            user: {
              id: payload?.sub ?? "",
              email: payload?.email ?? "",
              name: payload?.email ?? "",
              provider: "oidc",
            },
          }),
        });

        if (!response.ok) {
          throw new Error(`session route returned ${response.status}`);
        }

        // `replace` so the fragment — which contains the session token — does
        // not stay in history for a back-button press to reveal.
        window.location.replace(next);
      } catch (error) {
        logger.error("Failed to store the OIDC session", error);
        window.location.replace("/auth/login?error=failed");
      }
    };

    void finish();
  }, []);

  return (
    <AuthShell>
      <div className="flex flex-col items-center gap-3 text-center">
        <Loader2 className="h-8 w-8 animate-spin" />
        <p className="text-sm text-muted-foreground">Signing you in…</p>
      </div>
    </AuthShell>
  );
}

function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const base64 = part.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    return JSON.parse(window.atob(padded));
  } catch {
    // A token we cannot read is not fatal — the session cookie is what
    // authenticates, and this payload only fills in display fields.
    return null;
  }
}
