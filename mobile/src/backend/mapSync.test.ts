import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createSeedState } from "../demo/seed";
import { __setDemoStateForTests, getDemoState } from "../demo/store";
import { getMapSyncStatus, MAP_REFRESH_MS, refreshMap, startMapSync } from "./mapSync";
import { __setSupabaseForTests } from "./supabaseClient";

const serverMap = {
  server_now: new Date().toISOString(),
  monuments: [{
    id: "m1", slug: "bethesda", name: "Bethesda Fountain", neighborhood: "Central Park", description: "",
    icon: "⛲", latitude: 40.7744, longitude: -73.9703, capture_radius_m: 100, active: true, is_test: false, hold: null,
  }],
};

function fakeClient(rpc: ReturnType<typeof vi.fn>) {
  __setSupabaseForTests({ rpc } as unknown as SupabaseClient);
}

describe("map sync", () => {
  beforeEach(() => __setDemoStateForTests({ ...createSeedState(Date.now()), monuments: [] }));
  afterEach(() => {
    __setSupabaseForTests(null);
    vi.useRealTimers();
  });

  it("calls get_game_state and puts the server's monuments in the store", async () => {
    const rpc = vi.fn(async () => ({ data: serverMap, error: null }));
    fakeClient(rpc);
    await refreshMap();
    expect(rpc).toHaveBeenCalledWith("get_game_state");
    expect(getDemoState().monuments.map((m) => m.name)).toEqual(["Bethesda Fountain"]);
    expect(getMapSyncStatus().state).toBe("ok");
  });

  it("keeps the last map and reports a readable error when the server fails", async () => {
    fakeClient(vi.fn(async () => ({ data: serverMap, error: null })));
    await refreshMap();
    fakeClient(vi.fn(async () => { throw new TypeError("Failed to fetch"); }));
    await refreshMap();
    expect(getDemoState().monuments).toHaveLength(1);
    expect(getMapSyncStatus()).toEqual({ state: "error", message: "Can't reach the game server. Showing the last map we had." });
  });

  it("treats a malformed reply as an error, not as an empty map", async () => {
    fakeClient(vi.fn(async () => ({ data: serverMap, error: null })));
    await refreshMap();
    fakeClient(vi.fn(async () => ({ data: { nope: true }, error: null })));
    await refreshMap();
    expect(getDemoState().monuments).toHaveLength(1);
    expect(getMapSyncStatus().state).toBe("error");
  });

  it("refreshes on a timer and stops cleanly", async () => {
    vi.useFakeTimers();
    const rpc = vi.fn(async () => ({ data: serverMap, error: null }));
    fakeClient(rpc);
    const stop = startMapSync();
    await vi.advanceTimersByTimeAsync(0);
    expect(rpc).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(MAP_REFRESH_MS);
    expect(rpc).toHaveBeenCalledTimes(2);
    stop();
    await vi.advanceTimersByTimeAsync(MAP_REFRESH_MS * 3);
    expect(rpc).toHaveBeenCalledTimes(2);
    expect(getMapSyncStatus().state).toBe("idle");
  });

  it("shares one request between overlapping refreshes", async () => {
    let release!: () => void;
    const rpc = vi.fn(() => new Promise((resolve) => { release = () => resolve({ data: serverMap, error: null }); }));
    fakeClient(rpc);
    const a = refreshMap();
    const b = refreshMap();
    release();
    await Promise.all([a, b]);
    expect(rpc).toHaveBeenCalledTimes(1);
  });

  it("runs a fresh read after an existing poll when a game action completes", async () => {
    let release!: () => void;
    const rpc = vi.fn()
      .mockImplementationOnce(() => new Promise((resolve) => { release = () => resolve({ data: serverMap, error: null }); }))
      .mockResolvedValue({ data: serverMap, error: null });
    fakeClient(rpc);
    const poll = refreshMap();
    const afterAction = refreshMap({ afterCurrent: true });
    release();
    await Promise.all([poll, afterAction]);
    expect(rpc).toHaveBeenCalledTimes(2);
  });
  it("discards an old account's response and allows a new account to refresh immediately", async () => {
    vi.useFakeTimers();
    __setDemoStateForTests({ ...createSeedState(Date.now()), monuments: [], sessionUserId: "a" });
    let release!: (reply: unknown) => void;
    const rpc = vi.fn().mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }))
      .mockResolvedValue({ data: { ...serverMap, monuments: [] }, error: null });
    fakeClient(rpc);
    const stopA = startMapSync();
    stopA();
    __setDemoStateForTests({ ...createSeedState(Date.now()), monuments: [], sessionUserId: "b" });
    const stopB = startMapSync();
    await vi.advanceTimersByTimeAsync(0);
    expect(rpc).toHaveBeenCalledTimes(2);
    release({ data: serverMap, error: null });
    await vi.advanceTimersByTimeAsync(0);
    expect(getDemoState().monuments).toEqual([]);
    expect(getMapSyncStatus().state).toBe("ok");
    stopB();
  });

  it("ignores a response after logout even before effect cleanup", async () => {
    let release!: (reply: unknown) => void;
    fakeClient(vi.fn(() => new Promise((resolve) => { release = resolve; })));
    __setDemoStateForTests({ ...createSeedState(Date.now()), monuments: [], sessionUserId: "a" });
    const pending = refreshMap();
    __setDemoStateForTests({ ...createSeedState(Date.now()), monuments: [], sessionUserId: null });
    release({ data: serverMap, error: null });
    await pending;
    expect(getDemoState().monuments).toEqual([]);
  });

  it("refreshes on browser focus and visibility, and removes listeners on stop", async () => {
    const rpc = vi.fn(async () => ({ data: serverMap, error: null }));
    fakeClient(rpc);
    const stop = startMapSync();
    await refreshMap();
    window.dispatchEvent(new Event("focus"));
    await refreshMap();
    document.dispatchEvent(new Event("visibilitychange"));
    await refreshMap();
    expect(rpc).toHaveBeenCalledTimes(3);
    stop();
    window.dispatchEvent(new Event("focus"));
    document.dispatchEvent(new Event("visibilitychange"));
    expect(rpc).toHaveBeenCalledTimes(3);
  });

});
