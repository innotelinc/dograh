'use client';

import React, { useEffect, useMemo, useRef, useState } from 'react';

import logger from '@/lib/logger';

import type { AuthUser, LocalUser } from '../types';
import { AuthContext } from './AuthProvider';

/**
 * Session provider for every mode whose session lives in the OSS cookies.
 *
 * That is `local` and `oidc` alike: an Authentik sign-in ends in the backend
 * minting the same JWT a password login would, so the only thing that differs is
 * which screen the user saw first. `providerName` exists so consumers can tell
 * the two apart (analytics, "sign out of Authentik too") without a second,
 * near-identical wrapper that would drift from this one.
 */
export function LocalProviderWrapper({
  children,
  providerName = 'local',
}: {
  children: React.ReactNode;
  providerName?: string;
}) {
  const [user, setUser] = useState<LocalUser | null>(null);
  const [loading, setLoading] = useState(true);
  const tokenRef = useRef<string | null>(null);

  useEffect(() => {
    if (typeof window === 'undefined') return;

    const initializeAuth = async () => {
      try {
        const response = await fetch('/api/auth/oss');
        if (response.ok) {
          const data = await response.json();
          tokenRef.current = data.token;
          setUser(data.user);
          logger.info('OSS auth initialized', { user: data.user });
        } else if (response.status === 401) {
          // No token - redirect to login (but not if already on auth pages)
          if (!window.location.pathname.startsWith('/auth/')) {
            window.location.href = '/auth/login';
            return;
          }
        } else {
          logger.error('Failed to initialize OSS auth');
        }
      } catch (error) {
        logger.error('Error initializing OSS auth', error);
      } finally {
        setLoading(false);
      }
    };

    initializeAuth();
  }, []);

  const getAccessToken = React.useCallback(async () => {
    if (typeof window === 'undefined') {
      return 'ssr-placeholder-token';
    }
    if (!tokenRef.current) {
      logger.warn('No OSS token available after initialization');
      return '';
    }
    return tokenRef.current;
  }, []);

  const redirectToLogin = React.useCallback(() => {
    window.location.href = '/auth/login';
  }, []);

  const logout = React.useCallback(async () => {
    try {
      await fetch('/api/auth/logout', { method: 'POST' });
    } catch (error) {
      logger.error('Error during logout', error);
    }
    setUser(null);
    tokenRef.current = null;
    window.location.href = '/auth/login';
  }, []);

  const contextValue = useMemo(() => ({
    user: user as AuthUser,
    isAuthenticated: !!user,
    loading,
    getAccessToken,
    redirectToLogin,
    logout,
    provider: providerName,
  }), [user, loading, getAccessToken, redirectToLogin, logout, providerName]);

  return (
    <AuthContext.Provider value={contextValue}>
      {children}
    </AuthContext.Provider>
  );
}
