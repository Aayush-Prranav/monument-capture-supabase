import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { PropsWithChildren } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import LoginScreen from "../../app/login";
import { createSeedState } from "../demo/seed";
import { __setDemoStateForTests } from "../demo/store";
import type { AuthBackend } from "./authBackend";
import { __setAuthBackendForTests } from "./AuthContext";
import { setAuthReady } from "./authState";
import { localAuth } from "./localAuth";

const router = vi.hoisted(() => ({ replace: vi.fn() }));
vi.mock("react-native", () => vi.importActual("react-native-web"));
vi.mock("@expo/vector-icons", () => ({ Ionicons: () => null }));
vi.mock("../components/Screen", () => ({ Screen: ({ children, subtitle }: PropsWithChildren<{ subtitle?: string }>) => (
  <div><p>{subtitle}</p>{children}</div>
) }));
vi.mock("expo-router", () => ({ router, Redirect: () => <p>redirected home</p> }));

function fakeSupabaseBackend(overrides: Partial<AuthBackend> = {}): AuthBackend {
  return {
    kind: "supabase",
    canSignUp: true,
    start: () => () => {},
    login: vi.fn(async () => ({ ok: false as const, message: "Invalid email or password." })),
    signUp: vi.fn(async () => ({ ok: true as const })),
    logout: vi.fn(async () => {}),
    ...overrides,
  };
}

const type = (label: string, value: string) => fireEvent.change(screen.getByLabelText(label), { target: { value } });

describe("login screen", () => {
  beforeEach(() => {
    __setDemoStateForTests(createSeedState(Date.now()));
    router.replace.mockClear();
  });
  afterEach(() => {
    cleanup();
    __setAuthBackendForTests(localAuth);
  });

  it("local mode: shows the demo accounts and no sign-up", () => {
    __setAuthBackendForTests(localAuth);
    render(<LoginScreen />);
    expect(screen.getByText("Demo accounts")).toBeTruthy();
    expect(screen.queryByText("New here? Create an account")).toBeNull();
  });

  it("Supabase mode: no demo accounts, and a way to create an account", () => {
    __setAuthBackendForTests(fakeSupabaseBackend());
    setAuthReady(true);
    render(<LoginScreen />);
    expect(screen.queryByText("Demo accounts")).toBeNull();
    expect(screen.getByText("New here? Create an account")).toBeTruthy();
  });

  it("Supabase mode: waits for the saved session before showing the form", () => {
    __setAuthBackendForTests(fakeSupabaseBackend());
    render(<LoginScreen />);
    expect(screen.getByLabelText("Loading")).toBeTruthy();
    expect(screen.queryByLabelText("Email")).toBeNull();
  });

  it("shows the server's message when login fails", async () => {
    __setAuthBackendForTests(fakeSupabaseBackend());
    setAuthReady(true);
    render(<LoginScreen />);
    type("Email", "ada@test.dev");
    type("Password", "nope");
    await act(async () => { fireEvent.click(screen.getByText("Log In")); });
    expect(screen.getByText("Invalid email or password.")).toBeTruthy();
    expect(router.replace).not.toHaveBeenCalled();
  });

  it("creates an account with a display name and goes to the map", async () => {
    const backend = fakeSupabaseBackend();
    __setAuthBackendForTests(backend);
    setAuthReady(true);
    render(<LoginScreen />);
    fireEvent.click(screen.getByText("New here? Create an account"));

    await act(async () => { fireEvent.click(screen.getByText("Create account")); });
    expect(screen.getByText("Please choose a display name.")).toBeTruthy();
    expect(backend.signUp).not.toHaveBeenCalled();

    type("Display name", "Ada");
    type("Email", "ada@test.dev");
    type("Password", "secret1");
    await act(async () => { fireEvent.click(screen.getByText("Create account")); });
    expect(backend.signUp).toHaveBeenCalledWith({ email: "ada@test.dev", password: "secret1", displayName: "Ada" });
    expect(router.replace).toHaveBeenCalledWith("/");
  });
});
