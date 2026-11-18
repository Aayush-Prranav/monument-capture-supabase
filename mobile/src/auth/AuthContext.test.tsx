import { act, renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";

import { __setDemoStateForTests } from "../demo/store";
import { createSeedState, DEMO_PASSWORD } from "../demo/seed";
import { __setAuthBackendForTests, useAuth } from "./AuthContext";
import { localAuth } from "./localAuth";

describe("US-01 login with the local backend", () => {
  beforeEach(() => {
    __setAuthBackendForTests(localAuth);
    __setDemoStateForTests(createSeedState(Date.now()));
  });

  it("is ready immediately, with no account creation", () => {
    const { result } = renderHook(() => useAuth());
    expect(result.current.ready).toBe(true);
    expect(result.current.backend).toBe("local");
    expect(result.current.canSignUp).toBe(false);
  });

  it("logs in with a known email and the demo password", async () => {
    const { result } = renderHook(() => useAuth());
    expect(result.current.isLoggedIn).toBe(false);
    let outcome;
    await act(async () => { outcome = await result.current.login("  Demo@Example.com ", DEMO_PASSWORD); });
    expect(outcome).toEqual({ ok: true });
    expect(result.current.isLoggedIn).toBe(true);
    expect(result.current.user?.role).toBe("player");
  });

  it("rejects a wrong password and an unknown email with Iris's message", async () => {
    const { result } = renderHook(() => useAuth());
    await act(async () => {
      expect(await result.current.login("demo@example.com", "wrong")).toEqual({ ok: false, message: "Invalid email or password." });
      expect(await result.current.login("nobody@example.com", DEMO_PASSWORD)).toEqual({ ok: false, message: "Invalid email or password." });
    });
    expect(result.current.isLoggedIn).toBe(false);
  });

  it("signs moderators in with the moderator role, and logs out", async () => {
    const { result } = renderHook(() => useAuth());
    await act(async () => { await result.current.login("mod@demo.test", DEMO_PASSWORD); });
    expect(result.current.user?.role).toBe("moderator");
    await act(async () => { await result.current.logout(); });
    expect(result.current.isLoggedIn).toBe(false);
  });

  it("refuses sign-up without the Supabase backend", async () => {
    const { result } = renderHook(() => useAuth());
    let outcome;
    await act(async () => { outcome = await result.current.signUp({ email: "a@b.c", password: "secret1", displayName: "A" }); });
    expect(outcome).toMatchObject({ ok: false });
  });
});
