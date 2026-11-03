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
/** The exact GPS point under the car, flat on the ground. */
export const VEHICLE_SPOT_LAYER = "sary-vehicle-spot";

/** Degrees added to a compass heading so the model's nose (+Z in glTF) points that way. */
export const MODEL_HEADING_OFFSET = 180;

export function modelIdFor(hex: string): string {
	return `sary-suv-${hex.replace(/[^0-9a-f]/gi, "").toLowerCase()}`;
}

/** On-screen length the car keeps until its true size (≈4.9 m) is larger. */
export const VEHICLE_SCREEN_PX = 36;
const CAR_LENGTH_M = 4.9;
/* Metres per CSS pixel at zoom 0 around Saudi latitudes (cos 25°). */
const MPP_Z0 = 156543.03 * Math.cos((25 * Math.PI) / 180);

export function vehicleScaleAt(zoom: number): number {
	return Math.max(1, (VEHICLE_SCREEN_PX * (MPP_Z0 / 2 ** zoom)) / CAR_LENGTH_M);
}

/**
 * Height grows much less than length and width. A car enlarged 20× to stay
 * readable would otherwise stand 40 m tall, and on a tilted map it would rise
 * over the buildings and look as if it sat somewhere other than its fix.
 */
export function vehicleHeightScale(s: number): number {
	return Math.round((1 + (s - 1) * 0.25) * 100) / 100;
}

/**
 * model-scale by zoom. Mapbox's exponential interpolation bends the *curve*
 * between two stops, it does not halve a value per zoom — so the halving is
 * written out as one linear stop per zoom level. Model units are metres
 * (scale 1 = true size, checked against parked cars in the imagery).
 */
export const VEHICLE_SCALE: unknown = [
	"interpolate",
	["linear"],
	["zoom"],
	...Array.from({ length: 19 }, (_, i) => 4 + i).flatMap((z) => {
		const v = Math.round(vehicleScaleAt(z) * 100) / 100;
		return [z, ["literal", [v, v, v]]];
	}),
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
	const m = map as unknown as { addModel: (id: string, url: string) => void };
	const id = modelIdFor(bodyHex);
	try {
		/* map.hasModel() throws on import-based styles (Standard, 3.28), so we
		 * remember what we added, and forget it whenever the style is replaced. */
		let added = addedModels.get(map);
		if (!added) {
			added = new Set();
			addedModels.set(map, added);
			const set = added;
			map.on("style.load", () => set.clear());
		}
		if (!added.has(id)) {
			m.addModel(id, suvModelUrl(bodyHex));
			added.add(id);
		}
		if (!map.getSource(VEHICLE_SOURCE)) {
			map.addSource(VEHICLE_SOURCE, { type: "geojson", data: vehicleFeature(null) });
		}
		if (!map.getLayer(VEHICLE_SPOT_LAYER)) {
			map.addLayer({
				id: VEHICLE_SPOT_LAYER,
				type: "circle",
				source: VEHICLE_SOURCE,
				paint: {
					"circle-radius": 6,
					"circle-color": "#e8862e",
					"circle-stroke-color": "#ffffff",
					"circle-stroke-width": 2.5,
					"circle-pitch-alignment": "map",
					"circle-emissive-strength": 1,
				},
			} as unknown as Parameters<MapboxMap["addLayer"]>[0]);
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
	} catch (e) {
		/* Say why once; the caller falls back to the 2D marker. */
		if (!warned) {
			warned = true;
			console.warn("[sary-vehicle] 3D car unavailable:", e instanceof Error ? e.message : e);
		}
		return false;
	}
}

let warned = false;
const addedModels = new WeakMap<MapboxMap, Set<string>>();

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
		if (map.getLayer(VEHICLE_SPOT_LAYER)) map.removeLayer(VEHICLE_SPOT_LAYER);
		if (map.getSource(VEHICLE_SOURCE)) map.removeSource(VEHICLE_SOURCE);
	} catch {
		/* style swapped underneath us */
	}
}

type LngLat = { lng: number; lat: number };

export function distanceMeters(a: LngLat, b: LngLat): number {
	const r = Math.PI / 180;
	const x = (b.lng - a.lng) * r * Math.cos(((a.lat + b.lat) / 2) * r);
	const y = (b.lat - a.lat) * r;
	return Math.hypot(x, y) * 6_371_000;
}

/** Compass bearing from a to b, 0 = north, 90 = east. */
export function bearingBetween(a: LngLat, b: LngLat): number {
	const r = Math.PI / 180;
	const x = (b.lng - a.lng) * Math.cos(((a.lat + b.lat) / 2) * r);
	const y = b.lat - a.lat;
	return ((Math.atan2(x, y) / r) % 360 + 360) % 360;
}
