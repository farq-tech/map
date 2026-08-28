/**
 * Trip session math. Coordinates are only accepted when they are finite
 * numbers inside Saudi bounds. Nothing is interpolated or invented.
 */

import { asLngLat, haversineMeters } from "./domain";

export type TripStatus = "idle" | "recording" | "paused" | "finished";

export type TripPoint = {
	lng: number;
	lat: number;
	at: number;
	accuracy?: number | null;
	heading?: number | null;
};

export type TripRecord = {
	id: string;
	name: string | null;
	status: TripStatus;
	startedAt: number;
	endedAt: number | null;
	pausedMs: number;
	points: TripPoint[];
	distanceM: number;
};

export function createTripId(now = Date.now()): string {
	return `trip-${now.toString(36)}`;
}

export function emptyTrip(now = Date.now()): TripRecord {
	return {
		id: createTripId(now),
		name: null,
		status: "recording",
		startedAt: now,
		endedAt: null,
		pausedMs: 0,
		points: [],
		distanceM: 0,
	};
}

export function parseTripPoint(raw: {
	lng?: unknown;
	lat?: unknown;
	at?: unknown;
	accuracy?: unknown;
	heading?: unknown;
}): TripPoint | null {
	const coord = asLngLat(raw.lng, raw.lat);
	if (!coord) return null;
	const at = typeof raw.at === "number" && Number.isFinite(raw.at) ? raw.at : Date.now();
	const accuracy =
		typeof raw.accuracy === "number" && Number.isFinite(raw.accuracy) ? raw.accuracy : null;
	const heading =
		typeof raw.heading === "number" && Number.isFinite(raw.heading) ? raw.heading : null;
	return { lng: coord.lng, lat: coord.lat, at, accuracy, heading };
}

export function appendTripPoint(trip: TripRecord, raw: Parameters<typeof parseTripPoint>[0]): TripRecord {
	if (trip.status !== "recording") return trip;
	const point = parseTripPoint(raw);
	if (!point) return trip;
	const last = trip.points[trip.points.length - 1];
	if (last && last.lng === point.lng && last.lat === point.lat && last.at === point.at) {
		return trip;
	}
	const delta = last ? haversineMeters(last, point) : 0;
	/* Ignore GPS jitter under 4 m so a parked car does not grow a scribble. */
	if (last && delta < 4) {
		return {
			...trip,
			points: [...trip.points.slice(0, -1), { ...last, at: point.at, accuracy: point.accuracy, heading: point.heading ?? last.heading }],
		};
	}
	return {
		...trip,
		points: [...trip.points, point],
		distanceM: trip.distanceM + (last ? delta : 0),
	};
}

export function tripDurationMs(trip: TripRecord, now = Date.now()): number {
	const end = trip.endedAt ?? now;
	return Math.max(0, end - trip.startedAt - trip.pausedMs);
}

export function tripLine(trip: TripRecord): GeoJSON.Feature<GeoJSON.LineString> | null {
	if (trip.points.length < 2) return null;
	return {
		type: "Feature",
		properties: {
			id: trip.id,
			kind: "personal_track",
			evidence: "mine",
			source: "gps",
		},
		geometry: {
			type: "LineString",
			coordinates: trip.points.map((p) => [p.lng, p.lat]),
		},
	};
}

export function tripStartEnd(trip: TripRecord): {
	start: TripPoint | null;
	end: TripPoint | null;
} {
	return {
		start: trip.points[0] ?? null,
		end: trip.points[trip.points.length - 1] ?? null,
	};
}

/** Honest motion: recording, a recent fix, and the last step was more than jitter. */
export function tripIsMoving(trip: TripRecord | null, now = Date.now()): boolean {
	if (!trip || trip.status !== "recording") return false;
	const last = trip.points[trip.points.length - 1];
	const prev = trip.points[trip.points.length - 2];
	if (!last || !prev) return false;
	if (now - last.at > 4_000) return false;
	return haversineMeters(prev, last) >= 8;
}
