/**
 * Safe Web Storage helpers.
 *
 * Calls to `localStorage`/`sessionStorage` can throw in several real-world
 * environments:
 *   - Server-side rendering (no `window`)
 *   - Safari Private Browsing (quota = 0, throws on `setItem`)
 *   - Iframes/embeds where storage access is blocked
 *   - Quota exceeded
 *   - Browsers/users that have storage disabled entirely
 *
 * These helpers swallow those failures so feature code can ignore them. A
 * failed read returns `null`; a failed write returns `false`.
 */

type StorageKind = "localStorage" | "sessionStorage";

/**
 * Probe results, memoized per storage kind. The availability probe is a
 * setItem+removeItem write — doing it on EVERY read made each `safeGet` a
 * storage write. Availability doesn't change mid-session, so probe once and
 * cache the verdict. Later failures (e.g. quota on a real write) are still
 * caught by the per-operation try/catch in `safeGet`/`safeSet`/`safeRemove`.
 */
const probeCache: Partial<Record<StorageKind, boolean>> = {};

/**
 * Returns the requested Storage object only if it is genuinely usable
 * (probe-write succeeds). Otherwise returns `null`.
 */
function getStore(kind: StorageKind): Storage | null {
	if (typeof window === "undefined") return null;
	try {
		const s = window[kind];
		if (probeCache[kind] === undefined) {
			const k = "__farq_probe__";
			s.setItem(k, "1");
			s.removeItem(k);
			probeCache[kind] = true;
		}
		return probeCache[kind] ? s : null;
	} catch {
		probeCache[kind] = false;
		return null;
	}
}

export function safeGet(kind: StorageKind, key: string): string | null {
	const s = getStore(kind);
	if (!s) return null;
	try {
		return s.getItem(key);
	} catch {
		return null;
	}
}

export function safeSet(
	kind: StorageKind,
	key: string,
	value: string,
): boolean {
	const s = getStore(kind);
	if (!s) return false;
	try {
		s.setItem(key, value);
		return true;
	} catch {
		return false;
	}
}

export function safeRemove(kind: StorageKind, key: string): void {
	const s = getStore(kind);
	if (!s) return;
	try {
		s.removeItem(key);
	} catch {
		/* ignore */
	}
}
