import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { supabasePublishableKey, supabaseUrl } from "./config";

let client: SupabaseClient | null = null;

/**
 * The one Supabase client for the app, created on first use.
 *
 * Only the publishable key is ever used here. It is safe in the browser
 * because the database grants the browser SELECT on a few tables and nothing
 * else (supabase/migrations/*_security.sql). Never put the secret key in the app.
 */
export function getSupabase(): SupabaseClient {
  if (client) return client;
  if (!supabaseUrl || !supabasePublishableKey) {
    throw new Error(
      "Supabase is not configured. Set EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY in mobile/.env (see mobile/.env.example).",
    );
  }
  client = createClient(supabaseUrl, supabasePublishableKey, {
    auth: {
      // Web: the session is kept in localStorage and refreshed automatically.
      // Native would need an AsyncStorage adapter; this project targets the web.
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  });
  return client;
}

/** Test helper: inject a fake client. */
export function __setSupabaseForTests(fake: SupabaseClient | null) {
  client = fake;
}
