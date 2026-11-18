import type { BackendMode } from "../backend/config";

export type AuthResult =
  | { ok: true }
  | { ok: false; message: string };

export type SignUpInput = { email: string; password: string; displayName: string };

/**
 * What the app needs from an authentication backend. Both implementations
 * put the signed-in user into the game store (store.ts), so every screen
 * keeps reading the session the same way.
 */
export interface AuthBackend {
  readonly kind: BackendMode;
  readonly canSignUp: boolean;
  /** Starts restoring/watching the session. Returns a function that stops it. */
  start(): () => void;
  login(email: string, password: string): Promise<AuthResult>;
  signUp(input: SignUpInput): Promise<AuthResult>;
  logout(): Promise<void>;
}
