export type FarqMapEvent =
	| "map_open"
	| "map_ready"
	| "map_zoom"
	| "map_pan"
	| "category_changed"
	| "opportunity_seen"
	| "opportunity_selected"
	| "popup_open"
	| "next_opportunity"
	| "compare_clicked"
	| "provider_opened"
	| "location_requested";

export function trackFarqMap(event: FarqMapEvent, payload: Record<string, unknown> = {}) {
	if (typeof window === "undefined") return;
	const detail = { event, ...payload, ts: Date.now() };
	window.dispatchEvent(new CustomEvent("farq:map", { detail }));
	if (import.meta.env.DEV) console.debug("[farq:map]", detail);
}
