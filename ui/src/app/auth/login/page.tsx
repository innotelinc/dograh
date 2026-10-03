import { getOidcLoginPath, getSignupEnabled } from "@/lib/auth/config";

import { LoginForm } from "./LoginForm";

// Resolve the backend health check before rendering so the sign-in screen is
// correct on first paint — no client-side fetch, no flicker on locked-down
// installs. force-dynamic keeps the page off the build-time prerender, which
// would bake in the flag's build-environment value.
export const dynamic = "force-dynamic";

export default async function LoginPage() {
  const [signupEnabled, oidcLoginPath] = await Promise.all([
    getSignupEnabled(),
    getOidcLoginPath(),
  ]);
  return (
    <LoginForm signupEnabled={signupEnabled} oidcLoginPath={oidcLoginPath} />
  );
}
