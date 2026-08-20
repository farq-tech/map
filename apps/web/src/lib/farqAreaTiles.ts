/**
 * The opportunity field — what the city looks like before there are pins.
 *
 * Below AREA_MAX_ZOOM the map shows H3 res-8 cells tinted by how many
 * opportunities they hold, with the biggest gap written on the busiest cells
 * only. Cells have no stroke, so they read as a soft field rather than a
 * grid; they fade out as the clusters fade in, so the whole thing is one
 * entity changing resolution, not two layers switching.
 */
import type { ExpressionSpecification, GeoJSONSource, Map as MapboxMap } from "mapbox-gl";
import { FARQ_BRAND_900, FARQ_MINT } from "./farqBrandAssets";
import type { CityAreas } from "../services/intelligenceService";

export const AREA_SOURCE = "farq-areas";
export const AREA_FILL = "farq-area-fill";
export const AREA_LABELS = "farq-area-labels";
/** Cells are gone by here; clusters own the picture from AREA_MAX_ZOOM on. */
export const AREA_MAX_ZOOM = 11.5;
export const AREA_FADE_START = 10.6;
/** Clusters appear here, inside the fade, so one picture hands over to the next. */
export const AREA_HANDOVER_ZOOM = 10.9;
/** How many cells may carry a number on screen — a budget, not a guess. */
export const AREA_LABEL_BUDGET = 8;

const COUNT: ExpressionSpecification = ["coalesce", ["get", "opportunities"], 0];

export function ensureAreaLayers(map: MapboxMap): void {
	if (map.getSource(AREA_SOURCE)) return;
	map.addSource(AREA_SOURCE, { type: "geojson", data: { type: "FeatureCollection", features: [] } });
	map.addLayer(
		{
			id: AREA_FILL,
			type: "fill",
			source: AREA_SOURCE,
			maxzoom: AREA_MAX_ZOOM,
			paint: {
				"fill-color": FARQ_MINT,
				"fill-emissive-strength": 1,
				/* three steps of opacity by count; the whole field fades as clusters arrive
				 * (zoom must be the top-level interpolate input, counts are its outputs) */
				"fill-opacity": [
					"interpolate",
					["linear"],
					["zoom"],
					AREA_FADE_START,
					["step", COUNT, 0, 1, 0.16, 8, 0.3, 25, 0.48],
					AREA_MAX_ZOOM,
					0,
				],
				"fill-antialias": false,
			},
		},
		/* under every symbol we draw, over the basemap */
		map.getLayer("farq-price-clusters") ? "farq-price-clusters" : undefined,
	);
	map.addLayer({
		id: AREA_LABELS,
		type: "symbol",
		source: AREA_SOURCE,
		maxzoom: AREA_MAX_ZOOM,
		filter: ["==", ["get", "labelled"], true],
		layout: {
			"text-field": ["to-string", ["get", "max_gap"]],
			"text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"],
			"text-size": 14,
			"text-allow-overlap": false,
			"symbol-sort-key": ["-", 0, ["coalesce", ["get", "max_gap"], 0]],
		},
		paint: {
			"text-color": FARQ_BRAND_900,
			"text-halo-color": "#FFFFFF",
			"text-halo-width": 1.6,
			"text-emissive-strength": 1,
			"text-opacity": ["interpolate", ["linear"], ["zoom"], AREA_FADE_START, 1, AREA_MAX_ZOOM, 0],
		},
	});
}

/** Only the busiest cells speak; everything else is colour. */
export function toAreaCollection(areas: CityAreas | null | undefined): GeoJSON.FeatureCollection {
	if (!areas) return { type: "FeatureCollection", features: [] };
	const ranked = [...areas.features]
		.filter((f) => f.properties.opportunities > 0)
		.sort((a, b) => b.properties.opportunities - a.properties.opportunities || (b.properties.max_gap || 0) - (a.properties.max_gap || 0));
	const labelled = new Set(ranked.slice(0, AREA_LABEL_BUDGET).map((f) => f.properties.h3));
	return {
		type: "FeatureCollection",
		features: ranked.map((f) => ({
			type: "Feature",
			id: f.properties.h3,
			geometry: f.geometry,
			properties: {
				h3: f.properties.h3,
				opportunities: f.properties.opportunities,
				max_gap: f.properties.max_gap,
				labelled: labelled.has(f.properties.h3),
			},
		})),
	};
}

export function syncAreaData(map: MapboxMap, areas: CityAreas | null | undefined): void {
	const src = map.getSource(AREA_SOURCE) as GeoJSONSource | undefined;
	if (!src || !("setData" in src)) return;
	src.setData(toAreaCollection(areas));
}
