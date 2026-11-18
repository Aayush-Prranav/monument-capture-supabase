// Extends app.json. EXPO_BASE_URL lets the web build live under a subpath,
// e.g. GitHub Pages serves this repo at /monument-capture-supabase/. Unset
// for local development, so `npm run web` still serves at the root.
module.exports = ({ config }) => ({
  ...config,
  experiments: {
    ...config.experiments,
    ...(process.env.EXPO_BASE_URL ? { baseUrl: process.env.EXPO_BASE_URL } : {}),
  },
});
