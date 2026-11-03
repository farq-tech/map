import { afterEach, describe, expect, it, vi } from "vitest";
import { backoffMs, FAILS_BEFORE_POLLING, LiveChannel, wireFix } from "./live";
import { applyEvent, fromSnapshot, mergeSnapshot } from "./outingState";
import type { OutingSnapshot, Position } from "./api";

class FakeSocket {
	static all: FakeSocket[] = [];
	readyState = 0;
	sent: unknown[] = [];
	onopen: (() => void) | null = null;
	onmessage: ((e: { data: string }) => void) | null = null;
	onclose: ((e: { code: number }) => void) | null = null;
	onerror: (() => void) | null = null;
	constructor(public url: string) {
		FakeSocket.all.push(this);
	}
	send(d: string) {
		this.sent.push(JSON.parse(d));
	}
	close(code = 1000) {
		this.readyState = 3;
		this.onclose?.({ code });
	}
	open() {
		this.readyState = 1;
		this.onopen?.();
	}
	push(msg: unknown) {
		this.onmessage?.({ data: JSON.stringify(msg) });
	}
}

const snap = (over: Partial<OutingSnapshot> = {}): OutingSnapshot => ({
	outing: { id: "o1", name: "طلعة", status: "active", owner_id: "a", created_at: "", started_at: "", ended_at: null },
	me: { user_id: "me", role: "member", sharing: true },
	members: [
		{ user_id: "me", display_name: "أنا", avatar: null, role: "member", sharing: true, joined_at: "" },
		{ user_id: "a", display_name: "سعد", avatar: null, role: "owner", sharing: true, joined_at: "" },
	],
	positions: [],
	invite: null,
	server_now: new Date().toISOString(),
	...over,
});

const pos = (recorded: number, lat = 24.7): Position => ({
	user_id: "a", lat, lng: 46.7, accuracy: 8, heading: null, speed: 10, mode: "balanced",
	recorded_at: new Date(recorded).toISOString(), received_at: new Date(recorded).toISOString(),
});

afterEach(() => {
	FakeSocket.all = [];
	vi.useRealTimers();
});

function channel(extra: Partial<ConstructorParameters<typeof LiveChannel>[3]> = {}) {
	const events: string[] = [];
	const h = {
		onSnapshot: vi.fn(),
		onEvent: vi.fn(),
		onState: (s: string) => events.push(s),
		onClosed: vi.fn(),
		onAck: vi.fn(),
	};
	const ch = new LiveChannel("o1", "tok", h, {
		WebSocketImpl: FakeSocket as unknown as typeof WebSocket,
		poll: vi.fn(async () => snap()),
		post: vi.fn(async () => ({})),
		beat: vi.fn(async () => ({})),
		online: () => true,
		...extra,
	}, "ws://x/api/outings/live");
	return { ch, h, events };
}

describe("LiveChannel", () => {
	it("authenticates in the first frame, never in the URL", () => {
		const { ch } = channel();
		ch.start();
		const ws = FakeSocket.all[0];
		expect(ws.url).not.toContain("tok");
		ws.open();
		expect(ws.sent[0]).toEqual({ type: "auth", token: "tok", outing_id: "o1" });
		ch.stop();
	});

	it("keeps only the latest fix while disconnected and sends it on ready", () => {
		const { ch, h, events } = channel();
		ch.start();
		const ws = FakeSocket.all[0];
		const now = Date.now();
		ch.sendFix({ lat: 1, lng: 1, accuracy: 5, heading: null, speed: null, at: now }, "balanced");
		ch.sendFix({ lat: 2, lng: 2, accuracy: 5, heading: null, speed: null, at: now }, "balanced");
		ws.open();
		ws.push({ type: "ready", snapshot: snap() });
		expect(events).toContain("live");
		expect(h.onSnapshot).toHaveBeenCalled();
		const positions = ws.sent.filter((m) => (m as { type: string }).type === "position");
		expect(positions).toHaveLength(1);
		expect((positions[0] as { fix: { lat: number } }).fix.lat).toBe(2);
		ch.stop();
	});

	it("drops a fix too old to be worth sending", () => {
		const { ch } = channel();
		ch.start();
		const ws = FakeSocket.all[0];
		ch.sendFix({ lat: 1, lng: 1, accuracy: 5, heading: null, speed: null, at: Date.now() - 58_000 }, "balanced");
		ws.open();
		ws.push({ type: "ready", snapshot: snap() });
		expect(ws.sent.some((m) => (m as { type: string }).type === "position")).toBe(false);
		ch.stop();
	});

	it("terminal close codes stop reconnecting and say why", () => {
		const { ch, h } = channel();
		ch.start();
		const ws = FakeSocket.all[0];
		ws.open();
		ws.push({ type: "ready", snapshot: snap() });
		ws.close(4403);
		expect(h.onClosed).toHaveBeenCalledWith("removed");
		expect(FakeSocket.all).toHaveLength(1);
	});

	it("reconnects with backoff after a dropped socket, and the snapshot restores state", () => {
		vi.useFakeTimers();
		const { ch, h } = channel();
		ch.start();
		FakeSocket.all[0].open();
		FakeSocket.all[0].push({ type: "ready", snapshot: snap() });
		FakeSocket.all[0].close(1006);
		vi.advanceTimersByTime(BACKOFF_CAP_FOR_TEST);
		expect(FakeSocket.all).toHaveLength(2);
		FakeSocket.all[1].open();
		FakeSocket.all[1].push({ type: "ready", snapshot: snap() });
		expect(h.onSnapshot).toHaveBeenCalledTimes(2);
		ch.stop();
	});

	it("falls back to HTTP polling when sockets never get through", async () => {
		vi.useFakeTimers();
		const poll = vi.fn(async () => snap());
		const { ch, events } = channel({ poll });
		ch.start();
		for (let i = 0; i < FAILS_BEFORE_POLLING; i += 1) {
			FakeSocket.all[FakeSocket.all.length - 1].close(1006);
			vi.advanceTimersByTime(40_000);
		}
		expect(events).toContain("polling");
		await vi.runOnlyPendingTimersAsync();
		expect(poll).toHaveBeenCalled();
		ch.stop();
	});

	it("offline is a state, and coming online reconnects at once", () => {
		let online = true;
		const { ch, events } = channel({ online: () => online });
		ch.start();
		online = false;
		window.dispatchEvent(new Event("offline"));
		expect(events).toContain("offline");
		online = true;
		window.dispatchEvent(new Event("online"));
		expect(FakeSocket.all.length).toBeGreaterThanOrEqual(1);
		ch.stop();
	});

	it("network back after an outage replaces a socket that only looked open", () => {
		let online = true;
		const { ch, events } = channel({ online: () => online });
		ch.start();
		FakeSocket.all[0].open();
		FakeSocket.all[0].push({ type: "ready", snapshot: snap() });
		online = false;
		window.dispatchEvent(new Event("offline"));
		expect(events.at(-1)).toBe("offline");
		online = true;
		window.dispatchEvent(new Event("online"));
		expect(FakeSocket.all).toHaveLength(2);
		FakeSocket.all[1].open();
		FakeSocket.all[1].push({ type: "ready", snapshot: snap() });
		expect(events.at(-1)).toBe("live");
		ch.stop();
	});

	it("backoff grows, is capped, and is jittered", () => {
		expect(backoffMs(0, 0)).toBe(500);
		expect(backoffMs(3, 1)).toBe(8_000);
		expect(backoffMs(20, 1)).toBe(30_000);
		expect(backoffMs(20, 0)).toBe(15_000);
	});

	it("wire fix carries device-measured age, not a device timestamp", () => {
		const w = wireFix({ lat: 1, lng: 2, accuracy: 3, heading: 4, speed: 5, at: 1000 }, "saver", 3500);
		expect(w).toEqual({ lat: 1, lng: 2, accuracy: 3, heading: 4, speed: 5, mode: "saver", age_ms: 2500 });
	});
});

const BACKOFF_CAP_FOR_TEST = 2_000;

describe("outing state reducer", () => {
	it("a late older fix never moves a marker back", () => {
		let v = fromSnapshot(snap());
		v = applyEvent(v, { type: "position", position: pos(2000, 24.8) });
		v = applyEvent(v, { type: "position", position: pos(1000, 24.1) });
		expect(v.positions.get("a")!.lat).toBe(24.8);
	});
	it("a reconnect snapshot keeps the newer fix we already had", () => {
		let v = fromSnapshot(snap());
		v = applyEvent(v, { type: "position", position: pos(5000, 24.9) });
		v = mergeSnapshot(v, snap({ positions: [pos(3000, 24.2)] }));
		expect(v.positions.get("a")!.lat).toBe(24.9);
	});
	it("paused sharing, pause and end drop positions", () => {
		let v = fromSnapshot(snap({ positions: [pos(1000)] }));
		expect(applyEvent(v, { type: "member_sharing", user_id: "a", sharing: false }).positions.size).toBe(0);
		expect(applyEvent(v, { type: "outing_status", status: "paused" }).positions.size).toBe(0);
		v = applyEvent(v, { type: "member_left", user_id: "a", reason: "removed" });
		expect(v.members.has("a")).toBe(false);
	});
	it("ignores positions while not active", () => {
		const v = fromSnapshot(snap({ outing: { ...snap().outing, status: "created" } }));
		expect(applyEvent(v, { type: "position", position: pos(1) }).positions.size).toBe(0);
	});
	it("link heartbeats update last seen without touching positions", () => {
		const v = applyEvent(fromSnapshot(snap()), { type: "member_link", user_id: "a", last_seen_at: "2026-11-03T10:00:00Z", gps: "unavailable" });
		expect(v.members.get("a")!.gps).toBe("unavailable");
		expect(v.positions.size).toBe(0);
	});
});
