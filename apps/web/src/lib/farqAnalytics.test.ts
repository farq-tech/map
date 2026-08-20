import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Each test imports a fresh copy of the module: the buffer, the session id and
 * safeStorage's probe cache are all module state, and a stale one would hide
 * exactly the bugs these tests exist to catch.
 */
async function freshModule() {
	vi.resetModules();
	return import("./farqAnalytics");
}

let beacon: ReturnType<typeof vi.fn>;

function installBeacon(result = true) {
	beacon = vi.fn(() => result);
	Object.defineProperty(navigator, "sendBeacon", {
		value: beacon,
		configurable: true,
		writable: true,
	});
}

/** jsdom's Blob has no `.text()`, so read it the way a browser of that era would. */
function readBody(body: Blob | string): Promise<string> {
	if (typeof body === "string") return Promise.resolve(body);
	return new Promise((resolve, reject) => {
		const reader = new FileReader();
		reader.onload = () => resolve(String(reader.result));
		reader.onerror = () => reject(reader.error);
		reader.readAsText(body);
	});
}

async function sentBatches(): Promise<Array<Record<string, unknown>[]>> {
	const out: Array<Record<string, unknown>[]> = [];
	for (const call of beacon.mock.calls) {
		out.push(JSON.parse(await readBody(call[1] as Blob | string)).events);
	}
	return out;
}

/** Restored after every test: one test replaces it with a getter that throws. */
const sessionStorageDescriptor = Object.getOwnPropertyDescriptor(
	window,
	"sessionStorage",
) as PropertyDescriptor;

beforeEach(() => {
	installBeacon();
	document.documentElement.lang = "ar";
	sessionStorage.clear();
});

afterEach(() => {
	vi.useRealTimers();
	Object.defineProperty(window, "sessionStorage", sessionStorageDescriptor);
	Reflect.deleteProperty(navigator, "sendBeacon");
	Reflect.deleteProperty(navigator, "doNotTrack");
	Reflect.deleteProperty(globalThis as Record<string, unknown>, "__farqAnalyticsOff");
});

describe("farqAnalytics", () => {
	it("buffers events and sends nothing until a flush", async () => {
		const { track, flush, __bufferSizeForTests } = await freshModule();
		track("map_view", { zoom: 12 });
		track("district_select", { district_id: "d-1" });
		expect(__bufferSizeForTests()).toBe(2);
		expect(beacon).not.toHaveBeenCalled();
		// Drain: this instance keeps its page listeners for the rest of the file,
		// and a leftover buffer would post again on the next visibilitychange.
		flush();
		expect(__bufferSizeForTests()).toBe(0);
	});

	it("flush sends one beacon carrying the whole batch", async () => {
		const { track, flush } = await freshModule();
		track("map_view", { zoom: 12 });
		track("list_open", { result_count: 8 });
		track("search_here");
		flush();

		expect(beacon).toHaveBeenCalledTimes(1);
		const [url] = beacon.mock.calls[0];
		expect(String(url)).toMatch(/\/api\/analytics$/);
		const [events] = await sentBatches();
		expect(events.map((e) => e.type)).toEqual(["map_view", "list_open", "search_here"]);
		expect(events[0].language).toBe("ar");
		expect(events[0].path).toBe("/");
		expect(events[0].session_id).toMatch(/^[A-Za-z0-9_-]{8,64}$/);
		expect(events[0].meta).toEqual({ zoom: 12 });

		flush();
		expect(beacon).toHaveBeenCalledTimes(1); // an empty buffer sends nothing
	});

	it("flushes on its own after 3s", async () => {
		vi.useFakeTimers();
		const { track } = await freshModule();
		track("map_view");
		expect(beacon).not.toHaveBeenCalled();
		vi.advanceTimersByTime(3_000);
		expect(beacon).toHaveBeenCalledTimes(1);
	});

	it("flushes when the page is hidden", async () => {
		const { track } = await freshModule();
		track("copilot_ask", { has_query: true });
		Object.defineProperty(document, "visibilityState", {
			value: "hidden",
			configurable: true,
		});
		document.dispatchEvent(new Event("visibilitychange"));
		expect(beacon).toHaveBeenCalledTimes(1);
		Reflect.deleteProperty(document, "visibilityState");
	});

	it("does nothing at all when Do Not Track is on", async () => {
		Object.defineProperty(navigator, "doNotTrack", {
			value: "1",
			configurable: true,
		});
		const { track, flush, __bufferSizeForTests } = await freshModule();
		track("map_view");
		expect(__bufferSizeForTests()).toBe(0);
		flush();
		expect(beacon).not.toHaveBeenCalled();
	});

	it("does nothing when __farqAnalyticsOff is set", async () => {
		(globalThis as Record<string, unknown>).__farqAnalyticsOff = true;
		const { track, __bufferSizeForTests } = await freshModule();
		track("map_view");
		expect(__bufferSizeForTests()).toBe(0);
	});

	it("caps the buffer at 50 and posts in requests of 20", async () => {
		const { track, flush, __bufferSizeForTests } = await freshModule();
		for (let i = 0; i < 60; i += 1) track("map_view");
		expect(__bufferSizeForTests()).toBe(50);
		flush();
		const batches = await sentBatches();
		expect(batches.map((b) => b.length)).toEqual([20, 20, 10]);
	});

	it("survives sessionStorage throwing (private mode) with a null session", async () => {
		Object.defineProperty(window, "sessionStorage", {
			configurable: true,
			get() {
				throw new Error("storage blocked");
			},
		});
		const { track, flush } = await freshModule();
		expect(() => track("map_view")).not.toThrow();
		flush();
		const [events] = await sentBatches();
		expect(events).toHaveLength(1);
		// Storage being blocked only costs the id its persistence; nothing throws.
		expect(events[0].session_id).toMatch(/^[A-Za-z0-9_-]{8,64}$/);
	});

	it("falls back to a keepalive fetch when sendBeacon is missing", async () => {
		Reflect.deleteProperty(navigator, "sendBeacon");
		const fetchMock = vi.fn(() => Promise.resolve(new Response(null, { status: 204 })));
		vi.stubGlobal("fetch", fetchMock);
		const { track, flush } = await freshModule();
		track("lens_change", { lens: "price" });
		flush();
		expect(fetchMock).toHaveBeenCalledTimes(1);
		const init = fetchMock.mock.calls[0][1] as RequestInit;
		expect(init.keepalive).toBe(true);
		expect(init.method).toBe("POST");
		vi.unstubAllGlobals();
	});

	it("never throws, whatever the transport does", async () => {
		beacon.mockImplementation(() => {
			throw new Error("beacon exploded");
		});
		const { track, flush } = await freshModule();
		track("locate_click");
		expect(() => flush()).not.toThrow();
	});
});
