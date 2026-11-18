// Every change a player or moderator makes to the game goes through here.
//
// Local mode: the original rules in the browser (demo/store.ts).
// Supabase mode: a Postgres function called with rpc(); the server decides,
// then the app re-reads the game state. The client never writes a table.
//
// Screens only ever see { ok: true, ... } or { ok: false, message }.

import { formatDistance, formatRemaining, RuleError } from "../demo/rules";
import { demo, demoNow, getDemoState } from "../demo/store";
import type { PlayerPosition } from "../features/capture/types";
import { backendMode } from "./config";
import { refreshMap } from "./mapSync";
import { getSupabase } from "./supabaseClient";

export type Failure = { ok: false; message: string; code?: string };
export type Result<T extends object = object> = ({ ok: true } & T) | Failure;

const OFFLINE = "Can't reach the game server. Check your connection and try again.";

function failure(e: unknown, fallback: string): Failure {
  if (e instanceof RuleError) return { ok: false, message: e.message };
  if (e instanceof Error && /fetch|network/i.test(e.message)) return { ok: false, message: OFFLINE };
  return { ok: false, message: e instanceof Error && e.message ? e.message : fallback };
}

// ---------------------------------------------------------------------------
// Messages for the server's refusal codes
// ---------------------------------------------------------------------------

type StartRefusal = {
  ok: false;
  code: string;
  distance_m?: number;
  radius_m?: number;
  accuracy_m?: number;
  max_accuracy_m?: number;
  holder_name?: string;
  locked_until?: string;
};

export function startRefusalMessage(r: StartRefusal, now = demoNow()): string {
  switch (r.code) {
    case "not_a_player":
      return "Only players capture monuments.";
    case "monument_unavailable":
      return "This monument is not available for capture.";
    case "bad_position":
      return "Your location couldn't be read. Retry for a current location.";
    case "inaccurate":
      return `Your GPS signal is not accurate enough (needs ${r.max_accuracy_m ?? 50} m or better). Move to an open area and retry.`;
    case "too_far": {
      const d = r.distance_m ?? 0;
      const closer = Math.max(1, d - (r.radius_m ?? 0));
      return `You are about ${formatDistance(d)} away. Move ${formatDistance(closer)} closer and retry.`;
    }
    case "held":
    case "held_by_you": {
      const left = r.locked_until ? formatRemaining(Date.parse(r.locked_until) - now) : "a while";
      const who = r.code === "held_by_you" ? "you" : (r.holder_name ?? "another player");
      return `Held by ${who} for another ${left}. Come back when the lock expires.`;
    }
    case "already_pending":
      return "You already have a capture of this monument waiting for review.";
    default:
      return "The capture couldn't be started. Try again.";
  }
}

export function submitRefusalMessage(code: string): string {
  switch (code) {
    case "expired":
      return "Your check-in expired before the photo was submitted. Check in again at the monument.";
    case "not_in_progress":
      return "This capture was already submitted or cancelled.";
    case "not_found":
      return "This capture no longer exists. Check in again at the monument.";
    case "photo_missing":
      return "The photo didn't finish uploading. Try submitting again.";
    default:
      return "The capture couldn't be submitted. Try again.";
  }
}

export const PHOTO_BUCKET = "capture-photos";

/** Where a capture's photo must be uploaded; the server only accepts this path. */
export function capturePhotoPath(playerId: string, captureId: string) {
  return `${playerId}/${captureId}.jpg`;
}

/** A photo from the camera or picker (a JPEG data URL) as an uploadable file. */
export async function photoToJpegBlob(photoUri: string): Promise<Blob> {
  const blob = await (await fetch(photoUri)).blob();
  if (blob.type !== "image/jpeg") {
    throw new Error("That photo couldn't be prepared for upload. Take it again with the camera.");
  }
  return blob;
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

export const game = {
  /** Checks in at a monument. The server computes the distance and decides. */
  async startCapture(
    monumentId: string,
    position: PlayerPosition,
    simulated: boolean,
  ): Promise<Result<{ captureId: string }>> {
    if (backendMode === "local") {
      try {
        const user = getDemoState().sessionUserId;
        if (!user) return { ok: false, message: "Sign in first." };
        const capture = demo.startCapture(monumentId, user, position, simulated);
        return { ok: true, captureId: capture.id };
      } catch (e) {
        return failure(e, "Could not start the capture.");
      }
    }
    try {
      const { data, error } = await getSupabase().rpc("start_capture", {
        p_monument_id: monumentId,
        p_latitude: position.latitude,
        p_longitude: position.longitude,
        p_accuracy_m: position.accuracyMeters,
      });
      if (error) throw new Error(error.message);
      const reply = data as { ok: true; capture: { id: string } } | StartRefusal;
      await refreshMap();
      if (!reply.ok) return { ok: false, code: reply.code, message: startRefusalMessage(reply) };
      return { ok: true, captureId: reply.capture.id };
    } catch (e) {
      return failure(e, "Could not start the capture.");
    }
  },

  /**
   * Uploads the photo straight to Storage (the bytes never pass through a
   * function), then asks the server to submit the capture for review. The
   * server checks the photo is really there before accepting.
   */
  async submitCapture(captureId: string, photoUri: string): Promise<Result> {
    if (backendMode === "local") {
      try {
        demo.submitPhoto(captureId, photoUri);
        return { ok: true };
      } catch (e) {
        return failure(e, "Could not submit the capture.");
      }
    }
    const playerId = getDemoState().sessionUserId;
    if (!playerId) return { ok: false, message: "Sign in first." };
    try {
      const client = getSupabase();
      const blob = await photoToJpegBlob(photoUri);
      const upload = await client.storage
        .from(PHOTO_BUCKET)
        .upload(capturePhotoPath(playerId, captureId), blob, { contentType: "image/jpeg", upsert: false });
      // A retry after a failed submit finds the photo already there: that's fine.
      if (upload.error && !/exists|duplicate/i.test(upload.error.message)) {
        throw new Error(
          /row-level security|unauthori[sz]ed|403/i.test(upload.error.message)
            ? submitRefusalMessage("expired")
            : upload.error.message,
        );
      }
      const { data, error } = await client.rpc("submit_capture", { p_capture_id: captureId });
      if (error) throw new Error(error.message);
      const reply = data as { ok: true } | { ok: false; code: string };
      await refreshMap();
      if (!reply.ok) return { ok: false, code: reply.code, message: submitRefusalMessage(reply.code) };
      return { ok: true };
    } catch (e) {
      return failure(e, "Could not submit the capture.");
    }
  },

  /** Abandons a capture that hasn't been submitted. */
  async cancelCapture(captureId: string): Promise<Result> {
    if (backendMode === "local") {
      demo.cancelCapture(captureId);
      return { ok: true };
    }
    try {
      const { error } = await getSupabase().rpc("cancel_capture", { p_capture_id: captureId });
      if (error) throw new Error(error.message);
      await refreshMap();
      return { ok: true };
    } catch (e) {
      return failure(e, "Could not cancel the capture.");
    }
  },
};
