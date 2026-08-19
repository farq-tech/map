/**
 * Group opportunities by the neighbourhood polygon they fall inside.
 *
 * Counting is geometric, not by name: an opportunity belongs to a حي because
 * its coordinates are inside that حي's ring, never because a string matched.
 * If no polygon contains it, it is counted nowhere — a wrong حي is worse than
 * an uncounted one when the number ends up in front of an investor.
 */

export type NeighborhoodFeature = {
	type: "Feature";
	geometry: { type: string; coordinates: unknown } | null;
	properties: {
		neighborhood_id?: string;
		neighborhood_ar?: string | null;
		neighborhood_en?: string | null;
	} & Record<string, unknown>;
};

export type NeighborhoodTally = {
	id: string;
	nameAr: string | null;
	nameEn: string | null;
	count: number;
	topGap: number | null;
};

type Ring = Array<[number, number]>;
type Prepared = { id: string; nameAr: string | null; nameEn: string | null; polygons: Ring[][]; bbox: [number, number, number, number] };

function ringsOf(geometry: NeighborhoodFeature["geometry"]): Ring[][] {
	if (!geometry) return [];
	const coords = geometry.coordinates as unknown;
	if (geometry.type === "Polygon") return Array.isArray(coords) ? [coords as Ring[]] : [];
	if (geometry.type === "MultiPolygon") return Array.isArray(coords) ? (coords as Ring[][][]).flatMap((p) => [p as unknown as Ring[]]) : [];
	return [];
}

function boundsOf(polygons: Ring[][]): [number, number, number, number] {
	let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
	for (const rings of polygons) {
		for (const point of rings[0] ?? []) {
			if (point[0] < minX) minX = point[0];
			if (point[0] > maxX) maxX = point[0];
			if (point[1] < minY) minY = point[1];
			if (point[1] > maxY) maxY = point[1];
		}
	}
	return [minX, minY, maxX, maxY];
}

/** Ray casting. Even crossings means outside. */
function inRing(lng: number, lat: number, ring: Ring): boolean {
	let inside = false;
	for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
		const [xi, yi] = ring[i];
		const [xj, yj] = ring[j];
		if (yi > lat !== yj > lat && lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) inside = !inside;
	}
	return inside;
}

/** Outer ring counts, holes cut back out. */
function inPolygon(lng: number, lat: number, rings: Ring[]): boolean {
	if (!rings.length || !inRing(lng, lat, rings[0])) return false;
	for (let i = 1; i < rings.length; i += 1) if (inRing(lng, lat, rings[i])) return false;
	return true;
}

/** Bounds first: rejecting on four comparisons beats walking every vertex. */
function prepare(features: NeighborhoodFeature[]): Prepared[] {
	const out: Prepared[] = [];
	for (const feature of features) {
		const polygons = ringsOf(feature.geometry);
		if (!polygons.length) continue;
		const id = String(feature.properties?.neighborhood_id ?? "");
		if (!id) continue;
		out.push({
			id,
			nameAr: (feature.properties?.neighborhood_ar as string | null) ?? null,
			nameEn: (feature.properties?.neighborhood_en as string | null) ?? null,
			polygons,
			bbox: boundsOf(polygons),
		});
	}
	return out;
}

export function neighborhoodAt(prepared: Prepared[], lng: number, lat: number): Prepared | null {
	for (const hood of prepared) {
		const [minX, minY, maxX, maxY] = hood.bbox;
		if (lng < minX || lng > maxX || lat < minY || lat > maxY) continue;
		for (const rings of hood.polygons) if (inPolygon(lng, lat, rings)) return hood;
	}
	return null;
}

export type TallyInput = { id: string; lat: number; lng: number; gap: number | null };

/**
 * Counts per حي, plus which حي each opportunity landed in so a tap on the
 * polygon can list exactly the places it counted.
 */
export function tallyByNeighborhood(features: NeighborhoodFeature[], opportunities: TallyInput[]) {
	const prepared = prepare(features);
	const tallies = new Map<string, NeighborhoodTally>();
	const assignment = new Map<string, string>();
	for (const hood of prepared) tallies.set(hood.id, { id: hood.id, nameAr: hood.nameAr, nameEn: hood.nameEn, count: 0, topGap: null });
	for (const item of opportunities) {
		if (!Number.isFinite(item.lat) || !Number.isFinite(item.lng)) continue;
		const hood = neighborhoodAt(prepared, item.lng, item.lat);
		if (!hood) continue;
		assignment.set(item.id, hood.id);
		const tally = tallies.get(hood.id);
		if (!tally) continue;
		tally.count += 1;
		if (item.gap != null && (tally.topGap == null || item.gap > tally.topGap)) tally.topGap = item.gap;
	}
	return { tallies, assignment };
}

/** West, south, east, north — what the camera needs to frame one حي. */
export function neighborhoodBounds(feature: NeighborhoodFeature): [number, number, number, number] | null {
	const polygons = ringsOf(feature.geometry);
	if (!polygons.length) return null;
	const bbox = boundsOf(polygons);
	return Number.isFinite(bbox[0]) && bbox[0] <= bbox[2] && bbox[1] <= bbox[3] ? bbox : null;
}

/** A point to hang the label on: the centre of the bounds when that is inside. */
export function labelPoint(feature: NeighborhoodFeature): [number, number] | null {
	const polygons = ringsOf(feature.geometry);
	if (!polygons.length) return null;
	const [minX, minY, maxX, maxY] = boundsOf(polygons);
	if (!Number.isFinite(minX)) return null;
	const centre: [number, number] = [(minX + maxX) / 2, (minY + maxY) / 2];
	for (const rings of polygons) if (inPolygon(centre[0], centre[1], rings)) return centre;
	const outer = polygons[0][0] ?? [];
	if (!outer.length) return centre;
	const sum = outer.reduce((acc, p) => [acc[0] + p[0], acc[1] + p[1]] as [number, number], [0, 0] as [number, number]);
	return [sum[0] / outer.length, sum[1] / outer.length];
}

/** Polygons carrying their own count, ready for a choropleth. */
export function neighborhoodShapes(features: NeighborhoodFeature[], tallies: Map<string, NeighborhoodTally>): GeoJSON.FeatureCollection {
	return {
		type: "FeatureCollection",
		features: features.flatMap((feature) => {
			const id = String(feature.properties?.neighborhood_id ?? "");
			const tally = id ? tallies.get(id) : undefined;
			if (!tally || !feature.geometry) return [];
			return [{ type: "Feature" as const, id, properties: { neighborhood_id: id, count: tally.count }, geometry: feature.geometry as GeoJSON.Geometry }];
		}),
	};
}

/** One label per حي: its name and how many opportunities sit inside it. */
export function neighborhoodLabels(features: NeighborhoodFeature[], tallies: Map<string, NeighborhoodTally>, isRTL: boolean): GeoJSON.FeatureCollection {
	return {
		type: "FeatureCollection",
		features: features.flatMap((feature) => {
			const id = String(feature.properties?.neighborhood_id ?? "");
			const tally = id ? tallies.get(id) : undefined;
			const point = labelPoint(feature);
			if (!tally || !point || tally.count === 0) return [];
			const name = (isRTL ? tally.nameAr || tally.nameEn : tally.nameEn || tally.nameAr) || "";
			return [{
				type: "Feature" as const,
				id,
				properties: {
					neighborhood_id: id,
					count: tally.count,
					label: name ? `${name}\n${tally.count} ${isRTL ? "فرصة" : "opportunities"}` : `${tally.count}`,
				},
				geometry: { type: "Point" as const, coordinates: point },
			}];
		}),
	};
}
