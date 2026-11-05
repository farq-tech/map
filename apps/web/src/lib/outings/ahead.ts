/**
 * «أقرب محطة» — the nearest fuel (and water) along the group's way.
 *
 * Everything here runs on the phone. The data request asks for a coarse
 * ~1° square around the group (snapped to a 0.25° grid, cacheable, without
 * the member's token), so no precise position leaves the device for it; the
 * distances and "ahead / behind" are worked out here.
 */

import { haversineMeters } from "../sary/domain";
import { bearingDeg } from "./policy";

export type LatLng = { lat: number; lng: number };

export type Mover = LatLng & { heading: number | null; speed: number | null };

/** Moving faster than this, a reported course is trusted as the group's way. */
export const HEADING_MIN_MPS = 3;
/** Within this angle of the heading, a place is "ahead". */
export const AHEAD_CONE_DEG = 60;

export type GroupMotion = { origin: LatLng; heading: number | null; movers: number };

/**
 * Where the group is and which way it is going: the centre of everyone we
 * can place, and the circular mean of the courses of those actually moving.
 */
export function groupMotion(people: Mover[]): GroupMotion | null {
	const pts = people.filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng));
	if (!pts.length) return null;
	const origin = { lat: pts.reduce((a, p) => a + p.lat, 0) / pts.length, lng: pts.reduce((a, p) => a + p.lng, 0) / pts.length };
	let x = 0;
	let y = 0;
	let movers = 0;
	for (const p of pts) {
		if (p.heading == null || !Number.isFinite(p.heading) || (p.speed ?? 0) < HEADING_MIN_MPS) continue;
		const r = (p.heading * Math.PI) / 180;
		x += Math.cos(r);
		y += Math.sin(r);
		movers += 1;
	}
	/* Cars going opposite ways cancel out: no agreed direction, so none is claimed. */
	if (!movers || Math.hypot(x, y) / movers < 0.5) return { origin, heading: null, movers };
	const heading = (((Math.atan2(y, x) * 180) / Math.PI) % 360 + 360) % 360;
	return { origin, heading: Math.round(heading), movers };
}

/** Signed smallest angle a→b, in −180…180. */
export function angleDiff(a: number, b: number): number {
	return ((((b - a) % 360) + 540) % 360) - 180;
}

export type Candidate = { id: string; kind: string; name: string | null; brand?: string | null; lat: number; lng: number };

export type Ranked = Candidate & {
	distanceM: number;
	bearing: number;
	/** Distance along the heading (negative = behind); null without a heading. */
	alongM: number | null;
	ahead: boolean | null;
};

/**
 * With a heading: places ahead (inside the cone) first, nearest first, then
 * the rest by distance. Without one: simply nearest first.
 */
export function rankAlong(origin: LatLng, heading: number | null, items: Candidate[], { limit = 3, maxM = 80_000 } = {}): Ranked[] {
	const ranked: Ranked[] = [];
	for (const c of items) {
		const distanceM = haversineMeters(origin, c);
		if (distanceM > maxM) continue;
		const bearing = bearingDeg(origin, c);
		if (heading == null) {
			ranked.push({ ...c, distanceM, bearing, alongM: null, ahead: null });
			continue;
		}
		const delta = angleDiff(heading, bearing);
		const alongM = distanceM * Math.cos((delta * Math.PI) / 180);
		ranked.push({ ...c, distanceM, bearing, alongM, ahead: Math.abs(delta) <= AHEAD_CONE_DEG });
	}
	ranked.sort((a, b) => Number(b.ahead === true) - Number(a.ahead === true) || a.distanceM - b.distanceM);
	return ranked.slice(0, limit);
}

/**
 * A coarse, cacheable box around a point: centre snapped to `grid` degrees,
 * ±`half`. The default (0.25°, ±0.5°) is the wide look; NEAR_BOX is the
 * first, tighter one — a city like Riyadh has hundreds of stations.
 */
export function coarseBbox(p: LatLng, grid = 0.25, half = 0.5): [number, number, number, number] {
	const snap = (v: number) => Math.round(v / grid) * grid;
	const lat = snap(p.lat);
	const lng = snap(p.lng);
	const r = (v: number) => Math.round(v * 1000) / 1000;
	return [r(lng - half), r(lat - half), r(lng + half), r(lat + half)];
}

/** ~14 km grid, ±0.125°: the group is always ≥ ~7 km inside it. */
export const NEAR_BOX = { grid: 0.125, half: 0.125 } as const;

/** Enough answers from the near box, or look wider? */
export function needWider(ranked: Ranked[], heading: number | null, want = 3): boolean {
	const useful = heading == null ? ranked : ranked.filter((r) => r.ahead);
	return useful.length < want;
}

/** The line that goes over your car when you share it («⛽ محطة … — ١٢ كم قدّام»). */
export function shareLine(r: Ranked, isRTL: boolean, fmtKm: (m: number, rtl: boolean) => string): string {
	const label = r.name || r.brand || (r.kind === "fuel" ? (isRTL ? "محطة بنزين" : "Fuel station") : isRTL ? "قليب" : "Well");
	const icon = r.kind === "fuel" ? "⛽" : "💧";
	const where = r.ahead == null ? "" : r.ahead ? (isRTL ? " قدّام" : " ahead") : isRTL ? " ورانا" : " behind";
	const text = `${icon} ${label} — ${fmtKm(r.distanceM, isRTL)}${where}`;
	return [...text].slice(0, 80).join("");
}
