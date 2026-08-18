import { MapboxSearchBox } from "@mapbox/search-js-web";
import type { Map as MapboxMap } from "mapbox-gl";
import mapboxgl from "mapbox-gl";
import { RIYADH_LNG_LAT } from "./mapboxAccess";

export function createFarqSearchBox(opts: {
	token: string;
	isRTL: boolean;
	marker?: boolean;
}): MapboxSearchBox {
	const box = new MapboxSearchBox();
	box.accessToken = opts.token;
	box.mapboxgl = mapboxgl;
	box.marker = opts.marker ?? false;
	box.options = {
		language: opts.isRTL ? "ar" : "en",
		country: "SA",
		proximity: RIYADH_LNG_LAT,
		limit: 6,
	};
	box.placeholder = opts.isRTL
		? "ابحث عن عنوان أو حي…"
		: "Search an address or district…";
	box.componentOptions = { flyTo: true, allowReverse: true };
	return box;
}

export function lngLatFromSearchRetrieve(detail: unknown): {
	lat: number;
	lng: number;
} | null {
	const features = (
		detail as { features?: Array<{ geometry?: { coordinates?: unknown } }> }
	)?.features;
	const coords = features?.[0]?.geometry?.coordinates;
	if (!Array.isArray(coords) || coords.length < 2) return null;
	const lng = Number(coords[0]);
	const lat = Number(coords[1]);
	if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
	return { lat, lng };
}

export function bindSearchBoxToMap(box: MapboxSearchBox, map: MapboxMap): void {
	try {
		box.bindMap(map);
	} catch {
		/* Search Box still works as a standalone input */
	}
}
