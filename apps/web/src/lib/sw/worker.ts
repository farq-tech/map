/**
 * The single service worker (public/sw.js) does two jobs: Web Push for
 * outings and offline areas. Its registration is shared, so neither job may
 * pull it out from under the other:
 *
 *   keep it registered while push is subscribed OR at least one offline area
 *   is saved; deleting the last area only clears the offline cache.
 *
 * This module is tiny on purpose: both the push code (outing chunk) and the
 * offline code import it without pulling each other in.
 */

export const SW_URL = "/sw.js";
/** Must equal CACHE in public/sw.js and OFFLINE_CACHE in lib/offline/offlineAreas.ts. */
export const OFFLINE_CACHE_NAME = "sary-offline-v1";

/** The combined rule. Pure, for tests. */
export function keepWorker(state: { pushSubscribed: boolean; offlineAreas: number }): boolean {
	return state.pushSubscribed || state.offlineAreas > 0;
}

function supported(): boolean {
	return typeof navigator !== "undefined" && "serviceWorker" in navigator;
}

/** Register (or reuse) the shared worker and wait until it is active. */
export async function ensureWorker(): Promise<ServiceWorkerRegistration> {
	const existing = await navigator.serviceWorker.getRegistration("/");
	if (existing?.active?.scriptURL.endsWith(SW_URL)) return existing;
	await navigator.serviceWorker.register(SW_URL, { scope: "/" });
	return navigator.serviceWorker.ready;
}

/** Tell the running worker whether offline areas exist, so it stops (or starts) reading the cache at once. */
export async function tellWorkerOffline(on: boolean): Promise<void> {
	if (!supported()) return;
	try {
		const regs = await navigator.serviceWorker.getRegistrations();
		for (const r of regs) if (r.active?.scriptURL.endsWith(SW_URL)) r.active.postMessage({ type: "sary-offline", on });
	} catch {
		/* best effort: the worker re-checks the cache when it next starts */
	}
}

async function offlineAreaCount(): Promise<number> {
	if (typeof caches === "undefined") return 0;
	try {
		if (!(await caches.has(OFFLINE_CACHE_NAME))) return 0;
		const res = await (await caches.open(OFFLINE_CACHE_NAME)).match(new URL("/__sary-offline/areas.json", location.origin).href);
		const list = res ? ((await res.json()) as unknown[]) : [];
		/* A cache with no readable index still holds files: treat it as in use. */
		return Array.isArray(list) ? Math.max(list.length, 1) : 1;
	} catch {
		return 0;
	}
}

/**
 * Unregister the shared worker only if nothing needs it any more. Call after
 * deleting the last offline area or after turning push off.
 */
export async function releaseWorkerIfUnused(): Promise<boolean> {
	if (!supported()) return false;
	const regs = (await navigator.serviceWorker.getRegistrations()).filter((r) => r.active?.scriptURL.endsWith(SW_URL));
	if (!regs.length) return false;
	const areas = await offlineAreaCount();
	let released = false;
	for (const r of regs) {
		const sub = await r.pushManager?.getSubscription().catch(() => null);
		if (keepWorker({ pushSubscribed: Boolean(sub), offlineAreas: areas })) continue;
		await r.unregister();
		released = true;
	}
	return released;
}
