/**
 * Viewport bbox helpers for the comparison map.
 * Search-here means “load opportunities in this view” — not a radius product.
 */

export type MapBbox = {
	west: number;
	south: number;
	east: number;
	north: number;
};

export type MapView = {
	bbox: string;
	zoom: number;
};

export type MapViewChangeMeta = {
	/** True only for a user pan/zoom/rotate (originalEvent / gesture). */
	userGesture?: boolean;
};

const MIN_CENTER_RATIO = 0.18;
const MIN_ZOOM_DELTA = 0.35;

export function parseMapBbox(bbox: string): MapBbox | null {
	const parts = String(bbox || "")
		.split(",")
		.map((n) => Number(n.trim()));
	if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) {
		return null;
	}
	const [west, south, east, north] = parts;
	if (east <= west || north <= south) return null;
	return { west, south, east, north };
}

export function bboxCenter(bbox: MapBbox): { lng: number; lat: number } {
	return {
		lng: (bbox.west + bbox.east) / 2,
		lat: (bbox.south + bbox.north) / 2,
	};
}

export function bboxSpan(bbox: MapBbox): { lng: number; lat: number } {
	return {
		lng: Math.abs(bbox.east - bbox.west),
		lat: Math.abs(bbox.north - bbox.south),
	};
}

export function lngLatInBbox(
	lng: number,
	lat: number,
	bbox: MapBbox,
): boolean {
	return lng >= bbox.west && lng <= bbox.east && lat >= bbox.south && lat <= bbox.north;
}

/** Center or zoom moved enough vs the last fetched view. */
export function viewMovedEnough(
	prev: MapView | null,
	next: MapView,
	opts?: { minCenterRatio?: number; minZoom?: number },
): boolean {
	if (!prev) return false;
	const minZoom = opts?.minZoom ?? MIN_ZOOM_DELTA;
	if (Math.abs(next.zoom - prev.zoom) >= minZoom) return true;
	const a = parseMapBbox(prev.bbox);
	const b = parseMapBbox(next.bbox);
	if (!a || !b) return prev.bbox !== next.bbox;
	const ca = bboxCenter(a);
	const cb = bboxCenter(b);
	const span = bboxSpan(a);
	const minRatio = opts?.minCenterRatio ?? MIN_CENTER_RATIO;
	return (
		Math.abs(cb.lng - ca.lng) > span.lng * minRatio ||
		Math.abs(cb.lat - ca.lat) > span.lat * minRatio
	);
}

/**
 * Show ابحث هنا only after a user gesture, once a viewport was already loaded,
 * and the camera left that fetched view. Programmatic flyTo/easeTo must not.
 */
export function shouldOfferSearchHere(opts: {
	userGesture: boolean;
	hasFetched: boolean;
	fetched: MapView | null;
	current: MapView;
}): boolean {
	if (!opts.userGesture || !opts.hasFetched) return false;
	return viewMovedEnough(opts.fetched, opts.current);
}

/** Camera box for search results. Same-coordinate piles get a tiny pad, not a merge. */
export function boundsFromPlaceFeatures(
	features: Array<{
		geometry?: { type?: string; coordinates?: unknown } | null;
		properties?: { feature_type?: string } | null;
	}>,
): [number, number, number, number] | null {
	let west = 180;
	let south = 90;
	let east = -180;
	let north = -90;
	let n = 0;
	for (const feature of features) {
		if (feature.properties?.feature_type === "cluster") continue;
		if (feature.geometry?.type !== "Point") continue;
		const coords = feature.geometry.coordinates;
		if (!Array.isArray(coords) || coords.length < 2) continue;
		const lng = Number(coords[0]);
		const lat = Number(coords[1]);
		if (!Number.isFinite(lng) || !Number.isFinite(lat)) continue;
		west = Math.min(west, lng);
		south = Math.min(south, lat);
		east = Math.max(east, lng);
		north = Math.max(north, lat);
		n += 1;
	}
	if (!n) return null;
	if (west === east || south === north) {
		const pad = 0.002;
		return [west - pad, south - pad, east + pad, north + pad];
	}
	return [west, south, east, north];
}

/** Observed pin coordinates from a collection — never invented, never guessed. */
export function pointFromPlaceCollection(
	collection:
		| { features?: Array<{
				geometry?: { type?: string; coordinates?: unknown } | null;
				properties?: { place_id?: unknown } | null;
		  }> }
		| null
		| undefined,
	placeId: string,
): { lat: number; lng: number } | null {
	const want = String(placeId || "").trim();
	if (!want) return null;
	for (const feature of collection?.features || []) {
		if (String(feature.properties?.place_id || "") !== want) continue;
		if (feature.geometry?.type !== "Point") continue;
		const coords = feature.geometry.coordinates;
		if (!Array.isArray(coords) || coords.length < 2) continue;
		const lng = Number(coords[0]);
		const lat = Number(coords[1]);
		if (!Number.isFinite(lng) || !Number.isFinite(lat)) continue;
		return { lat, lng };
	}
	return null;
}
