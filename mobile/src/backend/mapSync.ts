// Keeps the map in sync with the server while a player is signed in
// (Supabase mode only): on sign-in, every 30 seconds, and whenever the tab
// comes back into view. Hold expiry needs no refresh: countdowns run on the
// database clock locally, and the next sync confirms them.

import { useSyncExternalStore } from "react";

import { demo } from "../demo/store";
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

/** Fetches get_map() once and applies it. Concurrent calls share one request. */
export function refreshMap(): Promise<void> {
  if (inFlight) return inFlight;
  inFlight = (async () => {
    if (status.state !== "ok") setStatus({ state: "loading" });
    const sentAt = Date.now();
    try {
      const { data, error } = await getSupabase().rpc("get_map");
      const receivedAt = Date.now();
      if (error) throw new Error(error.message);
      demo.applyServerMap(parseServerMap(data), sentAt, receivedAt);
      setStatus({ state: "ok", at: receivedAt });
    } catch (e) {
      const offline = e instanceof Error && /fetch|network/i.test(e.message);
      setStatus({
        state: "error",
        message: offline
          ? "Can't reach the game server. Showing the last map we had."
          : "The map couldn't be updated. Showing the last map we had.",
      });
    } finally {
      inFlight = null;
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
    clearInterval(timer);
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", onVisible);
    if (typeof window !== "undefined") window.removeEventListener("focus", onVisible);
    setStatus({ state: "idle" });
  };
}
