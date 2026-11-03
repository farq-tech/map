import { describe, expect, it } from "vitest";
import { applyEvent, fromSnapshot } from "./outingState";
import type { OutingSnapshot } from "./api";
import { arrived, batteryLow, GapWatcher, groupMedian, PARKED_MS, REALERT_MS, watchBattery, type GapInput } from "./safety";

const KM_LAT = 1 / 111.195; // degrees of latitude per km
const at = (km: number, extra: Partial<GapInput> = {}): Omit<GapInput, "userId" | "name"> => ({ lat: 24.7 + km * KM_LAT, lng: 46.7, speed: 15, ...extra });
const group = (saadKm: number, extra: Partial<GapInput> = {}): GapInput[] => [
	{ userId: "me", name: "أنا", me: true, ...at(0) },
	{ userId: "a", name: "أحمد", ...at(0.1) },
	{ userId: "b", name: "بدر", ...at(0.2) },
	{ userId: "s", name: "سعد", ...at(saadKm), ...extra },
];

describe("battery", () => {
	const now = Date.parse("2026-11-03T10:00:00Z");
	const read = (level: number, charging: boolean, agoMs = 0) => ({ level, charging, at: new Date(now - agoMs).toISOString() });
	it("warns under 15 % only when not charging", () => {
		expect(batteryLow(read(0.12, false), now)).toBe(true);
		expect(batteryLow(read(0.12, true), now)).toBe(false);
		expect(batteryLow(read(0.15, false), now)).toBe(false);
	});
	it("never warns from nothing or from an old reading", () => {
		expect(batteryLow(null, now)).toBe(false);
		expect(batteryLow(undefined, now)).toBe(false);
		expect(batteryLow(read(0.05, false, 11 * 60_000), now)).toBe(false);
	});
	it("reports nothing where the Battery Status API is missing (iOS)", () => {
		const seen: unknown[] = [];
		const stop = watchBattery((b) => seen.push(b), {});
		stop();
		expect(seen).toEqual([]);
	});
	it("reads level and charging where it exists", async () => {
		const mgr = Object.assign(new EventTarget(), { level: 0.42, charging: false });
		const seen: Array<{ level: number; charging: boolean }> = [];
		const stop = watchBattery((b) => seen.push(b), { getBattery: () => Promise.resolve(mgr) });
		await Promise.resolve();
		await Promise.resolve();
		mgr.charging = true;
		mgr.dispatchEvent(new Event("chargingchange"));
		stop();
		mgr.dispatchEvent(new Event("levelchange"));
		expect(seen).toEqual([{ level: 0.42, charging: false }, { level: 0.42, charging: true }]);
	});
});

describe("rally point", () => {
	it("counts arrival within 150 m", () => {
		const r = { lat: 24.7, lng: 46.7 };
		expect(arrived(r, { lat: 24.7 + 0.14 * KM_LAT, lng: 46.7 })).toBe(true);
		expect(arrived(r, { lat: 24.7 + 0.16 * KM_LAT, lng: 46.7 })).toBe(false);
	});
	it("rally events replace the outing's pin", () => {
		const snap = {
			outing: { id: "o", name: "x", status: "active", owner_id: "me", created_at: "", started_at: null, ended_at: null, rally: null },
			me: { user_id: "me", role: "owner", sharing: true },
			members: [{ user_id: "s", display_name: "سعد", avatar: null, role: "member", sharing: true, joined_at: "" }],
			positions: [],
			invite: null,
			server_now: new Date().toISOString(),
		} as OutingSnapshot;
		let v = fromSnapshot(snap);
		v = applyEvent(v, { type: "rally", rally: { lat: 24.8, lng: 46.7, label: null, set_at: null, set_by: "me" } });
		expect(v.snapshot.outing.rally?.lat).toBe(24.8);
		v = applyEvent(v, { type: "sos", user_id: "s", sos: { at: "t", fix: null } });
		expect(v.members.get("s")?.sos).toEqual({ at: "t", fix: null });
		v = applyEvent(v, { type: "member_link", user_id: "s", last_seen_at: "t", gps: "ok", battery: { level: 0.1, charging: false, at: "t" } });
		expect(v.members.get("s")?.battery?.level).toBe(0.1);
		v = applyEvent(v, { type: "member_link", user_id: "s", last_seen_at: "t2", gps: "ok" });
		expect(v.members.get("s")?.battery?.level, "an older server without the field keeps the reading").toBe(0.1);
		v = applyEvent(v, { type: "sos", user_id: "s", sos: null });
		v = applyEvent(v, { type: "rally", rally: null });
		expect([v.members.get("s")?.sos, v.snapshot.outing.rally]).toEqual([null, null]);
	});
});

describe("gap watcher", () => {
	it("uses the median, so one runaway car does not move the group", () => {
		const m = groupMedian(group(20));
		expect(m!.lat).toBeCloseTo(24.7 + 0.15 * KM_LAT, 6);
	});

	it("alerts once when someone drifts past the threshold, with hysteresis", () => {
		const w = new GapWatcher(3);
		let t = 0;
		expect(w.update(group(1), t)).toEqual([]);
		const a = w.update(group(4), (t += 10_000));
		expect(a).toHaveLength(1);
		expect(a[0]).toMatchObject({ kind: "far", userId: "s", name: "سعد" });
		expect((a[0] as { distanceM: number }).distanceM).toBeGreaterThan(3_500);
		/* Still far, then hovering around the line: no repeats. */
		expect(w.update(group(5), (t += 10_000))).toEqual([]);
		expect(w.update(group(2.8), (t += 10_000))).toEqual([]);
		expect(w.update(group(3.2), (t += 10_000))).toEqual([]);
		/* Back well inside (under 70 %), then out again soon: still quiet. */
		expect(w.update(group(1), (t += 10_000))).toEqual([]);
		expect(w.update(group(4), (t += 10_000))).toEqual([]);
		/* After the re-alert gap, a new episode alerts again. */
		w.update(group(1), (t += 10_000));
		expect(w.update(group(4), (t += REALERT_MS + 1))).toHaveLength(1);
	});

	it("needs three people and never alerts about me", () => {
		const w = new GapWatcher(3);
		expect(w.update(group(0).slice(0, 1).concat([{ userId: "s", name: "سعد", ...at(10) }]), 0)).toEqual([]);
		const meFar: GapInput[] = [
			{ userId: "me", name: "أنا", me: true, ...at(10) },
			{ userId: "a", name: "أحمد", ...at(0) },
			{ userId: "b", name: "بدر", ...at(0.1) },
		];
		expect(w.update(meFar, 1)).toEqual([]);
	});

	it("is off at threshold 0", () => {
		const w = new GapWatcher(0);
		expect(w.update(group(1), 0)).toEqual([]);
		expect(w.update(group(40), 1)).toEqual([]);
	});

	it("alerts when someone is parked for 10 min while the group moves", () => {
		const w = new GapWatcher(3);
		const parked = { speed: 0 };
		w.update(group(1, parked), 0);
		expect(w.update(group(1, parked), PARKED_MS - 1)).toEqual([]);
		const a = w.update(group(1, parked), PARKED_MS + 1);
		expect(a).toEqual([{ kind: "parked", userId: "s", name: "سعد", parkedMs: PARKED_MS + 1 }]);
		expect(w.update(group(1, parked), PARKED_MS + 60_000)).toEqual([]);
	});

	it("does not call it parked when the whole group has stopped", () => {
		const w = new GapWatcher(3);
		const still = (km: number) => group(km, { speed: 0 }).map((p) => ({ ...p, speed: 0 }));
		w.update(still(1), 0);
		expect(w.update(still(1), PARKED_MS + 1)).toEqual([]);
	});
});
