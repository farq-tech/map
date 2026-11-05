import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { keepWorker, OFFLINE_CACHE_NAME } from "./worker";
import { OFFLINE_CACHE } from "../offline/offlineAreas";

const SRC = readFileSync(resolve(__dirname, "../../../public/sw.js"), "utf8");

/** Evaluate public/sw.js against a fake worker global; returns its listeners and exports. */
function boot(opts: { cacheHas?: boolean } = {}) {
	const listeners: Record<string, (e: unknown) => void> = {};
	const self = {
		location: { origin: "https://sary.example" },
		addEventListener: (t: string, fn: (e: unknown) => void) => (listeners[t] = fn),
		skipWaiting: vi.fn(),
		clients: { claim: vi.fn(async () => undefined), matchAll: vi.fn(async () => []), openWindow: vi.fn() },
		registration: { showNotification: vi.fn(async () => undefined) },
	};
	const caches = { has: vi.fn(async () => Boolean(opts.cacheHas)), open: vi.fn(async () => ({ match: async () => undefined })) };
	const mod = { exports: {} as Record<string, unknown> };
	new Function("module", "self", "caches", SRC)(mod, self, caches);
	return { listeners, self, caches, sw: mod.exports as { offlineDecision: (r: string, h: boolean | null) => string; notificationFor: (d: unknown) => { title: string; options: { requireInteraction: boolean; tag: string; data: { url: string } } }; CACHE: string } };
}

function fetchEvent(url: string, method = "GET", mode = "cors") {
	return { request: { url, method, mode }, respondWith: vi.fn((p: Promise<unknown>) => void p.catch(() => undefined)) };
}

describe("one service worker for push and offline", () => {
	it("stays registered while push is subscribed OR an offline area exists", () => {
		expect(keepWorker({ pushSubscribed: false, offlineAreas: 0 })).toBe(false);
		expect(keepWorker({ pushSubscribed: true, offlineAreas: 0 })).toBe(true); // deleting the last area must not kill push
		expect(keepWorker({ pushSubscribed: false, offlineAreas: 2 })).toBe(true); // turning push off must not kill offline
		expect(keepWorker({ pushSubscribed: true, offlineAreas: 1 })).toBe(true);
	});

	it("one cache name everywhere", () => {
		expect(boot().sw.CACHE).toBe(OFFLINE_CACHE_NAME);
		expect(OFFLINE_CACHE).toBe(OFFLINE_CACHE_NAME);
	});

	it("handles push, notificationclick and fetch in the same script", () => {
		const { listeners } = boot();
		expect(Object.keys(listeners).sort()).toEqual(["activate", "fetch", "install", "message", "notificationclick", "push"]);
	});

	it("offline logic runs only when an area exists; push-only use is never intercepted", () => {
		const { sw } = boot();
		expect(sw.offlineDecision("mapbox", false)).toBe("skip");
		expect(sw.offlineDecision("page", false)).toBe("skip");
		expect(sw.offlineDecision("page", true)).toBe("page");
		expect(sw.offlineDecision("skip", true)).toBe("skip");
		expect(sw.offlineDecision("mapbox", null)).toBe("check");
	});

	it("never intercepts /api, /_api or non-GET, even with areas saved", async () => {
		const { listeners } = boot({ cacheHas: true });
		listeners.message({ data: { type: "sary-offline", on: true } });
		for (const e of [
			fetchEvent("https://sary.example/api/outings/x"),
			fetchEvent("https://sary.example/_api/health"),
			fetchEvent("https://sary.example/outings/1", "POST", "navigate"),
			fetchEvent("https://api.mapbox.com/v4/x/1/1/1.vector.pbf", "POST"),
		]) {
			listeners.fetch(e);
			expect(e.respondWith).not.toHaveBeenCalled();
		}
		const page = fetchEvent("https://sary.example/outings/1", "GET", "navigate");
		listeners.fetch(page);
		expect(page.respondWith).toHaveBeenCalled();
	});

	it("after the last area is deleted the page says so and the worker stops serving", () => {
		const { listeners } = boot({ cacheHas: true });
		listeners.message({ data: { type: "sary-offline", on: false } });
		const e = fetchEvent("https://api.mapbox.com/v4/mapbox.satellite/1/1/1.webp");
		listeners.fetch(e);
		expect(e.respondWith).not.toHaveBeenCalled();
	});

	it("push: SOS stays on screen, others do not; links stay on this site", async () => {
		const { sw, listeners, self } = boot();
		const sos = sw.notificationFor({ type: "sos", title: "🆘", url: "/outings/abc" });
		expect(sos.options.requireInteraction).toBe(true);
		expect(sos.options.data.url).toBe("/outings/abc");
		const clear = sw.notificationFor({ type: "sos_clear", tag: "sary-sos-u", url: "https://evil.example/" });
		expect(clear.options.requireInteraction).toBe(false);
		expect(clear.options.tag).toBe("sary-sos-u");
		expect(clear.options.data.url).toBe("/outings");
		const waits: Promise<unknown>[] = [];
		listeners.push({ data: { json: () => ({ type: "note", title: "سعد", body: "وين؟" }) }, waitUntil: (p: Promise<unknown>) => waits.push(p) });
		await Promise.all(waits);
		expect(self.registration.showNotification).toHaveBeenCalledWith("سعد", expect.objectContaining({ body: "وين؟" }));
	});
});
