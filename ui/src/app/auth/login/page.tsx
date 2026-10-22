import { getOidcLoginPath, getSignupEnabled } from "@/lib/auth/config";

import { LoginForm } from "./LoginForm";

// Resolve the backend health check before rendering so the sign-in screen is
// correct on first paint — no client-side fetch, no flicker on locked-down
// installs. force-dynamic keeps the page off the build-time prerender, which
// would bake in the flag's build-environment value.
export const dynamic = "force-dynamic";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const [signupEnabled, oidcLoginPath, params] = await Promise.all([
    getSignupEnabled(),
    getOidcLoginPath(),
    searchParams,
  ]);
  // The backend funnels every OIDC failure back here as `?error=<slug>` (see
  // `_failure_redirect` in api/routes/auth.py). Forwarding it is what turns a
  // bounced sign-in into something the user can act on instead of an unchanged
  // form that appears to do nothing.
  return (
    <LoginForm
      signupEnabled={signupEnabled}
      oidcLoginPath={oidcLoginPath}
      error={params?.error ?? null}
    />
  );
}
