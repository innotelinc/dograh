"use client";

import Link from "next/link";
import { useState } from "react";
import { toast } from "sonner";

import { loginApiV1AuthLoginPost } from "@/client/sdk.gen";
import { AuthEnterpriseCTA } from "@/components/auth/AuthEnterpriseCTA";
import { AuthShell } from "@/components/auth/AuthShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

// Why a sign-in that just ended up back here ended up back here. The backend
// sends one of these slugs (api/routes/auth.py `_failure_redirect`); without a
// message the user is returned to an unchanged form and has no way to tell a
// cancelled consent from an account that is not allowed in — the failure looks
// identical to the button not working.
const SIGN_IN_ERRORS: Record<string, string> = {
  denied: "Sign-in was cancelled before it finished. Try again when you are ready.",
  expired: "That sign-in took too long and expired. Please try again.",
  not_allowed:
    "Your Cerulean account is not allowed to sign in here. Ask an administrator to grant it access.",
  unavailable:
    "Cerulean sign-in is temporarily unavailable. Please try again in a moment.",
  failed: "Sign-in could not be completed. Please try again.",
};

function SignInError({ error }: { error: string | null }) {
  if (!error) return null;
  const message = SIGN_IN_ERRORS[error] ?? SIGN_IN_ERRORS.failed;
  return (
    <p
      role="alert"
      className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-center text-sm text-destructive"
    >
      {message}
    </p>
  );
}

export function LoginForm({
  signupEnabled,
  oidcLoginPath,
  error = null,
}: {
  signupEnabled: boolean;
  oidcLoginPath: string | null;
  error?: string | null;
}) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);

  // Cerulean (Authentik) is the identity provider in this mode: there is no
  // password form to show and no local fallback to offer, because the backend
  // 404s the local routes entirely. The redirect is a full-page navigation, not
  // a fetch, so it works even when the API is on another origin — which is why
  // the path is joined with the backend URL instead of assumed same-origin.
  if (oidcLoginPath) {
    const backendBase = process.env.NEXT_PUBLIC_BACKEND_URL || "";
    const href = `${backendBase}${oidcLoginPath}?next=${encodeURIComponent("/after-sign-in")}`;
    return (
      <AuthShell>
        <div className="space-y-1.5 text-center">
          <h1 className="text-2xl font-semibold tracking-tight">Capstone</h1>
        </div>

        <SignInError error={error} />

        <Button asChild className="w-full">
          <a href={href}>Sign In</a>
        </Button>
      </AuthShell>
    );
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);

    try {
      const res = await loginApiV1AuthLoginPost({
        body: { email, password },
      });

      if (res.error || !res.data) {
        const detail = (res.error as { detail?: string })?.detail;
        toast.error(detail || "Login failed");
        return;
      }

      // Set httpOnly cookies via server route
      await fetch("/api/auth/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: res.data.token, user: res.data.user }),
      });

      window.location.href = "/after-sign-in";
    } catch {
      toast.error("An error occurred. Please try again.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <AuthShell enterpriseSlot={<AuthEnterpriseCTA />}>
      <div className="space-y-1.5 text-center">
        <h1 className="text-2xl font-semibold tracking-tight">Sign in</h1>
        <p className="text-sm text-muted-foreground">
          Enter your email and password to continue
        </p>
      </div>

      <SignInError error={error} />

      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-2">
          <Label htmlFor="email">Email</Label>
          <Input
            id="email"
            type="email"
            placeholder="you@example.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="password">Password</Label>
          <Input
            id="password"
            type="password"
            placeholder="Enter your password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </div>
        <Button type="submit" className="w-full" disabled={loading}>
          {loading ? "Signing in..." : "Sign in"}
        </Button>
      </form>

      {signupEnabled && (
        <p className="text-center text-sm text-muted-foreground">
          Don&apos;t have an account?{" "}
          <Link href="/auth/signup" className="text-primary underline-offset-4 hover:underline">
            Sign up
          </Link>
        </p>
      )}
    </AuthShell>
  );
}
