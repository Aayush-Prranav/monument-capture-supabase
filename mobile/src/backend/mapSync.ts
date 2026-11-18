// Keeps the map in sync with the server while a player is signed in
// (Supabase mode only): on sign-in, every 30 seconds, and whenever the tab
// comes back into view. Hold expiry needs no refresh: countdowns run on the
// database clock locally, and the next sync confirms them.

import { useSyncExternalStore } from "react";

import { demo, getDemoState } from "../demo/store";
import { parseServerMap } from "./serverMap";
import { getSupabase } from "./supabaseClient";

export const MAP_REFRESH_MS = 30_000;

export type MapSyncStatus =
  | { state: "idle" }
  | { state: "loading" }
  | { state: "ok"; at: number }
  | { state: "error"; message: string };

let status: MapSyncStatus = { state: "idle" };
const listeners = new Set<() => void>();

function setStatus(next: MapSyncStatus) {
  status = next;
  listeners.forEach((l) => l());
}

export function getMapSyncStatus() {
  return status;
}

export function useMapSyncStatus(): MapSyncStatus {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    getMapSyncStatus,
    getMapSyncStatus,
  );
}

let inFlight: Promise<void> | null = null;
let generation = 0;

/**
 * Fetches get_game_state() once and applies it. Ordinary concurrent calls
 * share one request. A mutation can request a fresh read after any existing
 * poll, so a response that started before the mutation cannot hide its result.
 */
export function refreshMap(options: { afterCurrent?: boolean } = {}): Promise<void> {
  if (inFlight) {
    if (!options.afterCurrent) return inFlight;
    const currentRequest = inFlight;
    const userId = getDemoState().sessionUserId;
    return currentRequest.then(() => {
      if (userId !== getDemoState().sessionUserId) return;
      return refreshMap();
    });
  }
  const requestGeneration = generation;
  const userId = getDemoState().sessionUserId;
  const current = () => requestGeneration === generation && userId === getDemoState().sessionUserId;
  inFlight = (async () => {
    if (status.state !== "ok") setStatus({ state: "loading" });
    const sentAt = Date.now();
    try {
      const { data, error } = await getSupabase().rpc("get_game_state");
      const receivedAt = Date.now();
      if (!current()) return;
      if (error) throw new Error(error.message);
      demo.applyServerMap(parseServerMap(data), sentAt, receivedAt);
      setStatus({ state: "ok", at: receivedAt });
    } catch (e) {
      if (!current()) return;
      const offline = e instanceof Error && /fetch|network/i.test(e.message);
      setStatus({
        state: "error",
        message: offline
          ? "Can't reach the game server. Showing the last map we had."
          : "The map couldn't be updated. Showing the last map we had.",
      });
    } finally {
      if (requestGeneration === generation) inFlight = null;
    }
  })();
  return inFlight;
}

/** Starts syncing; returns a function that stops it. */
export function startMapSync(): () => void {
  void refreshMap();
  const timer = setInterval(() => void refreshMap(), MAP_REFRESH_MS);
  const onVisible = () => {
    if (typeof document === "undefined" || document.visibilityState === "visible") void refreshMap();
  };
  if (typeof document !== "undefined") document.addEventListener("visibilitychange", onVisible);
  if (typeof window !== "undefined") window.addEventListener("focus", onVisible);
  return () => {
    generation++;
    inFlight = null;
    clearInterval(timer);
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", onVisible);
    if (typeof window !== "undefined") window.removeEventListener("focus", onVisible);
    setStatus({ state: "idle" });
  };
}
