import { describe, expect, it } from "vitest";
import {
  SUPPORTED_LOCALES,
  defaultLocale,
  normalizeLocale,
  resolveAcceptLanguage,
  resolveNavigatorLocale,
} from "./locales";

describe("locale discovery and device resolution", () => {
  it("registers ro in SUPPORTED_LOCALES while keeping en as fallback", () => {
    expect(SUPPORTED_LOCALES).toContain("ro");
    expect(SUPPORTED_LOCALES).toContain("en");
    expect(defaultLocale).toBe("en");
  });

  it("normalizes regional Romanian tags to ro", () => {
    expect(normalizeLocale("ro")).toBe("ro");
    expect(normalizeLocale("ro-RO")).toBe("ro");
    expect(normalizeLocale("ro_MD")).toBe("ro");
  });

  it("resolves Accept-Language headers using q-weights and fallbacks", () => {
    expect(resolveAcceptLanguage("ro-RO,ro;q=0.9,en-US;q=0.8,en;q=0.7")).toBe("ro");
    expect(resolveAcceptLanguage("uk-UA,ro;q=0.8,en;q=0.7")).toBe("ro");
    expect(resolveAcceptLanguage("ro;q=0.5,de;q=0.9")).toBe("de");
    expect(resolveAcceptLanguage("ro;q=0,en;q=0.8")).toBe("en");
    expect(resolveAcceptLanguage("ja-JP,ko-KR;q=0.8")).toBe("en");
    expect(resolveAcceptLanguage(null)).toBe("en");
    expect(resolveAcceptLanguage("")).toBe("en");
  });

  it("resolves navigator.languages lists in priority order", () => {
    expect(resolveNavigatorLocale(["uk-UA", "ro-RO", "en-US"], "en-US")).toBe("ro");
    expect(resolveNavigatorLocale([], "ro-MD")).toBe("ro");
    expect(resolveNavigatorLocale(undefined, "ja-JP")).toBe("en");
    expect(resolveNavigatorLocale(undefined, null)).toBe("en");
  });
});
