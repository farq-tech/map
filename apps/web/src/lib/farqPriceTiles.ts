/**
 * GPU savings beacons. FAR (z<14): mint circle + gap number only (no emoji:
 * Mapbox glyphs stop at U+FFFF, so 🔥 never rendered and only warned).
 * NEAR (z≥14): opportunity + «N ر.س فرق», then cheapest-provider mark.
 * Display set is the same top-N as the list — no 400-pin restaurant farm.
 * HTML markers are the selected pin only.
 */
import type {
	GeoJSONSource,
	Map as MapboxMap,
	MapLayerMouseEvent,
} from "mapbox-gl";
import { FARQ_BRAND_900, FARQ_MINT } from "./farqBrandAssets";
import {
	CLUSTER_BREAK_ZOOM,
	observedDifferenceAmount,
	parseDifference,
} from "./farqMapPins";
import {
	ALL_PLATFORM_KEYS,
	normalizePlatformKey,
	PLATFORM_LOGOS,
	type PlatformKey,
} from "./platformLogos";

export const PRICE_TILE_SOURCE = "farq-price-tiles";
export const PRICE_TILE_HALO = "farq-price-halo";
export const PRICE_TILE_CIRCLES = "farq-price-circles";
export const PRICE_TILE_LABELS = "farq-price-labels";
export const PRICE_TILE_CLUSTER_HALO = "farq-price-cluster-halo";
export const PRICE_TILE_CLUSTERS = "farq-price-clusters";
export const PRICE_TILE_CLUSTER_COUNT = "farq-price-cluster-count";
export const PRICE_TILE_ICONS = "farq-price-icons";
export const PRICE_TILE_CHIPS = "farq-price-chips";
export const PRICE_TILE_CHIP_LABELS = "farq-price-chip-labels";
export const PRICE_TILE_NEAR_TEXT = "farq-price-near-text";

/** Radiant mint fill — number is dark Farq teal `#043434`, never white on mint. */
export const PRICE_CIRCLE_FILL = FARQ_MINT;
export const PRICE_CIRCLE_HALO = "#A8F8C9";
/* Standard's dusk/night presets colour-grade every layer that is not emissive;
 * without emissive strength the mint discs rendered as dark teal in production. */
export const PRICE_CIRCLE_STROKE = "#FFFFFF";
export const PRICE_CIRCLE_TEXT = FARQ_BRAND_900;

export const GPU_ICON_PREFIX = "farq-icon-";
export const GPU_ICON_FALLBACK = "farq-icon-fallback";
export const GPU_ICON_PX = 40;
/** Near-band mint chip — 24px, teal `#043434` on mint `#83F1B1`. */
export const GPU_CHIP_PX = 24;
export const GPU_CHIP_RADIUS = 12;
export const GPU_CHIP_TEXT_SIZE = 13;
/** FAR city beacons — big readable gap, no logos. */
export const FAR_BEACON_PX = 36;
export const FAR_BEACON_RADIUS = 18;
export const FAR_BEACON_TEXT_SIZE = 15;
export const GPU_CLUSTER_TEXT_SIZE = 15;
export const GPU_CLUSTER_RADIUS = 18;

const lastTileHash = new WeakMap<MapboxMap, string>();

export function gpuIconId(key: PlatformKey | string | null | undefined): string {
	const normalized = normalizePlatformKey(key);
	return normalized ? `${GPU_ICON_PREFIX}${normalized}` : GPU_ICON_FALLBACK;
}

export function pinGapAmount(props: {
	gap?: unknown;
	difference?: unknown;
} | null | undefined): number | null {
	if (props == null) return null;
	const raw = Number(props.gap);
	if (Number.isFinite(raw) && Math.round(raw) >= 1) return raw;
	return observedDifferenceAmount(props.difference);
}

export function cheapestProviderId(props: {
	cheapest_provider_id?: unknown;
	difference?: unknown;
} | null | undefined): string | null {
	if (props == null) return null;
	const slim = normalizePlatformKey(props.cheapest_provider_id);
	if (slim) return slim;
	return normalizePlatformKey(
		parseDifference(props.difference)?.cheapest_provider_id,
	);
}

export function toPriceTileCollection(
	places: GeoJSON.FeatureCollection | null | undefined,
	selectedPlaceId?: string,
): GeoJSON.FeatureCollection {
	const selected = String(selectedPlaceId || "").trim();
	const features: GeoJSON.Feature[] = [];
	for (const feature of places?.features || []) {
		if (feature.geometry?.type !== "Point") continue;
		const props = (feature.properties || {}) as {
			feature_type?: string;
			place_id?: string;
			name?: string;
			gap?: unknown;
			difference?: unknown;
			cheapest_provider_id?: unknown;
			product_name?: unknown;
		};
		if (props.feature_type === "cluster") continue;
		const placeId = String(props.place_id || "").trim();
		if (!placeId) continue;
		if (selected && placeId === selected) continue;
		const gap = pinGapAmount(props);
		const product = String(props.product_name || "").trim();
		features.push({
			type: "Feature",
			geometry: feature.geometry,
			properties: {
				place_id: placeId,
				name: String(props.name || ""),
				product_name: product,
				gap: gap != null ? Math.round(gap) : 0,
				icon: gpuIconId(cheapestProviderId(props)),
			},
		});
	}
	return { type: "FeatureCollection", features };
}

export function hashPriceTileCollection(
	data: GeoJSON.FeatureCollection | null | undefined,
): string {
	const parts: string[] = [];
	for (const feature of data?.features || []) {
		if (feature.geometry?.type !== "Point") continue;
		const [lng, lat] = feature.geometry.coordinates as [number, number];
		const props = (feature.properties || {}) as {
			place_id?: string;
			gap?: unknown;
			icon?: string;
			product_name?: string;
		};
		parts.push(
			`${props.place_id || ""}|${props.gap ?? 0}|${props.icon || ""}|${props.product_name || ""}|${lng}|${lat}`,
		);
	}
	parts.sort();
	return `${parts.length}:${parts.join(";")}`;
}

function roundedIconImageData(
	img: CanvasImageSource | null,
	size = GPU_ICON_PX * 2,
): ImageData {
	const canvas = document.createElement("canvas");
	canvas.width = size;
	canvas.height = size;
	const ctx = canvas.getContext("2d");
	if (!ctx) return new ImageData(size, size);
	ctx.beginPath();
	ctx.arc(size / 2, size / 2, size / 2 - 2, 0, Math.PI * 2);
	ctx.closePath();
	ctx.clip();
	ctx.fillStyle = "#FFFFFF";
	ctx.fillRect(0, 0, size, size);
	if (img) {
		const pad = 4;
		ctx.drawImage(img, pad, pad, size - pad * 2, size - pad * 2);
	} else {
		ctx.fillStyle = FARQ_MINT;
		ctx.fillRect(0, 0, size, size);
	}
	return ctx.getImageData(0, 0, size, size);
}

function loadMapImage(
	map: MapboxMap,
	url: string,
): Promise<HTMLImageElement | ImageBitmap | null> {
	return new Promise((resolve) => {
		map.loadImage(url, (err, image) => {
			if (err || !image || !("width" in image) || image instanceof ImageData) {
				resolve(null);
				return;
			}
			resolve(image);
		});
	});
}

export async function preloadPlatformAtlas(map: MapboxMap): Promise<void> {
	if (typeof document === "undefined") return;
	if (!map.hasImage(GPU_ICON_FALLBACK)) {
		map.addImage(GPU_ICON_FALLBACK, roundedIconImageData(null), { pixelRatio: 2 });
	}
	await Promise.all(
		ALL_PLATFORM_KEYS.map(async (key) => {
			const id = gpuIconId(key);
			if (map.hasImage(id)) return;
			const img = await loadMapImage(map, PLATFORM_LOGOS[key].src);
			if (!map.hasImage(id)) {
				map.addImage(id, roundedIconImageData(img), { pixelRatio: 2 });
			}
		}),
	);
}

function pickPlaceFromEvent(
	map: MapboxMap,
	ev: MapLayerMouseEvent,
	layers: string[],
): string {
	const hit = map.queryRenderedFeatures(ev.point, { layers });
	return String(hit[0]?.properties?.place_id || "").trim();
}

export function ensurePriceTileLayers(
	map: MapboxMap,
	onSelectPlace: (placeId: string) => void,
): void {
	if (map.getSource(PRICE_TILE_SOURCE)) {
		void preloadPlatformAtlas(map);
		return;
	}
	map.addSource(PRICE_TILE_SOURCE, {
		type: "geojson",
		data: { type: "FeatureCollection", features: [] },
		cluster: false,
	});
	map.addLayer({
		id: PRICE_TILE_CLUSTER_HALO,
		type: "circle",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["has", "point_count"],
		paint: {
			"circle-emissive-strength": 1,
			"circle-color": PRICE_CIRCLE_HALO,
			"circle-radius": ["step", ["get", "point_count"], 22, 8, 26, 24, 30],
			"circle-opacity": 0.42,
			"circle-blur": 0,
		},
	});
	map.addLayer({
		id: PRICE_TILE_CLUSTERS,
		type: "circle",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["has", "point_count"],
		paint: {
			"circle-emissive-strength": 1,
			"circle-color": PRICE_CIRCLE_FILL,
			"circle-stroke-color": PRICE_CIRCLE_STROKE,
			"circle-stroke-width": 2,
			"circle-radius": [
				"step",
				["get", "point_count"],
				GPU_CLUSTER_RADIUS,
				8,
				20,
				24,
				22,
			],
			"circle-opacity": 1,
		},
	});
	map.addLayer({
		id: PRICE_TILE_CLUSTER_COUNT,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["has", "point_count"],
		layout: {
			"text-field": ["to-string", ["round", ["coalesce", ["get", "max_gap"], 0]]],
			"text-size": GPU_CLUSTER_TEXT_SIZE,
			"text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"],
			"text-allow-overlap": true,
			"text-ignore-placement": true,
		},
		paint: {
			"text-emissive-strength": 1,
			"text-color": PRICE_CIRCLE_TEXT,
			"text-halo-color": PRICE_CIRCLE_STROKE,
			"text-halo-width": 1,
		},
	});
	map.addLayer({
		id: PRICE_TILE_HALO,
		type: "circle",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["!", ["has", "point_count"]],
		paint: {
			"circle-emissive-strength": 1,
			"circle-color": PRICE_CIRCLE_HALO,
			"circle-radius": [
				"interpolate",
				["linear"],
				["coalesce", ["get", "gap"], 0],
				8,
				FAR_BEACON_RADIUS + 3,
				50,
				FAR_BEACON_RADIUS + 8,
			],
			"circle-opacity": 0.4,
			"circle-blur": 0,
		},
	});
	map.addLayer({
		id: PRICE_TILE_CIRCLES,
		type: "circle",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["!", ["has", "point_count"]],
		paint: {
			"circle-emissive-strength": 1,
			"circle-color": PRICE_CIRCLE_FILL,
			"circle-stroke-color": PRICE_CIRCLE_STROKE,
			"circle-stroke-width": 2,
			"circle-radius": [
				"interpolate",
				["linear"],
				["coalesce", ["get", "gap"], 0],
				8,
				FAR_BEACON_RADIUS,
				50,
				FAR_BEACON_RADIUS + 5,
			],
			"circle-opacity": 1,
		},
	});
	map.addLayer({
		id: PRICE_TILE_LABELS,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["!", ["has", "point_count"]],
		layout: {
			"text-field": ["to-string", ["get", "gap"]],
			"text-size": FAR_BEACON_TEXT_SIZE,
			"text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"],
			"text-allow-overlap": true,
			"text-ignore-placement": true,
		},
		paint: {
			"text-emissive-strength": 1,
			"text-color": PRICE_CIRCLE_TEXT,
			"text-halo-color": PRICE_CIRCLE_STROKE,
			"text-halo-width": 1,
		},
	});
	map.addLayer({
		id: PRICE_TILE_ICONS,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		minzoom: CLUSTER_BREAK_ZOOM,
		filter: ["!", ["has", "point_count"]],
		paint: { "icon-emissive-strength": 1 },
		layout: {
			"icon-image": ["coalesce", ["get", "icon"], GPU_ICON_FALLBACK],
			"icon-size": 1,
			"icon-anchor": "bottom",
			"icon-allow-overlap": true,
			"icon-ignore-placement": true,
			"icon-padding": 0,
		},
	});
	map.addLayer({
		id: PRICE_TILE_NEAR_TEXT,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		minzoom: CLUSTER_BREAK_ZOOM,
		filter: ["!", ["has", "point_count"]],
		layout: {
			"text-field": [
				"case",
				[">", ["length", ["coalesce", ["get", "product_name"], ""]], 0],
				[
					"concat",
					["get", "product_name"],
					"\n",
					["to-string", ["get", "gap"]],
					" ر.س فرق",
				],
				[
					"concat",
					["to-string", ["get", "gap"]],
					" ر.س فرق",
				],
			],
			"text-size": 12,
			"text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"],
			"text-anchor": "top",
			"text-offset": [0, 0.35],
			"text-line-height": 1.15,
			"text-max-width": 9,
			"text-allow-overlap": true,
			"text-ignore-placement": true,
		},
		paint: {
			"text-emissive-strength": 1,
			"text-color": PRICE_CIRCLE_TEXT,
			"text-halo-color": PRICE_CIRCLE_STROKE,
			"text-halo-width": 1.2,
		},
	});
	map.addLayer({
		id: PRICE_TILE_CHIPS,
		type: "circle",
		source: PRICE_TILE_SOURCE,
		minzoom: CLUSTER_BREAK_ZOOM,
		filter: ["all", ["!", ["has", "point_count"]], [">", ["get", "gap"], 0]],
		paint: {
			"circle-emissive-strength": 1,
			"circle-color": PRICE_CIRCLE_FILL,
			"circle-stroke-color": PRICE_CIRCLE_STROKE,
			"circle-stroke-width": 2,
			"circle-radius": GPU_CHIP_RADIUS,
			"circle-opacity": 1,
			"circle-blur": 0,
			"circle-translate": [18, -36],
			"circle-translate-anchor": "viewport",
		},
	});
	map.addLayer({
		id: PRICE_TILE_CHIP_LABELS,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		minzoom: CLUSTER_BREAK_ZOOM,
		filter: ["all", ["!", ["has", "point_count"]], [">", ["get", "gap"], 0]],
		layout: {
			"text-field": ["to-string", ["get", "gap"]],
			"text-size": GPU_CHIP_TEXT_SIZE,
			"text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"],
			"text-allow-overlap": true,
			"text-ignore-placement": true,
			"icon-allow-overlap": true,
			"text-anchor": "center",
		},
		paint: {
			"text-emissive-strength": 1,
			"text-color": PRICE_CIRCLE_TEXT,
			"text-halo-color": PRICE_CIRCLE_STROKE,
			"text-halo-width": 1,
			"text-translate": [18, -36],
			"text-translate-anchor": "viewport",
		},
	});

	const pickLayers = [
		PRICE_TILE_CIRCLES,
		PRICE_TILE_LABELS,
		PRICE_TILE_ICONS,
		PRICE_TILE_NEAR_TEXT,
		PRICE_TILE_CHIPS,
		PRICE_TILE_CHIP_LABELS,
	];
	const pickPlace = (ev: MapLayerMouseEvent) => {
		const id = pickPlaceFromEvent(map, ev, pickLayers);
		if (id) onSelectPlace(id);
	};
	for (const id of pickLayers) {
		map.on("click", id, pickPlace);
	}
	map.on("click", PRICE_TILE_CLUSTERS, (ev: MapLayerMouseEvent) => {
		const hit = map.queryRenderedFeatures(ev.point, {
			layers: [PRICE_TILE_CLUSTERS],
		});
		const clusterId = hit[0]?.properties?.cluster_id;
		const src = map.getSource(PRICE_TILE_SOURCE) as GeoJSONSource | undefined;
		if (clusterId == null || !src || !("getClusterExpansionZoom" in src)) {
			return;
		}
		src.getClusterExpansionZoom(Number(clusterId), (err, zoom) => {
			if (err || zoom == null) return;
			map.easeTo({
				center: ev.lngLat,
				zoom,
				duration: 700,
			});
		});
	});
	const hoverLayers = [
		PRICE_TILE_CIRCLES,
		PRICE_TILE_LABELS,
		PRICE_TILE_CLUSTERS,
		PRICE_TILE_ICONS,
		PRICE_TILE_NEAR_TEXT,
		PRICE_TILE_CHIPS,
	];
	for (const id of hoverLayers) {
		map.on("mouseenter", id, () => {
			map.getCanvas().style.cursor = "pointer";
		});
		map.on("mouseleave", id, () => {
			map.getCanvas().style.cursor = "";
		});
	}
	void preloadPlatformAtlas(map);
}

export function syncPriceTileData(
	map: MapboxMap,
	places: GeoJSON.FeatureCollection | null | undefined,
	_zoom?: number,
	selectedPlaceId?: string,
): void {
	const src = map.getSource(PRICE_TILE_SOURCE) as GeoJSONSource | undefined;
	if (!src || !("setData" in src)) return;
	const collection = toPriceTileCollection(places, selectedPlaceId);
	const hash = hashPriceTileCollection(collection);
	if (lastTileHash.get(map) === hash) return;
	lastTileHash.set(map, hash);
	src.setData(collection);
}

export function resetPriceTileHash(map?: MapboxMap): void {
	if (map) lastTileHash.delete(map);
}
