// Real accounts in Supabase Auth. Used when EXPO_PUBLIC_BACKEND=supabase.
//
// Identity and role come from the server: after sign-in we read the caller's
// row in public.profiles (created by the sign-up trigger, role always
// 'player' until promoted in SQL) and put that user into the game store.

import type { AuthError, Session, SupabaseClient, User as AuthUser } from "@supabase/supabase-js";

import { getSupabase } from "../backend/supabaseClient";
import { demo } from "../demo/store";
import type { Role, User } from "../demo/types";
import type { AuthBackend, AuthResult } from "./authBackend";
import { setAuthReady } from "./authState";

type ProfileRow = { id: string; display_name: string; role: Role; created_at: string };

export const MIN_PASSWORD_LENGTH = 6;

/** Turns Supabase Auth errors into messages a player can act on. */
export function authErrorMessage(error: Pick<AuthError, "message"> & { code?: string; status?: number }): string {
  switch (error.code) {
    case "invalid_credentials":
      return "Invalid email or password.";
    case "user_already_exists":
    case "email_exists":
      return "An account with this email already exists. Log in instead.";
    case "weak_password":
      return `Choose a stronger password (at least ${MIN_PASSWORD_LENGTH} characters).`;
    case "email_address_invalid":
    case "validation_failed":
      return "Enter a valid email address.";
    case "signup_disabled":
      return "New sign-ups are turned off for this game.";
    case "over_request_rate_limit":
    case "over_email_send_rate_limit":
      return "Too many attempts. Wait a minute and try again.";
    default:
      if (error.status === 0 || /fetch|network/i.test(error.message)) {
        return "Can't reach the game server. Check your connection and try again.";
      }
      return error.message || "Something went wrong. Try again.";
  }
}

export async function loadProfile(client: SupabaseClient, authUser: AuthUser): Promise<User | null> {
  const { data, error } = await client
    .from("profiles")
    .select("id, display_name, role, created_at")
    .eq("id", authUser.id)
    .maybeSingle<ProfileRow>();
  if (error || !data) return null;
  return {
    id: data.id,
    name: data.display_name,
    email: authUser.email ?? "",
    role: data.role,
    joinedAt: Date.parse(data.created_at),
  };
}

const NO_PROFILE = "Your account has no game profile yet. Ask a moderator to check the database.";

/** Puts the session's user into the game store, or clears it. */
async function applySession(client: SupabaseClient, session: Session | null): Promise<AuthResult> {
  if (!session) {
    demo.logout();
    return { ok: true };
  }
  const user = await loadProfile(client, session.user);
  if (!user) {
    demo.logout();
    return { ok: false, message: NO_PROFILE };
  }
  demo.signInAs(user);
  return { ok: true };
}

export const supabaseAuth: AuthBackend = {
  kind: "supabase",
  canSignUp: true,

  start() {
    const client = getSupabase();
    // Fires INITIAL_SESSION straight away (restoring a saved session), then on
    // every sign-in, sign-out and token refresh. Supabase warns against
    // awaiting other client calls inside this callback, so defer the work.
    const { data } = client.auth.onAuthStateChange((event, session) => {
      if (event === "TOKEN_REFRESHED") return;
      setTimeout(() => {
        void applySession(client, session).finally(() => setAuthReady(true));
      }, 0);
    });
    return () => data.subscription.unsubscribe();
  },

  async login(email, password) {
    const client = getSupabase();
    const { data, error } = await client.auth.signInWithPassword({ email: email.trim(), password });
    if (error) return { ok: false, message: authErrorMessage(error) };
    const result = await applySession(client, data.session);
    if (!result.ok) await client.auth.signOut();
    return result;
  },

  async signUp({ email, password, displayName }) {
    if (!displayName.trim()) return { ok: false, message: "Choose a display name." };
    if (password.length < MIN_PASSWORD_LENGTH) {
      return { ok: false, message: `Choose a stronger password (at least ${MIN_PASSWORD_LENGTH} characters).` };
    }
    const client = getSupabase();
    const { data, error } = await client.auth.signUp({
      email: email.trim(),
      password,
      options: { data: { display_name: displayName.trim() } },
    });
    if (error) return { ok: false, message: authErrorMessage(error) };
    if (!data.session) {
      // Only happens if "Confirm email" is switched back on in Supabase.
      return { ok: false, message: "Check your email to confirm your account, then log in." };
    }
    return applySession(client, data.session);
  },

  async logout() {
    try {
      await getSupabase().auth.signOut();
    } finally {
      demo.logout();
    }
  },
};
