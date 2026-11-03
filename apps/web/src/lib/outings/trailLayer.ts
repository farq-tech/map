/**
 * Draws Trails (trail.ts) as one GeoJSON line layer under the cars.
 * Data lives only in this tab's memory; the source is rebuilt from it.
 */

import type { GeoJSONSource, Map as MapboxMap } from "mapbox-gl";

export const TRAIL_SOURCE = "sary-outing-trails";
export const TRAIL_LAYER = "sary-outing-trails-line";

const EMPTY: GeoJSON.FeatureCollection = { type: "FeatureCollection", features: [] };

export function ensureTrailLayer(map: MapboxMap): boolean {
	try {
		if (!map.getSource(TRAIL_SOURCE)) map.addSource(TRAIL_SOURCE, { type: "geojson", data: EMPTY });
		if (!map.getLayer(TRAIL_LAYER)) {
			/* Under the first car model, so a trail never paints over a car. */
			const firstCar = map.getStyle()?.layers?.find((l) => l.type === "model")?.id;
			map.addLayer(
				{
					id: TRAIL_LAYER,
					type: "line",
					source: TRAIL_SOURCE,
					layout: { "line-cap": "round", "line-join": "round" },
					paint: {
						"line-color": ["get", "color"],
						"line-opacity": ["get", "opacity"],
						"line-width": ["interpolate", ["linear"], ["zoom"], 10, 2, 16, 5],
						"line-emissive-strength": 1,
					},
				},
				firstCar,
			);
		}
		return true;
	} catch {
		/* style mid-swap; the next sync retries */
		return false;
	}
}

export function setTrailData(map: MapboxMap, data: GeoJSON.FeatureCollection): void {
	if (!ensureTrailLayer(map)) return;
	(map.getSource(TRAIL_SOURCE) as GeoJSONSource | undefined)?.setData(data);
}

export function removeTrailLayer(map: MapboxMap): void {
	try {
		if (map.getLayer(TRAIL_LAYER)) map.removeLayer(TRAIL_LAYER);
		if (map.getSource(TRAIL_SOURCE)) map.removeSource(TRAIL_SOURCE);
	} catch {
		/* map already gone */
	}
}
