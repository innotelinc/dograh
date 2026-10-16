import "server-only";

import { getServerBackendUrl } from "@/lib/apiClient";

export interface StackConfig {
  projectId: string;
  publishableClientKey: string;
}

interface ResolvedAuthConfig {
  authProvider: string;
  stackConfig: StackConfig | null;
  signupEnabled: boolean;
  oidcLoginPath: string | null;
}

let cachedConfig: ResolvedAuthConfig | null = null;

/**
 * Fetches the auth configuration from the backend health endpoint and caches it.
 *
 * The backend reports the active auth provider, the public Stack client config
 * when it is `stack`, and the sign-in path to use when it is `oidc`. The UI uses
 * these at runtime, so they no longer need to be baked into the browser bundle
 * at build time. Falls back to local auth on error.
 *
 * `oidc` and `local` share one session mechanism — the backend mints the same
 * JWT either way — so this only has to decide which sign-in screen to render,
 * not how a session is stored. `oidcLoginPath` is a path rather than a full URL
 * because the browser may reach the API on a different origin than the server
 * rendering this (LAN IP vs same-origin behind the edge), and the browser side
 * knows which one it is using.
 */
async function resolveAuthConfig(): Promise<ResolvedAuthConfig> {
  if (cachedConfig) {
    return cachedConfig;
  }

  try {
    const backendUrl = getServerBackendUrl();
    const res = await fetch(`${backendUrl}/api/v1/health`, {
      next: { revalidate: 300 },
    });
    if (res.ok) {
      const data = await res.json();
      const authProvider = (data.auth_provider as string) || "local";
      const stackConfig =
        authProvider === "stack" &&
        data.stack_project_id &&
        data.stack_publishable_client_key
          ? {
              projectId: data.stack_project_id as string,
              publishableClientKey:
                data.stack_publishable_client_key as string,
            }
          : null;
      // Default to signup-enabled when the backend omits the field (older api
      // versions before the flag existed) — matches the backend's own default.
      const signupEnabled = data.signup_enabled !== false;
      const oidcLoginPath =
        authProvider === 'oidc' && data.oidc_login_path
          ? (data.oidc_login_path as string)
          : null;
      cachedConfig = { authProvider, stackConfig, signupEnabled, oidcLoginPath };
      return cachedConfig;
    }
  } catch {
    // Backend not reachable — fall through without caching so we retry next request.
  }

  // Unknown (backend unreachable). Return the local fallback for THIS request but
  // do NOT cache it: caching here would pin the entire UI to local auth until a
  // container restart if the first resolution loses the startup race with the api
  // service. Leaving it uncached means the next request retries and self-heals.
  return {
    authProvider: "local",
    stackConfig: null,
    signupEnabled: true,
    oidcLoginPath: null,
  };
}

/**
 * Returns the active auth provider ('local', 'stack' or 'oidc'). Falls back to
 * 'local'.
 */
export async function getAuthProvider(): Promise<string> {
  return (await resolveAuthConfig()).authProvider;
}

/**
 * Returns the backend path that starts OIDC sign-in when the active provider is
 * `oidc`, otherwise null.
 */
export async function getOidcLoginPath(): Promise<string | null> {
  return (await resolveAuthConfig()).oidcLoginPath;
}

/**
 * Returns the public Stack client config when the active provider is `stack`,
 * otherwise null. Server-only — the browser receives these via /api/config/auth.
 */
export async function getStackConfig(): Promise<StackConfig | null> {
  return (await resolveAuthConfig()).stackConfig;
}

/**
 * Returns true when the backend allows signup (`ENABLE_SIGNUP`, default true).
 * The login page uses this to hide the signup link on locked-down installs.
 */
export async function getSignupEnabled(): Promise<boolean> {
  return (await resolveAuthConfig()).signupEnabled;
}
