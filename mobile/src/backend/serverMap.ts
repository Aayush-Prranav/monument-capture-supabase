// The game as the server sees it (public.get_game_state()), and how it is
// merged into the game store.
//
// The store stays the single thing screens read. In Supabase mode it is a
// cache of the server: monuments, current holds, the player's own captures
// with their reviews and, for moderators, the review queue. Every sync
// replaces all of it, so nothing local can drift from the database.

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

export type ServerReview = {
  id: string;
  decision: "approved" | "rejected";
  reason: string;
  reviewed_at: string;
  locked_until: string | null;
  moderator_id: string;
  moderator_name: string;
};

export type ServerCapture = {
  id: string;
  monument_id: string;
  player_id: string;
  status: Capture["status"];
  distance_m: number;
  reported_accuracy_m: number;
  flags: string[] | null;
  photo_path: string | null;
  started_at: string;
  submitted_at: string | null;
  expires_at?: string | null;
  review?: ServerReview | null;
  /** Review queue only. */
  player_name?: string;
};

export type ServerSettings = { lock_duration_s: number; max_accuracy_m: number; in_progress_ttl_s: number };

export type ServerMap = {
  server_now: string;
  monuments: ServerMonument[];
  settings?: ServerSettings;
  my_captures?: ServerCapture[];
  /** Moderators only: pending captures, oldest first. */
  review_queue?: ServerCapture[] | null;
};

/** Accepts only what the server promises; anything else is a server/version mismatch. */
export function parseServerMap(data: unknown): ServerMap {
  const map = data as Partial<ServerMap> | null;
  if (!map || typeof map.server_now !== "string" || !Array.isArray(map.monuments)) {
    throw new Error("The game server sent an unexpected reply.");
  }
  return map as ServerMap;
}

/** Photos live in Supabase Storage; screens resolve this marker to a signed URL. */
export const STORAGE_PHOTO_PREFIX = "storage:";

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

export function toCapture(c: ServerCapture): Capture {
  return {
    source: "server",
    id: c.id,
    monumentId: c.monument_id,
    playerId: c.player_id,
    status: c.status,
    distanceMeters: Math.round(c.distance_m),
    accuracyMeters: Math.round(c.reported_accuracy_m),
    simulatedPosition: false,
    photoUri: c.photo_path ? `${STORAGE_PHOTO_PREFIX}${c.photo_path}` : "",
    startedAt: Date.parse(c.started_at),
    submittedAt: c.submitted_at ? Date.parse(c.submitted_at) : null,
    flags: c.flags ?? [],
    expiresAt: c.expires_at ? Date.parse(c.expires_at) : undefined,
  };
}

export function toReview(captureId: string, r: ServerReview): CaptureReview {
  return {
    source: "server",
    id: r.id,
    captureId,
    moderatorId: r.moderator_id,
    decision: r.decision,
    reason: r.reason,
    reviewedAt: Date.parse(r.reviewed_at),
    lockedUntil: r.locked_until ? Date.parse(r.locked_until) : null,
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

/** Pure: the store after applying a fresh server state. */
export function applyServerMap(state: DemoState, map: ServerMap, sentAt: number, receivedAt: number): DemoState {
  const monuments = map.monuments.map(toMonument);

  // Fuller records win: own captures and queue entries over hold summaries.
  const captures = new Map<string, Capture>();
  const reviews = new Map<string, CaptureReview>(); // keyed by captureId
  const names = new Map<string, User>();
  const learn = (u: User) => {
    const known = names.get(u.id);
    names.set(u.id, known ? { ...known, name: u.name } : u);
  };

  for (const m of map.monuments) {
    const h = m.hold;
    if (!h) continue;
    const heldSince = Date.parse(h.held_since);
    captures.set(h.capture_id, {
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
    reviews.set(h.capture_id, {
      source: "server",
      id: `hold-${h.capture_id}`,
      captureId: h.capture_id,
      moderatorId: "",
      decision: "approved",
      reason: "",
      reviewedAt: heldSince,
      lockedUntil: Date.parse(h.locked_until),
    });
    learn({ id: h.holder_id, name: h.holder_name, email: "", role: "player" });
  }

  for (const c of [...(map.my_captures ?? []), ...(map.review_queue ?? [])]) {
    captures.set(c.id, toCapture(c));
    if (c.review) {
      reviews.set(c.id, toReview(c.id, c.review));
      learn({ id: c.review.moderator_id, name: c.review.moderator_name, email: "", role: "moderator" });
    }
    if (c.player_name) learn({ id: c.player_id, name: c.player_name, email: "", role: "player" });
  }

  // Keep the users we already know (the signed-in player has email and role);
  // only refresh their names from the server.
  const users = state.users.map((u) => {
    const fresh = names.get(u.id);
    names.delete(u.id);
    return fresh ? { ...u, name: fresh.name } : u;
  });
  users.push(...names.values());

  const s = map.settings;
  return {
    ...state,
    monuments,
    captures: [...captures.values()],
    reviews: [...reviews.values()],
    users,
    serverClockOffsetMs: clockOffsetMs(map.server_now, sentAt, receivedAt),
    serverSettings: s
      ? { lockDurationMs: s.lock_duration_s * 1000, maxAccuracyM: s.max_accuracy_m, inProgressTtlMs: s.in_progress_ttl_s * 1000 }
      : state.serverSettings,
  };
}
