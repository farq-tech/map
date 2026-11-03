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

/** p moved onto the nearest drivable street within maxM, else p itself. */
export function snapToRoad(map: MapboxMap, p: LngLat, maxM = MAX_SNAP_M): LngLat {
	try {
		if (!map.getSource(ROAD_SOURCE)) return p;
		const feats = map.querySourceFeatures(ROAD_SOURCE, {
			sourceLayer: "road",
			filter: ["match", ["get", "class"], DRIVABLE, true, false],
		});
		/* Cheap box first: only segments with a vertex near p. */
		const pad = 0.0015;
		const lines: number[][][] = [];
		for (const f of feats) {
			const g = f.geometry;
			const parts = g.type === "LineString" ? [g.coordinates] : g.type === "MultiLineString" ? g.coordinates : [];
			for (const line of parts) {
				if (line.some(([x, y]) => Math.abs(x - p.lng) < pad && Math.abs(y - p.lat) < pad)) lines.push(line);
			}
		}
		return nearestOnLines(p, lines, maxM) || p;
	} catch {
		return p;
	}
}
