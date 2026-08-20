export type MapViewMode = "list" | "map";
export type MapSort = "gap" | "near" | "cheap";

export type MapSearch = {
	neighborhood?: string;
	category?: string;
	city?: string;
	q?: string;
	place?: string;
	view?: MapViewMode;
	sort?: MapSort;
};

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
	if (v === "gap" || v === "near" || v === "cheap") return v;
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
		view: parseMapView(s.view),
		sort: parseMapSort(s.sort),
	};
}
