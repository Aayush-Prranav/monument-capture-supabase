import { Ionicons } from "@expo/vector-icons";
import { Redirect, router } from "expo-router";
import { useState } from "react";
import { ActivityIndicator, StyleSheet, Text, TextInput, View } from "react-native";

import { useAuth } from "../src/auth/AuthContext";
import { Screen } from "../src/components/Screen";
import { Banner, Button, Card, SectionTitle } from "../src/components/ui";
import { theme } from "../src/constants/theme";
import { DEMO_PASSWORD, seedUsers } from "../src/demo/seed";

type Mode = "login" | "signup";

// US-01: email + password login and its error messages are Iris's design.
// With the Supabase backend the same form also creates accounts; with the
// local backend the demo-account shortcuts fill the form for quick demos.
export default function LoginScreen() {
  const { ready, isLoggedIn, login, signUp, canSignUp, backend } = useAuth();
  const [mode, setMode] = useState<Mode>("login");
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  if (!ready) {
    return (
      <View accessibilityLabel="Loading" style={styles.loading}>
        <ActivityIndicator color={theme.colors.primary} size="large" />
      </View>
    );
  }
  if (isLoggedIn) return <Redirect href="/" />;

  const signingUp = mode === "signup";

  async function submit(address = email, secret = password) {
    setError("");
    if (signingUp && !displayName.trim()) {
      setError("Please choose a display name.");
      return;
    }
    if (!address.trim() || !secret) {
      setError("Please enter your email and password.");
      return;
    }
    setBusy(true);
    try {
      const result = signingUp
        ? await signUp({ email: address, password: secret, displayName })
        : await login(address, secret);
      if (result.ok) router.replace("/");
      else setError(result.message);
    } catch {
      setError("Can't reach the game server. Check your connection and try again.");
    } finally {
      setBusy(false);
    }
  }

  function switchMode(next: Mode) {
    setMode(next);
    setError("");
  }

  const clearError = (set: (v: string) => void) => (t: string) => {
    set(t);
    setError("");
  };

  return (
    <Screen title="Monument Capture" subtitle={signingUp ? "Create your account" : "Log in to your account"}>
      <View style={styles.hero}>
        <Ionicons color={theme.colors.primary} name="flag" size={40} />
        <Text style={styles.heroText}>Claim real monuments by standing next to them. Hold them to win.</Text>
      </View>

      <Card>
        {signingUp ? (
          <TextInput
            accessibilityLabel="Display name"
            autoCapitalize="words"
            maxLength={40}
            onChangeText={clearError(setDisplayName)}
            placeholder="Display name (shown to other players)"
            placeholderTextColor={theme.colors.muted}
            style={styles.input}
            value={displayName}
          />
        ) : null}
        <TextInput
          accessibilityLabel="Email"
          autoCapitalize="none"
          autoComplete="email"
          keyboardType="email-address"
          onChangeText={clearError(setEmail)}
          placeholder="Email"
          placeholderTextColor={theme.colors.muted}
          style={styles.input}
          value={email}
        />
        <TextInput
          accessibilityLabel="Password"
          autoComplete={signingUp ? "new-password" : "password"}
          onChangeText={clearError(setPassword)}
          onSubmitEditing={() => void submit()}
          placeholder={signingUp ? "Password (at least 6 characters)" : "Password"}
          placeholderTextColor={theme.colors.muted}
          secureTextEntry
          style={styles.input}
          value={password}
        />
        {error ? <Banner tone="danger">{error}</Banner> : null}
        <Button
          disabled={busy}
          icon={signingUp ? "person-add-outline" : "log-in-outline"}
          label={busy ? "Please wait…" : signingUp ? "Create account" : "Log In"}
          onPress={() => void submit()}
        />
        {canSignUp ? (
          <Text
            accessibilityRole="button"
            onPress={() => switchMode(signingUp ? "login" : "signup")}
            style={styles.switch}
          >
            {signingUp ? "Already have an account? Log in" : "New here? Create an account"}
          </Text>
        ) : null}
      </Card>

      {backend === "local" ? (
        <>
          <SectionTitle>Demo accounts</SectionTitle>
          <Text style={styles.hint}>{`Every demo account uses the password ${DEMO_PASSWORD}. Tap one to log in.`}</Text>
          {seedUsers.map((u) => (
            <Card
              key={u.id}
              onPress={() => {
                setEmail(u.email);
                setPassword(DEMO_PASSWORD);
                void submit(u.email, DEMO_PASSWORD);
              }}
              style={styles.account}
            >
              <View style={[styles.avatar, u.role === "moderator" && { backgroundColor: theme.colors.warningSoft }]}>
                <Ionicons
                  color={u.role === "moderator" ? theme.colors.warning : theme.colors.primary}
                  name={u.role === "moderator" ? "shield-checkmark" : "person"}
                  size={20}
                />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.accountName}>{u.name}</Text>
                <Text style={styles.accountMeta}>{u.email} · {u.role === "moderator" ? "Moderator" : "Player"}</Text>
              </View>
              <Ionicons color={theme.colors.muted} name="chevron-forward" size={20} />
            </Card>
          ))}
        </>
      ) : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  loading: { alignItems: "center", flex: 1, justifyContent: "center", padding: 40 },
  hero: {
    alignItems: "center",
    backgroundColor: theme.colors.primarySoft,
    borderRadius: theme.radius.large,
    gap: theme.spacing.small,
    padding: theme.spacing.large,
  },
  heroText: { color: theme.colors.text, fontSize: 16, fontWeight: "600", textAlign: "center" },
  input: {
    backgroundColor: theme.colors.background,
    borderColor: theme.colors.border,
    borderRadius: 14,
    borderWidth: 1,
    color: theme.colors.text,
    fontSize: 16,
    padding: 14,
  },
  switch: { color: theme.colors.primary, fontWeight: "700", textAlign: "center", paddingVertical: 4 },
  hint: { color: theme.colors.muted, marginTop: -10 },
  account: { alignItems: "center", flexDirection: "row", gap: theme.spacing.medium },
  avatar: {
    alignItems: "center",
    backgroundColor: theme.colors.primarySoft,
    borderRadius: 20,
    height: 40,
    justifyContent: "center",
    width: 40,
  },
  accountName: { color: theme.colors.text, fontSize: 16, fontWeight: "800" },
  accountMeta: { color: theme.colors.muted, marginTop: 2 },
});
