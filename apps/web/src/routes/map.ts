import { encodeMapFilters, parseMapFilters } from "../lib/mapFilters";
import type { MapValueFilter } from "../lib/mapFilters";
import { safeGet, safeSet } from "../lib/safeStorage";

export type MapViewMode = "list" | "map";
export type MapSort = "gap" | "near" | "cheap" | "value";
export type { MapValueFilter };

export type MapSearch = {
	neighborhood?: string;
	category?: string;
	city?: string;
	q?: string;
	place?: string;
	sector?: string;
	filter?: string;
	view?: MapViewMode;
	sort?: MapSort;
	/** Camera: bbox "west,south,east,north" (4 decimals) and zoom — so a link restores the scene. */
	b?: string;
	z?: number;
};

export type CameraBbox = [number, number, number, number];

export function parseCameraBbox(raw: unknown): CameraBbox | undefined {
	const parts = String(raw || "")
		.split(",")
		.map((v) => Number(v));
	if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) return undefined;
	const [w, s, e, n] = parts;
	if (w >= e || s >= n) return undefined;
	if (w < -180 || e > 180 || s < -85 || n > 85) return undefined;
	return [w, s, e, n];
}

export function parseCameraZoom(raw: unknown): number | undefined {
	const z = Number(raw);
	if (!Number.isFinite(z) || z < 2 || z > 20) return undefined;
	return Math.round(z * 100) / 100;
}

/** Compact, stable encoding for replaceState on every idle move. */
export function encodeCameraBbox(b: CameraBbox): string {
	return b.map((v) => v.toFixed(4)).join(",");
}

function trim(v: unknown, max: number): string | undefined {
	if (typeof v !== "string") return undefined;
	const t = v.trim().slice(0, max);
	return t || undefined;
}

export function parseMapView(raw: unknown): MapViewMode | undefined {
	const v = String(raw || "")
		.trim()
		.toLowerCase();
	if (v === "list" || v === "map") return v;
	return undefined;
}

export function parseMapSort(raw: unknown): MapSort | undefined {
	const v = String(raw || "")
		.trim()
		.toLowerCase();
	if (v === "gap" || v === "near" || v === "cheap" || v === "value") return v;
	return undefined;
}

/** `/map` defaults to map; `/` defaults to list. Explicit `view=` always wins. */
export function resolveMapView(
	search: Pick<MapSearch, "view">,
	pathname: string,
): MapViewMode {
	if (search.view) return search.view;
	return pathname === "/map" ? "map" : "list";
}

export function resolveMapSort(search: Pick<MapSearch, "sort">): MapSort {
	return search.sort || "gap";
}

export function parseMapSearch(s: Record<string, unknown>): MapSearch {
	return {
		neighborhood: trim(s.neighborhood, 120),
		category: trim(s.category, 40),
		city: trim(s.city, 40),
		q: trim(s.q, 200),
		place: trim(s.place, 80),
		sector: trim(s.sector, 24),
		filter: encodeMapFilters(parseMapFilters(s.filter)),
		view: parseMapView(s.view),
		sort: parseMapSort(s.sort),
		b: parseCameraBbox(s.b) ? encodeCameraBbox(parseCameraBbox(s.b) as CameraBbox) : undefined,
		z: parseCameraZoom(s.z),
	};
}

const MAP_RETURN_KEY = "farq-map-return";

/** Last map scene so merchant "Back to map" restores camera, place, and filters. */
export function writeMapReturn(search: MapSearch): void {
	safeSet("sessionStorage", MAP_RETURN_KEY, JSON.stringify(parseMapSearch({ ...search })));
}

export function readMapReturn(): MapSearch {
	try {
		const raw = JSON.parse(safeGet("sessionStorage", MAP_RETURN_KEY) || "{}") as unknown;
		if (!raw || typeof raw !== "object") return {};
		return parseMapSearch(raw as Record<string, unknown>);
	} catch {
		return {};
	}
}

export function mapReturnSearch(placeId?: string): MapSearch {
	const saved = readMapReturn();
	const want = String(placeId || "").trim();
	const savedPlace = String(saved.place || "").trim();
	/* Another restaurant's camera/filters would open the wrong scene. */
	if (want && savedPlace && want !== savedPlace) {
		return parseMapSearch({ place: want });
	}
	const place = want || savedPlace;
	return parseMapSearch({
		...saved,
		...(place ? { place } : {}),
	});
}

/** Session camera belongs to the last pan — a bare ?place= link must fly itself. */
export function resumeMapSessionCamera(search: Pick<MapSearch, "place" | "b" | "z">): boolean {
	const hasCamera = Boolean(parseCameraBbox(search.b) && parseCameraZoom(search.z));
	if (hasCamera) return true;
	return !String(search.place || "").trim();
}
