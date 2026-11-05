import { describe, expect, it } from "vitest";
import { createWakeKeeper, wakePreference, type WakeDocument } from "./wakeLock";

function fakes() {
	const listeners = new Set<() => void>();
	const doc: WakeDocument & { set: (v: "visible" | "hidden") => void } = {
		visibilityState: "visible",
		addEventListener: (_t, fn) => listeners.add(fn),
		removeEventListener: (_t, fn) => listeners.delete(fn),
		set(v) {
			this.visibilityState = v;
			for (const fn of listeners) fn();
		},
	};
	const sentinels: Array<{ released: boolean; fire: () => void }> = [];
	let requests = 0;
	const nav = {
		wakeLock: {
			request: async () => {
				requests += 1;
				let onRelease: (() => void) | null = null;
				const s = {
					released: false,
					release: async () => {
						s.released = true;
					},
					addEventListener: (_t: "release", fn: () => void) => {
						onRelease = fn;
					},
					fire: () => onRelease?.(),
				};
				sentinels.push(s);
				return s;
			},
		},
	};
	return { doc, nav, sentinels, requests: () => requests, listeners };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

describe("wake lock", () => {
	it("is on by default; only a saved off turns it off", () => {
		expect(wakePreference(null)).toBe(true);
		expect(wakePreference("1")).toBe(true);
		expect(wakePreference("0")).toBe(false);
	});

	it("acquires when wanted, releases when not", async () => {
		const f = fakes();
		const seen: boolean[] = [];
		const k = createWakeKeeper(f.nav, f.doc, (h) => seen.push(h));
		expect(k.supported).toBe(true);
		k.set(true);
		await tick();
		expect(k.held).toBe(true);
		k.set(false);
		expect(k.held).toBe(false);
		expect(f.sentinels[0].released).toBe(true);
		expect(seen).toEqual([true, false]);
	});

	it("re-acquires when the page becomes visible again", async () => {
		const f = fakes();
		const k = createWakeKeeper(f.nav, f.doc);
		k.set(true);
		await tick();
		f.doc.set("hidden");
		expect(k.held).toBe(false);
		f.doc.set("visible");
		await tick();
		expect(f.requests()).toBe(2);
		expect(k.held).toBe(true);
	});

	it("does not ask while hidden, and asks again after a system release", async () => {
		const f = fakes();
		f.doc.visibilityState = "hidden";
		const k = createWakeKeeper(f.nav, f.doc);
		k.set(true);
		await tick();
		expect(f.requests()).toBe(0);
		f.doc.set("visible");
		await tick();
		expect(k.held).toBe(true);
		f.sentinels[0].fire();
		await tick();
		await tick();
		expect(f.requests()).toBe(2);
		expect(k.held).toBe(true);
	});

	it("never re-acquires after being turned off, and cleans up its listener", async () => {
		const f = fakes();
		const k = createWakeKeeper(f.nav, f.doc);
		k.set(true);
		await tick();
		k.set(false);
		f.doc.set("hidden");
		f.doc.set("visible");
		await tick();
		expect(f.requests()).toBe(1);
		k.dispose();
		expect(f.listeners.size).toBe(0);
	});

	it("is a harmless no-op without the Wake Lock API", () => {
		const f = fakes();
		const k = createWakeKeeper({}, f.doc);
		k.set(true);
		expect([k.supported, k.held]).toEqual([false, false]);
	});
});
