/**
 * Outing safety, as pure functions — battery warnings, rally arrivals and the
 * group-gap watcher — so every rule is testable without a map or a phone.
 *
 * Nothing here estimates a position: every input is a real fix the server
 * relayed, and callers pass only fixes they would show (not «انقطع الاتصال»).
 */

import { haversineMeters } from "../sary/domain";
import type { Battery } from "./api";
import { STILL_MPS } from "./policy";

/* ---------- battery ---------- */

export const LOW_BATTERY = 0.15;
/** A reading that stopped coming is not shown: the phone may have died or been charged since. */
export const BATTERY_STALE_MS = 10 * 60_000;

export function batteryFresh(b: Battery | null | undefined, serverNow: number): b is Battery {
	return Boolean(b) && serverNow - new Date(b!.at).getTime() <= BATTERY_STALE_MS;
}

export function batteryLow(b: Battery | null | undefined, serverNow: number): boolean {
	return batteryFresh(b, serverNow) && !b.charging && b.level < LOW_BATTERY;
}

type BatteryManagerLike = EventTarget & { level: number; charging: boolean };

/**
 * Watch this phone's battery through the Battery Status API. Where it does
 * not exist (iOS Safari, Firefox) `onChange` is never called — we send
 * nothing rather than a guess. Returns a stop function.
 */
export function watchBattery(onChange: (b: { level: number; charging: boolean }) => void, nav: unknown = typeof navigator === "undefined" ? undefined : navigator): () => void {
	const get = (nav as { getBattery?: () => Promise<BatteryManagerLike> } | undefined)?.getBattery;
	if (typeof get !== "function") return () => undefined;
	let stopped = false;
	let mgr: BatteryManagerLike | null = null;
	const emit = () => {
		if (!stopped && mgr && Number.isFinite(mgr.level)) onChange({ level: mgr.level, charging: Boolean(mgr.charging) });
	};
	get.call(nav).then(
		(m) => {
			if (stopped) return;
			mgr = m;
			m.addEventListener("levelchange", emit);
			m.addEventListener("chargingchange", emit);
			emit();
		},
		() => undefined,
	);
	return () => {
		stopped = true;
		mgr?.removeEventListener("levelchange", emit);
		mgr?.removeEventListener("chargingchange", emit);
	};
}

/* ---------- rally point ---------- */

export const ARRIVED_M = 150;

export function arrived(rally: { lat: number; lng: number }, p: { lat: number; lng: number }): boolean {
	return haversineMeters(rally, p) <= ARRIVED_M;
}

/* ---------- group gap ---------- */

export type GapInput = {
	userId: string;
	name: string;
	lat: number;
	lng: number;
	/** m/s from the fix; null when the phone did not say. */
	speed: number | null;
	/** Me: counts toward the group, never alerted about. */
	me?: boolean;
};

export type GapAlert =
	| { kind: "far"; userId: string; name: string; distanceM: number }
	| { kind: "parked"; userId: string; name: string; parkedMs: number };

/** Coordinate-wise median: one runaway car cannot drag the "group" towards itself. */
export function groupMedian(points: Array<{ lat: number; lng: number }>): { lat: number; lng: number } | null {
	if (!points.length) return null;
	const med = (xs: number[]) => {
		const s = [...xs].sort((a, b) => a - b);
		const i = Math.floor(s.length / 2);
		return s.length % 2 ? s[i] : (s[i - 1] + s[i]) / 2;
	};
	return { lat: med(points.map((p) => p.lat)), lng: med(points.map((p) => p.lng)) };
}

function median(xs: number[]): number {
	return groupMedian(xs.map((x) => ({ lat: x, lng: 0 })))?.lat ?? 0;
}

export const PARKED_MS = 10 * 60_000;
/** Moving this far from where we first saw them stopped means they are not parked. */
export const PARKED_RADIUS_M = 120;
/** The rest of the group counts as moving above ~11 km/h (median speed). */
export const GROUP_MOVING_MPS = 3;
/** Clear a "far" alert only once they are back well inside the threshold. */
export const FAR_CLEAR_RATIO = 0.7;
/** After an alert clears, the same alert for the same person waits this long. */
export const REALERT_MS = 5 * 60_000;
/** With two cars, "far from the group" has no meaning: either could be the one. */
export const MIN_GROUP = 3;

type Track = {
	anchor: { lat: number; lng: number; since: number };
	far: boolean;
	parked: boolean;
	farClearedAt: number;
	parkedClearedAt: number;
};

/**
 * One alert per episode, per person: «سعد متأخر ٤ كم» fires when Saad crosses
 * the threshold and not again until he is back within 70 % of it (and 5 min
 * have passed). Likewise «واقف» while the group moves.
 */
export class GapWatcher {
	private tracks = new Map<string, Track>();

	constructor(public thresholdKm = 3) {}

	reset(): void {
		this.tracks.clear();
	}

	update(people: GapInput[], now: number): GapAlert[] {
		const out: GapAlert[] = [];
		const enabled = this.thresholdKm > 0;
		const center = people.length >= MIN_GROUP ? groupMedian(people) : null;
		const limitM = this.thresholdKm * 1000;
		for (const p of people) {
			let t = this.tracks.get(p.userId);
			if (!t) {
				t = { anchor: { lat: p.lat, lng: p.lng, since: now }, far: false, parked: false, farClearedAt: -Infinity, parkedClearedAt: -Infinity };
				this.tracks.set(p.userId, t);
			}
			if (haversineMeters(t.anchor, p) > PARKED_RADIUS_M || (p.speed ?? 0) >= STILL_MPS) t.anchor = { lat: p.lat, lng: p.lng, since: now };

			/* Far from the group. */
			if (center && enabled) {
				const d = haversineMeters(center, p);
				if (!t.far && d > limitM && now - t.farClearedAt >= REALERT_MS) {
					t.far = true;
					if (!p.me) out.push({ kind: "far", userId: p.userId, name: p.name, distanceM: d });
				} else if (t.far && d < limitM * FAR_CLEAR_RATIO) {
					t.far = false;
					t.farClearedAt = now;
				}
			}

			/* Parked while everyone else moves. */
			const others = people.filter((o) => o.userId !== p.userId);
			const groupMoving = others.length >= MIN_GROUP - 1 && median(others.map((o) => o.speed ?? 0)) >= GROUP_MOVING_MPS;
			const stillFor = now - t.anchor.since;
			if (!t.parked && enabled && groupMoving && stillFor >= PARKED_MS && now - t.parkedClearedAt >= REALERT_MS) {
				t.parked = true;
				if (!p.me) out.push({ kind: "parked", userId: p.userId, name: p.name, parkedMs: stillFor });
			} else if (t.parked && (stillFor < PARKED_MS || !groupMoving)) {
				t.parked = false;
				t.parkedClearedAt = now;
			}
		}
		return out;
	}

	/** Forget people who left the outing. Members merely without a fix right now keep their state, so reappearing is not a new alert. */
	retain(memberIds: Set<string>): void {
		for (const id of [...this.tracks.keys()]) if (!memberIds.has(id)) this.tracks.delete(id);
	}
}
