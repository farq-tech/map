/**
 * In town, a car is drawn on the street, not inside the house it is parked
 * beside: GPS in a city drifts 10–30 m into buildings, and a car in a living
 * room reads as a broken map.
 *
 * The street comes from Mapbox Streets' own road lines, already on the phone
 * as vector tiles (a hidden probe layer keeps them loaded). Only drivable
 * roads count, never desert tracks or footpaths, and only within MAX_SNAP_M
 * (60 m: city GPS under a roof drifts that far; no house is farther from a street)
 * — in open desert there is no street that close, so the car stays exactly
 * where GPS put it. This moves the drawing only: what is sent to the group
 * is always the real fix.
 */

import type { Map as MapboxMap } from "mapbox-gl";

export const ROAD_SOURCE = "sary-roads";
export const ROAD_PROBE_LAYER = "sary-roads-probe";
export const MAX_SNAP_M = 60;
export const MIN_SNAP_M = 25;

/**
 * How far a fix may be moved to a street: as far as its own uncertainty
 * reaches, between 25 m (a sharp fix only slides off a roof onto the street
 * beside it) and 60 m (indoors, where GPS drifts that far). A sharp fix is
 * never dragged onto a road it clearly is not on.
 */
export function snapRadius(accuracyM: number | null | undefined): number {
	if (accuracyM == null || !Number.isFinite(accuracyM)) return 40;
	return Math.max(MIN_SNAP_M, Math.min(MAX_SNAP_M, accuracyM * 1.5));
}

const DRIVABLE = [
	"motorway",
	"motorway_link",
	"trunk",
	"trunk_link",
	"primary",
	"primary_link",
	"secondary",
	"secondary_link",
	"tertiary",
	"tertiary_link",
	"street",
	"street_limited",
	"service",
];

type LngLat = { lng: number; lat: number };

/** One road line, with a key that names the road across tiles (same id, or same class + name). */
export type RoadLine = { key: string; coords: number[][] };

export function ensureRoadProbe(map: MapboxMap): void {
	try {
		if (!map.getSource(ROAD_SOURCE)) {
			map.addSource(ROAD_SOURCE, { type: "vector", url: "mapbox://mapbox.mapbox-streets-v8" });
		}
		if (!map.getLayer(ROAD_PROBE_LAYER)) {
			/* Invisible, but drawn, so its tiles load where the camera is. */
			map.addLayer({
				id: ROAD_PROBE_LAYER,
				type: "line",
				source: ROAD_SOURCE,
				"source-layer": "road",
				minzoom: 13,
				filter: ["match", ["get", "class"], DRIVABLE, true, false],
				paint: { "line-opacity": 0, "line-width": 1 },
			});
		}
	} catch {
		/* style swapped underneath us; next call adds it */
	}
}

/**
 * The nearest point on any of `lines` within maxM metres of p, or null.
 * Lines are [lng, lat] coordinate arrays. Exported for tests.
 */
export function nearestOnLines(p: LngLat, lines: number[][][], maxM = MAX_SNAP_M): LngLat | null {
	const kx = 111_320 * Math.cos((p.lat * Math.PI) / 180);
	const ky = 110_540;
	let best: LngLat | null = null;
	let bestD = maxM;
	for (const line of lines) {
		for (let i = 0; i + 1 < line.length; i += 1) {
			/* Local metres around p: plenty accurate over a few dozen metres. */
			const ax = (line[i][0] - p.lng) * kx;
			const ay = (line[i][1] - p.lat) * ky;
			const bx = (line[i + 1][0] - p.lng) * kx;
			const by = (line[i + 1][1] - p.lat) * ky;
			const dx = bx - ax;
			const dy = by - ay;
			const len2 = dx * dx + dy * dy;
			const t = len2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2)) : 0;
			const x = ax + t * dx;
			const y = ay + t * dy;
			const d = Math.hypot(x, y);
			if (d < bestD) {
				bestD = d;
				best = { lng: p.lng + x / kx, lat: p.lat + y / ky };
			}
		}
	}
	return best;
}

/** Drivable road lines near p (with a pad of ~150 m), from the probe layer's tiles. */
export function queryRoadLines(map: MapboxMap, p: LngLat): RoadLine[] {
	if (!map.getSource(ROAD_SOURCE)) return [];
	const feats = map.querySourceFeatures(ROAD_SOURCE, {
		sourceLayer: "road",
		filter: ["match", ["get", "class"], DRIVABLE, true, false],
	});
	/* Cheap box first: only lines with a vertex near p. */
	const pad = 0.0015;
	const lines: RoadLine[] = [];
	for (const f of feats) {
		const g = f.geometry;
		const parts = g.type === "LineString" ? [g.coordinates] : g.type === "MultiLineString" ? g.coordinates : [];
		const props = (f.properties || {}) as Record<string, unknown>;
		/* A road cut at a tile edge comes back as two features with the same id. */
		const key = f.id != null ? `id:${f.id}` : `${props.class ?? ""}:${props.name ?? props.ref ?? ""}`;
		for (const line of parts) {
			if (line.some(([x, y]) => Math.abs(x - p.lng) < pad && Math.abs(y - p.lat) < pad)) lines.push({ key, coords: line });
		}
	}
	return lines;
}

/** p moved onto the nearest drivable street within maxM, else p itself. */
export function snapToRoad(map: MapboxMap, p: LngLat, maxM = MAX_SNAP_M): LngLat {
	try {
		return nearestOnLines(p, queryRoadLines(map, p).map((l) => l.coords), maxM) || p;
	} catch {
		return p;
	}
}

/* ------------------------------------------------------------------ */
/* Road matching across fixes: stay on the same road, prefer the road  */
/* the car is actually driving along, and point the car down it.       */
/* ------------------------------------------------------------------ */

/** How many metres a road 90° off the car's course "costs" over one it is driving along. */
export const BEARING_PENALTY_M = 25;
/** A different road must beat the current one by this much… */
export const SWITCH_MARGIN_M = 5;
/** …on this many fixes in a row before the car is moved onto it. */
export const SWITCH_FIXES = 2;
/** Draw the car along the road only when its course is within this of the road's direction. */
export const ALIGN_MAX_DEG = 40;

export type RoadCandidate = {
	key: string;
	point: LngLat;
	distM: number;
	/** Direction of the road segment at the nearest point, 0–360 (the line's own drawing order). */
	bearing: number;
};

/** Smallest angle between two headings, 0–180. */
export function angleDiff(a: number, b: number): number {
	const d = Math.abs((((a - b) % 360) + 360) % 360);
	return d > 180 ? 360 - d : d;
}

/** Smallest angle between a course and a two-way road, 0–90. */
export function axialDiff(course: number, roadBearing: number): number {
	const d = angleDiff(course, roadBearing);
	return d > 90 ? 180 - d : d;
}

/** The nearest point on each road (one per key) within maxM of p, nearest first. Exported for tests. */
export function roadCandidates(p: LngLat, lines: RoadLine[], maxM = MAX_SNAP_M): RoadCandidate[] {
	const kx = 111_320 * Math.cos((p.lat * Math.PI) / 180);
	const ky = 110_540;
	const best = new Map<string, RoadCandidate>();
	for (const { key, coords: line } of lines) {
		for (let i = 0; i + 1 < line.length; i += 1) {
			const ax = (line[i][0] - p.lng) * kx;
			const ay = (line[i][1] - p.lat) * ky;
			const bx = (line[i + 1][0] - p.lng) * kx;
			const by = (line[i + 1][1] - p.lat) * ky;
			const dx = bx - ax;
			const dy = by - ay;
			const len2 = dx * dx + dy * dy;
			if (!len2) continue;
			const t = Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2));
			const x = ax + t * dx;
			const y = ay + t * dy;
			const d = Math.hypot(x, y);
			if (d > maxM) continue;
			const prev = best.get(key);
			if (prev && prev.distM <= d) continue;
			best.set(key, {
				key,
				point: { lng: p.lng + x / kx, lat: p.lat + y / ky },
				distM: d,
				bearing: ((Math.atan2(dx, dy) * 180) / Math.PI + 360) % 360,
			});
		}
	}
	return [...best.values()].sort((a, b) => a.distM - b.distM);
}

/** Distance, plus a penalty for a road that runs across the car's course rather than along it. */
export function candidateCost(c: RoadCandidate, course: number | null): number {
	if (course == null || !Number.isFinite(course)) return c.distM;
	return c.distM + (BEARING_PENALTY_M * axialDiff(course, c.bearing)) / 90;
}

/**
 * The drawn heading: the road's own direction (whichever way along it is
 * nearer the car's course) when the car is moving along it; the car's own
 * course otherwise (turning, or crossing at a junction). Null stays null —
 * a parked car is never given a direction it did not report.
 */
export function alignHeading(course: number | null, roadBearing: number | null): number | null {
	if (course == null || !Number.isFinite(course)) return null;
	if (roadBearing == null) return course;
	if (axialDiff(course, roadBearing) > ALIGN_MAX_DEG) return course;
	return angleDiff(course, roadBearing) <= 90 ? roadBearing : (roadBearing + 180) % 360;
}

export type RoadMatch = {
	/** Where to draw the car (the fix itself when no road is near). */
	point: LngLat;
	/** Which road it is drawn on, or null. */
	key: string | null;
	/** Direction to draw it (see alignHeading). */
	heading: number | null;
};

/**
 * Per-car road matching. Nearest-line snapping alone makes a car flicker
 * between two parallel streets 20 m apart as GPS wanders; this keeps the car
 * on the road it was on until another road is clearly better (by
 * SWITCH_MARGIN_M, on SWITCH_FIXES fixes in a row), and scores roads by how
 * well they line up with the car's course, so at a junction the street it
 * turned into wins over the one it left. Display only — never the shared fix.
 */
export class RoadMatcher {
	private current: string | null = null;
	private challenger: string | null = null;
	private challengerCount = 0;
	private last: { p: LngLat; result: RoadMatch } | null = null;

	reset(): void {
		this.current = null;
		this.challenger = null;
		this.challengerCount = 0;
		this.last = null;
	}

	/** The road the car is held on (for tests and QA). */
	get road(): string | null {
		return this.current;
	}

	match(p: LngLat, lines: RoadLine[], course: number | null, maxM = MAX_SNAP_M): RoadMatch {
		/* Re-renders call again with the same fix: that is not a second fix. */
		const l = this.last;
		if (l && l.p.lng === p.lng && l.p.lat === p.lat) return l.result;
		const result = this.step(p, lines, course, maxM);
		this.last = { p, result };
		return result;
	}

	private step(p: LngLat, lines: RoadLine[], course: number | null, maxM: number): RoadMatch {
		const cands = roadCandidates(p, lines, maxM);
		if (!cands.length) {
			this.reset();
			return { point: p, key: null, heading: course };
		}
		let best = cands[0];
		let bestCost = candidateCost(best, course);
		for (const c of cands) {
			const k = candidateCost(c, course);
			if (k < bestCost) {
				best = c;
				bestCost = k;
			}
		}
		const held = this.current ? cands.find((c) => c.key === this.current) : undefined;
		let chosen = best;
		if (held && held.key !== best.key) {
			const clearlyBetter = bestCost + SWITCH_MARGIN_M < candidateCost(held, course);
			if (clearlyBetter) {
				this.challengerCount = this.challenger === best.key ? this.challengerCount + 1 : 1;
				this.challenger = best.key;
			} else {
				this.challenger = null;
				this.challengerCount = 0;
			}
			if (this.challengerCount < SWITCH_FIXES) chosen = held;
		}
		if (chosen.key !== this.current) {
			this.current = chosen.key;
			this.challenger = null;
			this.challengerCount = 0;
		} else if (chosen === best) {
			this.challenger = null;
			this.challengerCount = 0;
		}
		return { point: chosen.point, key: chosen.key, heading: alignHeading(course, chosen.bearing) };
	}
}

/** Match p for one car against the roads already loaded on the map; p itself on any failure. */
export function matchOnMap(map: MapboxMap, matcher: RoadMatcher, p: LngLat, course: number | null, maxM = MAX_SNAP_M): RoadMatch {
	try {
		return matcher.match(p, queryRoadLines(map, p), course, maxM);
	} catch {
		return { point: p, key: null, heading: course };
	}
}
