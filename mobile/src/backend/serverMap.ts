// Stage 2: the map as the server sees it (public.get_map()), and how it is
// merged into the game store.
//
// The store stays the single thing screens read. In Supabase mode the
// monuments and the CURRENT holds come from the server; anything the player
// did locally that later stages haven't moved yet (captures in progress,
// reviews) is kept if it still refers to a monument the server knows.

import type { Capture, CaptureReview, DemoState, Monument, User } from "../demo/types";

export type ServerHold = {
  capture_id: string;
  holder_id: string;
  holder_name: string;
  held_since: string;
  locked_until: string;
};

export type ServerMonument = {
  id: string;
  slug: string | null;
  name: string;
  neighborhood: string;
  description: string;
  icon: string | null;
  latitude: number;
  longitude: number;
  capture_radius_m: number;
  active: boolean;
  is_test: boolean;
  hold: ServerHold | null;
};

export type ServerMap = { server_now: string; monuments: ServerMonument[] };

/** Accepts only what get_map() promises; anything else is a server/version mismatch. */
export function parseServerMap(data: unknown): ServerMap {
  const map = data as Partial<ServerMap> | null;
  if (!map || typeof map.server_now !== "string" || !Array.isArray(map.monuments)) {
    throw new Error("The game server sent an unexpected map.");
  }
  return map as ServerMap;
}

export function toMonument(m: ServerMonument): Monument {
  return {
    id: m.id,
    name: m.name,
    neighborhood: m.neighborhood,
    description: m.description,
    latitude: m.latitude,
    longitude: m.longitude,
    captureRadiusMeters: m.capture_radius_m,
    icon: m.icon ?? undefined,
    active: m.active,
  };
}

/**
 * Database clock minus device clock. The request's midpoint stands in for
 * the moment the server read its clock, which halves the network delay error.
 */
export function clockOffsetMs(serverNow: string, sentAt: number, receivedAt: number): number {
  const server = Date.parse(serverNow);
  if (!Number.isFinite(server)) return 0;
  return Math.round(server - (sentAt + receivedAt) / 2);
}

/** Pure: the store after applying a fresh server map. */
export function applyServerMap(state: DemoState, map: ServerMap, sentAt: number, receivedAt: number): DemoState {
  const monuments = map.monuments.map(toMonument);
  const known = new Set(monuments.map((m) => m.id));

  const holdCaptures: Capture[] = [];
  const holdReviews: CaptureReview[] = [];
  const holders: User[] = [];
  for (const m of map.monuments) {
    const h = m.hold;
    if (!h) continue;
    const heldSince = Date.parse(h.held_since);
    holdCaptures.push({
      source: "server",
      id: h.capture_id,
      monumentId: m.id,
      playerId: h.holder_id,
      status: "approved",
      distanceMeters: 0,
      accuracyMeters: 0,
      simulatedPosition: false,
      photoUri: "",
      startedAt: heldSince,
      submittedAt: heldSince,
    });
    holdReviews.push({
      source: "server",
      id: `hold-${h.capture_id}`,
      captureId: h.capture_id,
      moderatorId: "",
      decision: "approved",
      reason: "",
      reviewedAt: heldSince,
      lockedUntil: Date.parse(h.locked_until),
    });
    holders.push({ id: h.holder_id, name: h.holder_name, email: "", role: "player" });
  }

  // Keep local work that still points at a real monument; drop old server copies.
  const localCaptures = state.captures.filter((c) => c.source !== "server" && known.has(c.monumentId));
  const captures = [...localCaptures, ...holdCaptures];
  const captureIds = new Set(captures.map((c) => c.id));
  const localReviews = state.reviews.filter((r) => r.source !== "server" && captureIds.has(r.captureId));
  const reviews = [...localReviews, ...holdReviews];

  // Holders become known users (name only). Never overwrite a fuller record,
  // e.g. the signed-in player's own, which has their email and role.
  const users = [...state.users];
  for (const holder of holders) {
    const i = users.findIndex((u) => u.id === holder.id);
    const existing = users[i];
    if (!existing) users.push(holder);
    else users[i] = { ...existing, name: holder.name };
  }

  return {
    ...state,
    monuments,
    captures,
    reviews,
    users,
    serverClockOffsetMs: clockOffsetMs(map.server_now, sentAt, receivedAt),
  };
}
