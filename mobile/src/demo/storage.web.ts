// Web: persists the game store in localStorage so it survives a page refresh.
// Each backend has its own key, so the local demo's fake players never leak
// into a Supabase session (and switching back restores the demo as it was).
import { backendMode } from "../backend/config";

const KEY = backendMode === "local" ? "monument-capture-demo" : "monument-capture-supabase-cache";

export const demoStorage = {
  load(): string | null {
    try {
      return window.localStorage.getItem(KEY);
    } catch {
      return null;
    }
  },
  save(value: string): boolean {
    try {
      window.localStorage.setItem(KEY, value);
      return true;
    } catch {
      // Private browsing or storage full: keep working in memory.
      return false;
    }
  },
  clear() {
    try {
      window.localStorage.removeItem(KEY);
    } catch {
      // ignore
    }
  },
};
