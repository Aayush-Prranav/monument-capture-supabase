import { useEffect, type ReactNode } from "react";

import { backendMode, type BackendMode } from "../backend/config";
import { useCurrentUser } from "../demo/store";
import type { User } from "../demo/types";
import type { AuthBackend, AuthResult, SignUpInput } from "./authBackend";
import { setAuthReady, useAuthReady } from "./authState";
import { localAuth } from "./localAuth";
import { supabaseAuth } from "./supabaseAuth";

// US-01 authentication (originally Iris's mock login). The public API is the
// same as before: wrap the app in <AuthProvider> and call useAuth(). Which
// backend does the work is chosen by EXPO_PUBLIC_BACKEND (backend/config.ts).

let backend: AuthBackend = backendMode === "supabase" ? supabaseAuth : localAuth;
// Local mode knows the session synchronously; Supabase has to restore it first.
setAuthReady(backend.kind === "local");

/** Test helper: swap the backend. */
export function __setAuthBackendForTests(next: AuthBackend) {
  backend = next;
  setAuthReady(next.kind === "local");
}

type AuthContextType = {
  /** False while a saved session is still being restored. */
  ready: boolean;
  isLoggedIn: boolean;
  user: User | undefined;
  backend: BackendMode;
  canSignUp: boolean;
  login: (email: string, password: string) => Promise<AuthResult>;
  signUp: (input: SignUpInput) => Promise<AuthResult>;
  logout: () => Promise<void>;
};

export function AuthProvider({ children }: { children: ReactNode }) {
  useEffect(() => backend.start(), []);
  return <>{children}</>;
}

export function useAuth(): AuthContextType {
  const user = useCurrentUser();
  const ready = useAuthReady();
  return {
    ready,
    isLoggedIn: !!user,
    user,
    backend: backend.kind,
    canSignUp: backend.canSignUp,
    login: (email, password) => backend.login(email, password),
    signUp: (input) => backend.signUp(input),
    logout: () => backend.logout(),
  };
}
