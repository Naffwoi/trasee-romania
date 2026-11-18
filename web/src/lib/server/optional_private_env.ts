/**
 * Safely read an optional private environment variable from a SvelteKit `$app/env/private`
 * module namespace without throwing when partial test mocks omit optional keys.
 */
export function readOptionalPrivateEnv(privateEnvMod: object, name: string): string {
	try {
		const val = (privateEnvMod as Record<string, unknown>)[name];
		if (typeof val === "string") {
			return val.trim();
		}
	} catch {
		// Partial Vitest mocks of $app/env/private throw on unmocked property lookups.
	}
	return (typeof process !== "undefined" ? process.env[name] ?? "" : "").trim();
}
