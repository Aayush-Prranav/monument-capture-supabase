import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
    // Tests must not depend on the shell or CI environment: pin the backend
    // to the local demo. Supabase-mode code is tested with injected fakes.
    env: {
      EXPO_PUBLIC_BACKEND: "local",
      EXPO_PUBLIC_DEV_TOOLS: "",
      EXPO_PUBLIC_SUPABASE_URL: "",
      EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "",
    },
  },
});
