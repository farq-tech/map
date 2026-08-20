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
