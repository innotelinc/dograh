import type { CurrentUser } from '@stackframe/stack';

// Base user interface that all providers must support
export interface BaseUser {
  id: string;
  email?: string;
  name?: string;
  image?: string;
}

// Session-cookie user type. Covers both `local` (password) and `oidc`
// (Cerulean/Authentik) because the backend mints the same JWT for either, so the
// session is stored and read identically — only the sign-in screen differs.
export interface LocalUser extends BaseUser {
  provider: 'local' | 'oidc';
  organizationId?: string;
  displayName?: string;
  provider_id?: string;
}

// Union type for all user types
export type AuthUser = CurrentUser | LocalUser;


export interface AuthToken {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: number;
}

export interface TeamPermission {
  id: string;
}

export type AuthProvider = 'stack' | 'local' | 'oidc';

export interface AuthConfig {
  provider: AuthProvider;
  // Provider-specific configuration
  [key: string]: string | number | boolean;
}

