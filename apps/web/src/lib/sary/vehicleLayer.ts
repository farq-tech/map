/**
 * Your car on the map as a real 3D model (Mapbox GL v3 `model` layer).
 *
 * It replaces the Prado PNG poses, which carried their own patch of sand: a
 * square of background that rotated with the car. The model has no background,
 * is lit by the map's own light, sits on the terrain and casts a shadow.
 *
 * It stays readable at every zoom: about the same on-screen size up to street
 * zoom, then its true size (≈4.9 m) once that is larger.
 */

import type { Map as MapboxMap } from "mapbox-gl";
import { suvModelUrl } from "./suvModel";

export const VEHICLE_SOURCE = "sary-vehicle";
export const VEHICLE_LAYER = "sary-vehicle-3d";

/** Degrees added to a compass heading so the model's nose (+Z in glTF) points that way. */
export const MODEL_HEADING_OFFSET = 180;

export function modelIdFor(hex: string): string {
	return `sary-suv-${hex.replace(/[^0-9a-f]/gi, "").toLowerCase()}`;
}

/** Scale per zoom: constant ~55 px until true size takes over (exponential base 2 = one zoom, half the scale). */
export const VEHICLE_SCALE: unknown = [
	"interpolate",
	["exponential", 2],
	["zoom"],
	8,
	["literal", [3136, 3136, 3136]],
	15,
	["literal", [49, 49, 49]],
	20,
	["literal", [1.6, 1.6, 1.6]],
	22,
	["literal", [1, 1, 1]],
];

export function vehicleRotation(heading: number | null): [number, number, number] {
	const h = heading == null || !Number.isFinite(heading) ? 0 : heading;
	return [0, 0, (((h + MODEL_HEADING_OFFSET) % 360) + 360) % 360];
}

export function vehicleFeature(pos: { lng: number; lat: number } | null): GeoJSON.FeatureCollection {
	return {
		type: "FeatureCollection",
		features: pos
			? [{ type: "Feature", properties: {}, geometry: { type: "Point", coordinates: [pos.lng, pos.lat] } }]
			: [],
	};
}

/** Whether this map can draw models at all (Mapbox GL v3 with WebGL2). */
export function canDrawModels(map: MapboxMap): boolean {
	return typeof (map as unknown as { addModel?: unknown }).addModel === "function";
}

/**
 * Adds (once per style) the model for this body colour, the source and the
 * layer. Safe to call repeatedly. Returns false when the map cannot draw it.
 */
export function ensureVehicleLayer(map: MapboxMap, bodyHex: string): boolean {
	if (!canDrawModels(map)) return false;
	const m = map as unknown as {
		addModel: (id: string, url: string) => void;
		hasModel?: (id: string) => boolean;
	};
	const id = modelIdFor(bodyHex);
	try {
		if (!m.hasModel || !m.hasModel(id)) m.addModel(id, suvModelUrl(bodyHex));
		if (!map.getSource(VEHICLE_SOURCE)) {
			map.addSource(VEHICLE_SOURCE, { type: "geojson", data: vehicleFeature(null) });
		}
		if (!map.getLayer(VEHICLE_LAYER)) {
			map.addLayer({
				id: VEHICLE_LAYER,
				type: "model",
				source: VEHICLE_SOURCE,
				layout: { "model-id": id },
				paint: {
					"model-type": "common-3d",
					"model-scale": VEHICLE_SCALE,
					"model-rotation": vehicleRotation(null),
					"model-cast-shadows": true,
					"model-receive-shadows": true,
					"model-emissive-strength": 0.6,
					"model-opacity": 1,
				},
			} as unknown as Parameters<MapboxMap["addLayer"]>[0]);
		} else {
			map.setLayoutProperty(VEHICLE_LAYER, "model-id", id);
		}
		return true;
	} catch {
		return false;
	}
}

export function setVehicle(map: MapboxMap, pos: { lng: number; lat: number } | null, heading: number | null): void {
	const src = map.getSource(VEHICLE_SOURCE) as { setData?: (d: GeoJSON.FeatureCollection) => void } | undefined;
	src?.setData?.(vehicleFeature(pos));
	if (map.getLayer(VEHICLE_LAYER)) {
		map.setPaintProperty(VEHICLE_LAYER, "model-rotation" as never, vehicleRotation(heading) as never);
	}
}

export function removeVehicle(map: MapboxMap): void {
	try {
		if (map.getLayer(VEHICLE_LAYER)) map.removeLayer(VEHICLE_LAYER);
		if (map.getSource(VEHICLE_SOURCE)) map.removeSource(VEHICLE_SOURCE);
	} catch {
		/* style swapped underneath us */
	}
}
