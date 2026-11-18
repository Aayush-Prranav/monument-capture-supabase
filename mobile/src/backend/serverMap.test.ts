import { describe, expect, it } from "vitest";

import { getHold } from "../demo/rules";
import { createSeedState } from "../demo/seed";
import type { DemoState } from "../demo/types";
import { monumentViews } from "../demo/views";
import { applyServerMap, clockOffsetMs, parseServerMap, type ServerMap, type ServerMonument } from "./serverMap";

const T0 = Date.parse("2026-11-18T00:30:00Z");
const ME = "aaaaaaaa-0000-0000-0000-000000000001";
const OTHER = "aaaaaaaa-0000-0000-0000-000000000002";

const monument = (id: string, extra: Partial<ServerMonument> = {}): ServerMonument => ({
  id, slug: id, name: `M ${id}`, neighborhood: "Brooklyn", description: "", icon: "📍",
  latitude: 40.69, longitude: -73.98, capture_radius_m: 100, active: true, is_test: false, hold: null, ...extra,
});

const map = (monuments: ServerMonument[], serverNow = new Date(T0).toISOString()): ServerMap => ({ server_now: serverNow, monuments });

/** A signed-in Supabase player in an empty Supabase-mode world. */
function world(): DemoState {
  const seed = createSeedState(T0);
  return {
    ...seed,
    users: [{ id: ME, name: "Ada", email: "ada@test.dev", role: "player" }],
    monuments: [],
    captures: [],
    reviews: [],
    sessionUserId: ME,
  };
}

const heldBy = (who: string, name: string, minutesLeft: number) => ({
  capture_id: `cap-${who}`,
  holder_id: who,
  holder_name: name,
  held_since: new Date(T0 - 10 * 60_000).toISOString(),
  locked_until: new Date(T0 + minutesLeft * 60_000).toISOString(),
});

describe("applying the server map", () => {
  it("replaces monuments with the server's, mapping field names", () => {
    const next = applyServerMap(world(), map([monument("m1", { name: "Bethesda Fountain", capture_radius_m: 100, icon: "⛲" })]), T0, T0);
    expect(next.monuments).toEqual([{
      id: "m1", name: "Bethesda Fountain", neighborhood: "Brooklyn", description: "",
      latitude: 40.69, longitude: -73.98, captureRadiusMeters: 100, icon: "⛲", active: true,
    }]);
  });

  it("shows another player's hold with their display name and countdown", () => {
    const next = applyServerMap(world(), map([monument("m1", { hold: heldBy(OTHER, "Grace", 30) })]), T0, T0);
    const hold = getHold(next, "m1", T0);
    expect(hold.status).toBe("held");
    if (hold.status === "held") {
      expect(hold.holder.name).toBe("Grace");
      expect(hold.lockedUntil - T0).toBe(30 * 60_000);
    }
    const [view] = monumentViews(next, ME, T0);
    expect(view?.kind).toBe("held");
    expect(view?.statusLine).toBe("Held by Grace · 30 min left");
  });

  it("recognises the signed-in player's own hold, without losing their email", () => {
    const next = applyServerMap(world(), map([monument("m1", { hold: heldBy(ME, "Ada", 5) })]), T0, T0);
    expect(monumentViews(next, ME, T0)[0]?.kind).toBe("mine");
    expect(next.users.find((u) => u.id === ME)).toMatchObject({ email: "ada@test.dev", role: "player" });
  });

  it("a later sync without the hold frees the monument (no stale copies)", () => {
    const first = applyServerMap(world(), map([monument("m1", { hold: heldBy(OTHER, "Grace", 30) })]), T0, T0);
    const second = applyServerMap(first, map([monument("m1")]), T0, T0);
    expect(getHold(second, "m1", T0).status).toBe("free");
    expect(second.captures).toHaveLength(0);
    expect(second.reviews).toHaveLength(0);
  });

  it("replaces everything with the server's copy: local leftovers are dropped", () => {
    const base = world();
    base.captures = [
      { id: "local-1", monumentId: "m1", playerId: ME, status: "in_progress", distanceMeters: 5, accuracyMeters: 5,
        simulatedPosition: false, photoUri: "", startedAt: T0, submittedAt: null },
    ];
    const next = applyServerMap(base, map([monument("m1")]), T0, T0);
    expect(next.captures).toEqual([]);
  });

  it("hides nothing a moderator should see: inactive monuments come through marked inactive", () => {
    const next = applyServerMap(world(), map([monument("m1", { active: false })]), T0, T0);
    expect(next.monuments[0]?.active).toBe(false);
    expect(monumentViews(next, ME, T0)).toHaveLength(0);
    expect(monumentViews(next, ME, T0, true)[0]?.kind).toBe("inactive");
  });
});

describe("own captures and settings", () => {
  it("brings in the player's captures with flags, photo marker, expiry and review", () => {
    const next = applyServerMap(world(), {
      ...map([monument("m1")]),
      settings: { lock_duration_s: 3600, max_accuracy_m: 50, in_progress_ttl_s: 600 },
      my_captures: [{
        id: "c1", monument_id: "m1", player_id: ME, status: "rejected", distance_m: 41.6, reported_accuracy_m: 7.4,
        flags: ["exact_pin"], photo_path: `${ME}/c1.jpg`,
        started_at: new Date(T0 - 60_000).toISOString(), submitted_at: new Date(T0 - 30_000).toISOString(),
        expires_at: new Date(T0 + 540_000).toISOString(),
        review: { id: "r1", decision: "rejected", reason: "Blurry", reviewed_at: new Date(T0).toISOString(),
                  locked_until: null, moderator_id: "mod-1", moderator_name: "Mod" },
      }],
    }, T0, T0);
    expect(next.captures).toEqual([expect.objectContaining({
      id: "c1", status: "rejected", distanceMeters: 42, accuracyMeters: 7, flags: ["exact_pin"],
      photoUri: `storage:${ME}/c1.jpg`, expiresAt: T0 + 540_000,
    })]);
    expect(next.reviews).toEqual([expect.objectContaining({ captureId: "c1", decision: "rejected", reason: "Blurry", moderatorId: "mod-1" })]);
    expect(next.users.find((u) => u.id === "mod-1")).toMatchObject({ name: "Mod", role: "moderator" });
    expect(next.serverSettings).toEqual({ lockDurationMs: 3_600_000, maxAccuracyM: 50, inProgressTtlMs: 600_000 });
  });
});

describe("server clock", () => {
  it("measures the database clock against the device clock at the request midpoint", () => {
    // Device clock 2 minutes slow: server says T0, request took 400 ms around T0 - 2 min.
    const sentAt = T0 - 120_000 - 200;
    const receivedAt = T0 - 120_000 + 200;
    expect(clockOffsetMs(new Date(T0).toISOString(), sentAt, receivedAt)).toBe(120_000);
  });

  it("is stored with the map, so countdowns use server time", () => {
    const next = applyServerMap(world(), map([], new Date(T0 + 5_000).toISOString()), T0, T0);
    expect(next.serverClockOffsetMs).toBe(5_000);
  });

  it("ignores an unreadable server time", () => {
    expect(clockOffsetMs("not a date", T0, T0)).toBe(0);
  });
});

describe("parsing", () => {
  it("rejects anything that isn't a map", () => {
    expect(() => parseServerMap(null)).toThrow();
    expect(() => parseServerMap({ monuments: [] })).toThrow();
    expect(parseServerMap(map([])).monuments).toEqual([]);
  });
});
