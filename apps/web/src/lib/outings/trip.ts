/**
 * Opt-in trip summary — computed on THIS device from ITS OWN fixes only.
 *
 * Privacy shape: no list of points is ever kept, not even here. The
 * accumulator holds running totals plus the single previous fix it needs to
 * measure the next step; that is all that is saved on the phone (so a reload
 * mid-outing does not lose the distance), and only the totals ever leave it —
 * and only when the person taps «شارك ملخصي».
 */

import { haversineMeters } from "../sary/domain";
import type { DeviceFix } from "./policy";

/** Fixes worse than this cannot measure a step honestly. */
export const TRIP_MAX_ACCURACY_M = 50;
/** A step shorter than the noise floor is GPS wander, not driving. */
export const TRIP_MIN_STEP_M = 8;
/** Faster than any car on these roads: a glitch, not a step. */
export const TRIP_MAX_SPEED_MPS = 55;
/** Above this between two fixes, the time counts as moving. */
export const MOVING_MPS = 1.5;
/** A gap longer than this (tunnel, phone asleep) is not bridged with a straight line. */
export const TRIP_MAX_GAP_MS = 5 * 60_000;

export type TripState = {
	distanceM: number;
	movingMs: number;
	firstAt: number | null;
	lastAt: number | null;
	/** The previous accepted fix, to measure the next step. Never a list. */
	prev: { lat: number; lng: number; at: number; accuracy: number | null } | null;
};

export const emptyTrip = (): TripState => ({ distanceM: 0, movingMs: 0, firstAt: null, lastAt: null, prev: null });

export function addFix(s: TripState, f: DeviceFix): TripState {
	if (!Number.isFinite(f.lat) || !Number.isFinite(f.lng) || !Number.isFinite(f.at)) return s;
	if (f.accuracy != null && f.accuracy > TRIP_MAX_ACCURACY_M) return s;
	if (s.prev && f.at <= s.prev.at) return s;
	const here = { lat: f.lat, lng: f.lng, at: f.at, accuracy: f.accuracy };
	if (!s.prev) return { ...s, firstAt: s.firstAt ?? f.at, lastAt: f.at, prev: here };
	const dt = f.at - s.prev.at;
	const d = haversineMeters(s.prev, f);
	const noise = Math.max(TRIP_MIN_STEP_M, ((s.prev.accuracy ?? 10) + (f.accuracy ?? 10)) / 2);
	const lastAt = f.at;
	if (dt > TRIP_MAX_GAP_MS) {
		/* Resume from here; the unseen stretch is not guessed. */
		return { ...s, lastAt, prev: here };
	}
	if (d / (dt / 1000) > TRIP_MAX_SPEED_MPS) return s; // glitch: keep the previous anchor
	if (d < noise) return { ...s, lastAt }; // standing still, or wander: anchor stays
	const moving = d / (dt / 1000) >= MOVING_MPS;
	return { distanceM: s.distanceM + d, movingMs: s.movingMs + (moving ? dt : 0), firstAt: s.firstAt, lastAt, prev: here };
}

export type TripTotals = { distance_m: number; duration_s: number; moving_s: number };

export function totals(s: TripState): TripTotals {
	const duration = s.firstAt != null && s.lastAt != null ? Math.max(0, s.lastAt - s.firstAt) : 0;
	const moving = Math.min(duration, s.movingMs);
	return { distance_m: Math.round(s.distanceM), duration_s: Math.round(duration / 1000), moving_s: Math.round(moving / 1000) };
}

/** What is stored on the phone: totals and the one previous fix — nothing more. */
export function serialize(s: TripState): string {
	return JSON.stringify({ v: 1, d: s.distanceM, m: s.movingMs, f: s.firstAt, l: s.lastAt, p: s.prev });
}

export function deserialize(raw: string | null): TripState {
	if (!raw) return emptyTrip();
	try {
		const o = JSON.parse(raw) as { v?: number; d?: number; m?: number; f?: number | null; l?: number | null; p?: TripState["prev"] };
		if (o.v !== 1) return emptyTrip();
		const n = (x: unknown) => (typeof x === "number" && Number.isFinite(x) && x >= 0 ? x : null);
		const p = o.p && n(o.p.at) != null && Number.isFinite(o.p.lat) && Number.isFinite(o.p.lng) ? o.p : null;
		return { distanceM: n(o.d) ?? 0, movingMs: n(o.m) ?? 0, firstAt: n(o.f), lastAt: n(o.l), prev: p };
	} catch {
		return emptyTrip();
	}
}
