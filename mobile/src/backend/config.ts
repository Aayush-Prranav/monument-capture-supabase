// Which backend the app talks to, chosen at build time from mobile/.env.
//
//   EXPO_PUBLIC_BACKEND=local     Everything in the browser (the original demo).
//   EXPO_PUBLIC_BACKEND=supabase  Real accounts in Supabase. Game data moves
//                                 over stage by stage (see supabase/README.md).
//
// Expo only inlines EXPO_PUBLIC_* variables when they are read exactly like
// this (process.env.EXPO_PUBLIC_NAME), so keep the reads literal.

export type BackendMode = "local" | "supabase";

export const backendMode: BackendMode =
  process.env.EXPO_PUBLIC_BACKEND?.trim().toLowerCase() === "supabase" ? "supabase" : "local";

export const supabaseUrl = process.env.EXPO_PUBLIC_SUPABASE_URL?.trim() ?? "";
export const supabasePublishableKey = process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim() ?? "";

/**
 * Demo tools (fake location, fast-forward clock, reset). Always on in local
 * mode; in Supabase mode only when EXPO_PUBLIC_DEV_TOOLS=true, so a public
 * deploy can be built without them.
 */
export const devToolsEnabled =
  backendMode === "local" || process.env.EXPO_PUBLIC_DEV_TOOLS?.trim().toLowerCase() === "true";
