type LocaleMessages = Record<string, unknown>;
type LocaleModule = { default: LocaleMessages };
type LocaleLoader = () => Promise<LocaleMessages>;

const localeModules = import.meta.glob<LocaleModule>("./locales/*.json");

const localeEntries = Object.entries(localeModules)
  .map(([path, loadModule]) => {
    const match = path.match(/\/([a-z]{2,5}(?:-[a-z]{2,4})?)\.json$/i);
    if (!match) return null;

    const locale = match[1].toLowerCase();
    const loader: LocaleLoader = async () => (await loadModule()).default;
    return [locale, loader] as const;
  })
  .filter((entry): entry is readonly [string, LocaleLoader] => entry !== null);

export const LOCALE_LOADERS: Record<string, LocaleLoader> = Object.fromEntries(
  localeEntries,
);

export const SUPPORTED_LOCALES = Object.keys(LOCALE_LOADERS).sort();
export type SupportedLocale = string;

export const defaultLocale: SupportedLocale = SUPPORTED_LOCALES.includes("en")
  ? "en"
  : (SUPPORTED_LOCALES[0] ?? "en");

export function normalizeLocale(raw: string | null | undefined): SupportedLocale {
  if (!raw) return defaultLocale;

  // remove spaces and any ";q=0.7" part
  let tag = raw.trim().split(";")[0];

  // Turn "de_CH" into "de-CH"
  tag = tag.replace("_", "-");

  // Lowercase language, uppercase region if present
  const parts = tag.split("-");
  if (parts.length === 2) {
    tag = `${parts[0].toLowerCase()}-${parts[1].toUpperCase()}`;
  } else {
    tag = tag.toLowerCase();
  }

  // Map "de-CH" -> "de", "en-US" -> "en", etc.
  const base = tag.split("-")[0];

  if (SUPPORTED_LOCALES.includes(base)) {
    return base;
  }

  return defaultLocale;
}

function normalizeCandidateBase(raw: string | null | undefined): SupportedLocale | null {
  if (!raw) return null;
  const tag = raw.trim().split(";")[0]?.trim();
  if (!tag || tag === "*") return null;
  const base = tag.replace("_", "-").split("-")[0]?.toLowerCase();
  if (base && SUPPORTED_LOCALES.includes(base)) {
    return base;
  }
  return null;
}

/**
 * Resolves the best supported locale from an RFC 9110 `Accept-Language` header,
 * honoring quality (`q=`) weights and preferring earlier entries on ties.
 */
export function resolveAcceptLanguage(header: string | null | undefined): SupportedLocale {
  if (!header) return defaultLocale;

  const parsed = header
    .split(",")
    .map((part, index) => {
      const [rawTag, ...params] = part.split(";");
      let q = 1;
      for (const param of params) {
        const trimmed = param.trim().toLowerCase();
        if (trimmed.startsWith("q=")) {
          const parsedQ = Number(trimmed.slice(2));
          q = Number.isFinite(parsedQ) ? parsedQ : 0;
        }
      }
      return { tag: rawTag?.trim() ?? "", q, index };
    })
    .filter((entry) => entry.tag.length > 0 && entry.q > 0)
    .sort((a, b) => (b.q !== a.q ? b.q - a.q : a.index - b.index));

  for (const entry of parsed) {
    const match = normalizeCandidateBase(entry.tag);
    if (match) return match;
  }

  return defaultLocale;
}

/**
 * Resolves the best supported locale from `navigator.languages` and `navigator.language`.
 */
export function resolveNavigatorLocale(
  languages: readonly string[] | undefined,
  singleLanguage?: string | null,
): SupportedLocale {
  const candidates: string[] = [];
  if (languages && languages.length > 0) {
    candidates.push(...languages);
  }
  if (singleLanguage) {
    candidates.push(singleLanguage);
  }

  for (const candidate of candidates) {
    const match = normalizeCandidateBase(candidate);
    if (match) return match;
  }

  return defaultLocale;
}
