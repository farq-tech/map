import type { GeoJSONSource, Map as MapboxMap, MapLayerMouseEvent } from "mapbox-gl";

export const SARY_PLACES = "sary-places";
export const SARY_PLACES_CIRCLE = "sary-places-circle";
export const SARY_TRACKS = "sary-tracks";
export const SARY_TRACKS_CASING = "sary-tracks-casing";
export const SARY_TRACKS_LINE = "sary-tracks-line";
export const SARY_MY_TRACK = "sary-my-track";
export const SARY_MY_TRACK_LINE = "sary-my-track-line";

const EMPTY: GeoJSON.FeatureCollection = { type: "FeatureCollection", features: [] };

function setGeo(map: MapboxMap, id: string, data: GeoJSON.FeatureCollection) {
	const src = map.getSource(id);
	if (src && src.type === "geojson") {
		(src as GeoJSONSource).setData(data);
		return;
	}
	map.addSource(id, { type: "geojson", data });
}

export function ensureSaryLayers(map: MapboxMap, onSelect: (id: string) => void) {
	setGeo(map, SARY_TRACKS, EMPTY);
	setGeo(map, SARY_PLACES, EMPTY);
	setGeo(map, SARY_MY_TRACK, EMPTY);

	if (!map.getLayer(SARY_TRACKS_CASING)) {
		map.addLayer({
			id: SARY_TRACKS_CASING,
			type: "line",
			source: SARY_TRACKS,
			layout: { "line-cap": "round", "line-join": "round" },
			paint: {
				"line-color": "#ffffff",
				"line-width": 4.2,
				"line-opacity": 0.72,
			},
		});
	}
	if (!map.getLayer(SARY_TRACKS_LINE)) {
		map.addLayer({
			id: SARY_TRACKS_LINE,
			type: "line",
			source: SARY_TRACKS,
			layout: { "line-cap": "round", "line-join": "round" },
			paint: {
				"line-color": "#E8842C",
				"line-width": 2.1,
				"line-opacity": 0.92,
			},
		});
	}
	if (!map.getLayer(SARY_MY_TRACK_LINE)) {
		map.addLayer({
			id: SARY_MY_TRACK_LINE,
			type: "line",
			source: SARY_MY_TRACK,
			layout: { "line-cap": "round", "line-join": "round" },
			paint: {
				"line-color": "#F4E7C5",
				"line-width": 3.4,
				"line-dasharray": [1.2, 1.1],
				"line-opacity": 0.95,
			},
		});
	}
	if (!map.getLayer(SARY_PLACES_CIRCLE)) {
		map.addLayer({
			id: SARY_PLACES_CIRCLE,
			type: "circle",
			source: SARY_PLACES,
			paint: {
				"circle-radius": 6,
				"circle-color": [
					"match",
					["get", "kind"],
					"well",
					"#3D9BE9",
					"spring",
					"#5EEAD4",
					"camp",
					"#E8842C",
					"rawdah",
					"#86B56A",
					"fayad",
					"#86B56A",
					"shaib",
					"#7EB6C9",
					"wadi",
					"#7EB6C9",
					"#F4E7C5",
				],
				"circle-stroke-color": "#ffffff",
				"circle-stroke-width": 1.4,
			},
		});
	}

	const pick = (e: MapLayerMouseEvent) => {
		const id = String(e.features?.[0]?.properties?.id || "").trim();
		if (id) onSelect(id);
	};
	if (!(map as unknown as { __saryClick?: boolean }).__saryClick) {
		map.on("click", SARY_PLACES_CIRCLE, pick);
		map.on("click", SARY_TRACKS_LINE, pick);
		(map as unknown as { __saryClick?: boolean }).__saryClick = true;
	}
}

export function syncSaryData(
	map: MapboxMap,
	opts: {
		places: GeoJSON.FeatureCollection;
		tracks: GeoJSON.FeatureCollection;
		myTrack: GeoJSON.FeatureCollection;
		layer: "around" | "tracks" | "places" | "trips";
	},
) {
	setGeo(map, SARY_PLACES, opts.layer === "tracks" ? EMPTY : opts.places);
	setGeo(map, SARY_TRACKS, opts.layer === "places" ? EMPTY : opts.tracks);
	setGeo(map, SARY_MY_TRACK, opts.myTrack);
}

export function setSaryTerrain(map: MapboxMap, enabled: boolean) {
	try {
		if (!enabled) {
			map.setTerrain(null);
			return;
		}
		if (!map.getSource("mapbox-dem")) {
			map.addSource("mapbox-dem", {
				type: "raster-dem",
				url: "mapbox://mapbox.mapbox-terrain-dem-v1",
				tileSize: 512,
				maxzoom: 14,
			});
		}
		map.setTerrain({ source: "mapbox-dem", exaggeration: 1.15 });
	} catch {
		/* classic styles / token without terrain */
	}
}
