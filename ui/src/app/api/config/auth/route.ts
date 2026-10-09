import { NextResponse } from 'next/server';

import {
  getAuthProvider,
  getOidcLoginPath,
  getSignupEnabled,
  getStackConfig,
} from '@/lib/auth/config';
import logger from '@/lib/logger';

export async function GET() {
  const provider = await getAuthProvider();
  // When using Stack, hand the public client config to the browser so it can
  // initialize the Stack SDK at runtime (no build-time NEXT_PUBLIC_* needed).
  const stackConfig = provider === 'stack' ? await getStackConfig() : null;
  // When using OIDC, hand over the path that starts the sign-in redirect. The
  // browser joins it with whichever backend URL it resolved.
  const oidcLoginPath = provider === 'oidc' ? await getOidcLoginPath() : null;
  const signupEnabled = await getSignupEnabled();
  logger.debug(`Got provider ${provider} from getAuthProvider`)
  return NextResponse.json({
    provider,
    stackProjectId: stackConfig?.projectId ?? null,
    stackPublishableClientKey: stackConfig?.publishableClientKey ?? null,
    oidcLoginPath,
    signupEnabled,
  });
}
