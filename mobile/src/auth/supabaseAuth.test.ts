import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { __setSupabaseForTests } from "../backend/supabaseClient";
import { createSeedState } from "../demo/seed";
import { __setDemoStateForTests, getDemoState } from "../demo/store";
import { isAuthReady, setAuthReady } from "./authState";
import { authErrorMessage, supabaseAuth } from "./supabaseAuth";

const UID = "11111111-2222-3333-4444-555555555555";
const session = { user: { id: UID, email: "ada@test.dev" } };

type Profile = { id: string; display_name: string; role: "player" | "moderator"; created_at: string } | null;

/** A fake of the small part of supabase-js that supabaseAuth uses. */
function fakeClient(opts: { profile?: Profile } = {}) {
  const profile: Profile = opts.profile === undefined
    ? { id: UID, display_name: "Ada", role: "player", created_at: "2026-11-17T23:00:00Z" }
    : opts.profile;
  let authCallback: ((event: string, s: unknown) => void) | null = null;
  const query = {
    select: vi.fn(() => query),
    eq: vi.fn(() => query),
    maybeSingle: vi.fn(async () => ({ data: profile, error: null })),
  };
  const client = {
    auth: {
      signInWithPassword: vi.fn(async () => ({ data: { session }, error: null })),
      signUp: vi.fn(async () => ({ data: { session }, error: null })),
      signOut: vi.fn(async () => ({ error: null })),
      onAuthStateChange: vi.fn((cb: (event: string, s: unknown) => void) => {
        authCallback = cb;
        return { data: { subscription: { unsubscribe: vi.fn() } } };
      }),
    },
    from: vi.fn(() => query),
  };
  __setSupabaseForTests(client as unknown as SupabaseClient);
  return { client, query, fire: (event: string, s: unknown) => authCallback?.(event, s) };
}

const currentUser = () => {
  const s = getDemoState();
  return s.users.find((u) => u.id === s.sessionUserId);
};

describe("Supabase authentication", () => {
  beforeEach(() => {
    __setDemoStateForTests(createSeedState(Date.now()));
    setAuthReady(false);
  });
  afterEach(() => __setSupabaseForTests(null));

  it("logs in and takes name and role from the server profile", async () => {
    const { client, query } = fakeClient({ profile: { id: UID, display_name: "Ada", role: "moderator", created_at: "2026-11-17T23:00:00Z" } });
    expect(await supabaseAuth.login(" ada@test.dev ", "pw")).toEqual({ ok: true });
    expect(client.auth.signInWithPassword).toHaveBeenCalledWith({ email: "ada@test.dev", password: "pw" });
    expect(client.from).toHaveBeenCalledWith("profiles");
    expect(query.eq).toHaveBeenCalledWith("id", UID);
    expect(currentUser()).toMatchObject({ id: UID, name: "Ada", email: "ada@test.dev", role: "moderator" });
  });

  it("shows Iris's message for wrong credentials and stays signed out", async () => {
    const { client } = fakeClient();
    client.auth.signInWithPassword.mockResolvedValueOnce({
      data: { session: null },
      error: { message: "Invalid login credentials", code: "invalid_credentials", status: 400 },
    } as never);
    expect(await supabaseAuth.login("ada@test.dev", "nope")).toEqual({ ok: false, message: "Invalid email or password." });
    expect(currentUser()).toBeUndefined();
  });

  it("refuses an account with no profile, and signs it out again", async () => {
    const { client } = fakeClient({ profile: null });
    const result = await supabaseAuth.login("ada@test.dev", "pw");
    expect(result.ok).toBe(false);
    expect(client.auth.signOut).toHaveBeenCalled();
    expect(currentUser()).toBeUndefined();
  });

  it("signs up with the display name as metadata, never a role", async () => {
    const { client } = fakeClient();
    expect(await supabaseAuth.signUp({ email: "ada@test.dev", password: "secret1", displayName: "  Ada  " })).toEqual({ ok: true });
    expect(client.auth.signUp).toHaveBeenCalledWith({
      email: "ada@test.dev",
      password: "secret1",
      options: { data: { display_name: "Ada" } },
    });
    expect(currentUser()).toMatchObject({ id: UID, role: "player" });
  });

  it("checks name and password length before calling the server", async () => {
    const { client } = fakeClient();
    expect((await supabaseAuth.signUp({ email: "a@test.dev", password: "secret1", displayName: " " })).ok).toBe(false);
    expect((await supabaseAuth.signUp({ email: "a@test.dev", password: "12345", displayName: "A" })).ok).toBe(false);
    expect(client.auth.signUp).not.toHaveBeenCalled();
  });

  it("explains when sign-up needs email confirmation", async () => {
    const { client } = fakeClient();
    client.auth.signUp.mockResolvedValueOnce({ data: { session: null }, error: null } as never);
    const result = await supabaseAuth.signUp({ email: "a@test.dev", password: "secret1", displayName: "A" });
    expect(result).toEqual({ ok: false, message: "Check your email to confirm your account, then log in." });
  });

  it("restores a saved session on start, then marks auth ready", async () => {
    const { fire } = fakeClient();
    const stop = supabaseAuth.start();
    expect(isAuthReady()).toBe(false);
    fire("INITIAL_SESSION", session);
    await vi.waitFor(() => expect(isAuthReady()).toBe(true));
    expect(currentUser()).toMatchObject({ id: UID, name: "Ada" });
    stop();
  });

  it("with no saved session, starts signed out and ready", async () => {
    const { fire } = fakeClient();
    supabaseAuth.start();
    fire("INITIAL_SESSION", null);
    await vi.waitFor(() => expect(isAuthReady()).toBe(true));
    expect(currentUser()).toBeUndefined();
  });

  it("logout ends the Supabase session and the local one", async () => {
    const { client } = fakeClient();
    await supabaseAuth.login("ada@test.dev", "pw");
    await supabaseAuth.logout();
    expect(client.auth.signOut).toHaveBeenCalled();
    expect(currentUser()).toBeUndefined();
  });

  it("maps other auth errors to actionable messages", () => {
    expect(authErrorMessage({ message: "x", code: "user_already_exists" })).toMatch(/already exists/);
    expect(authErrorMessage({ message: "x", code: "weak_password" })).toMatch(/at least 6/);
    expect(authErrorMessage({ message: "Failed to fetch", status: 0 })).toMatch(/Can't reach/);
    expect(authErrorMessage({ message: "Something odd" })).toBe("Something odd");
  });
});
