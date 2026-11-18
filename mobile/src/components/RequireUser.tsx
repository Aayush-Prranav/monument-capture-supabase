import { Redirect } from "expo-router";
import type { ReactNode } from "react";
import { ActivityIndicator, StyleSheet, View } from "react-native";

import { useAuth } from "../auth/AuthContext";
import { theme } from "../constants/theme";
import type { Role, User } from "../demo/types";
import { Screen } from "./Screen";
import { Banner } from "./ui";

/** Sends signed-out visitors to /login and blocks screens meant for another role. */
export function RequireUser({ role, children }: { role?: Role; children: (user: User) => ReactNode }) {
  const { ready, user, backend } = useAuth();
  // Still restoring a saved session: wait rather than bounce through /login.
  if (!ready) {
    return (
      <View accessibilityLabel="Loading" style={styles.loading}>
        <ActivityIndicator color={theme.colors.primary} size="large" />
      </View>
    );
  }
  if (!user) return <Redirect href="/login" />;
  if (role && user.role !== role) {
    const hint = backend === "local"
      ? "Switch account from Profile to use it."
      : "Ask a moderator if you need access.";
    return (
      <Screen title="Not available" back>
        <Banner tone="warning">{`This screen is only for ${role}s. ${hint}`}</Banner>
      </Screen>
    );
  }
  return <>{children(user)}</>;
}

const styles = StyleSheet.create({
  loading: { alignItems: "center", flex: 1, justifyContent: "center", padding: 40 },
});
