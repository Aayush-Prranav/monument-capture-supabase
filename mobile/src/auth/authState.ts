// Whether the app knows yet who is signed in.
//
// With Supabase, the saved session is restored asynchronously when the app
// loads. Until that finishes, screens must not redirect to /login, or a
// signed-in player would bounce through the login page on every refresh.

import { useSyncExternalStore } from "react";

let ready = false;
const listeners = new Set<() => void>();

export function setAuthReady(value: boolean) {
  if (ready === value) return;
  ready = value;
  listeners.forEach((listener) => listener());
}

export function isAuthReady() {
  return ready;
}

export function useAuthReady() {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    isAuthReady,
    isAuthReady,
  );
}
