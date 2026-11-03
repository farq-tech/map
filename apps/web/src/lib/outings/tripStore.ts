/**
 * This device's running trip totals for one outing, on this device only
 * (localStorage, so a reload mid-outing keeps the distance). Holds totals and
 * one previous fix — see trip.ts — and is wiped once the person shares or
 * dismisses their summary, or after a week.
 */

import { safeGet, safeRemove, safeSet } from "../safeStorage";
import { deserialize, serialize, type TripState } from "./trip";

const key = (id: string) => `sary.outings.trip.v1.${id}`;
const KEEP_MS = 7 * 24 * 3600_000;

export function loadTrip(outingId: string, now = Date.now()): TripState {
	const s = deserialize(safeGet("localStorage", key(outingId)));
	if (s.lastAt != null && now - s.lastAt > KEEP_MS) {
		clearTrip(outingId);
		return deserialize(null);
	}
	return s;
}

export function saveTrip(outingId: string, s: TripState): void {
	safeSet("localStorage", key(outingId), serialize(s));
}

export function clearTrip(outingId: string): void {
	safeRemove("localStorage", key(outingId));
}

export function hasTrip(outingId: string): boolean {
	return loadTrip(outingId).firstAt != null;
}
