// The original US-01 mock login, unchanged in behaviour: demo accounts in the
// browser, one shared password. Used when EXPO_PUBLIC_BACKEND=local.

import { demo } from "../demo/store";
import type { AuthBackend } from "./authBackend";
import { setAuthReady } from "./authState";

export const localAuth: AuthBackend = {
  kind: "local",
  canSignUp: false,
  start() {
    setAuthReady(true);
    return () => {};
  },
  async login(email, password) {
    return demo.login(email, password) ? { ok: true } : { ok: false, message: "Invalid email or password." };
  },
  async signUp() {
    return { ok: false, message: "Creating accounts needs the Supabase backend." };
  },
  async logout() {
    demo.logout();
  },
};
