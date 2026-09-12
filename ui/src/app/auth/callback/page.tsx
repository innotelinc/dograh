import { OidcCallback } from "./OidcCallback";

// The callback is reached from the identity provider with no session cookie —
// it exists to receive the one being issued. It also must not be prerendered:
// it reads its token out of the URL fragment, which only exists in the browser.
export const dynamic = "force-dynamic";

export default function OidcCallbackPage() {
  return <OidcCallback />;
}
