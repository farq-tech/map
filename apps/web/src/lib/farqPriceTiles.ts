/**
 * GPU opportunity layers — one entity that changes resolution with zoom.
 *
 * FAR / AREA (z < CLUSTER_BREAK_ZOOM): Mapbox clusters the city's opportunities
 * in a worker. A cluster is a mint disc carrying the biggest gap inside it and
 * how many opportunities it stands for; a lone opportunity is a mint disc
 * sized by its approved tier, carrying its gap. Collision is on and the
 * biggest gap wins the pixel, so density never turns into noise.
 *
 * NEAR (z ≥ CLUSTER_BREAK_ZOOM): the cheapest app's logo with one label under
 * it — the gap on a mint pill, then the item name — so a label never outlives
 * its logo. Faint gaps (< 5 SAR) show the logo and item without a number.
 *
 * The selected place is excluded from the GPU source and drawn once as HTML.
 * No emoji in any text-field (Mapbox glyphs stop at U+FFFF). Every layer is
 * emissive so Standard's dusk/night presets cannot darken the opportunity
 * colour. Digits are Western on every locale (approved 2026-08-20).
 */
import type {
	ExpressionSpecification,
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
import { tierForGap, type OpportunityTier } from "./farqOpportunityTiers";
import {
	ALL_PLATFORM_KEYS,
	normalizePlatformKey,
	PLATFORM_LOGOS,
	type PlatformKey,
} from "./platformLogos";

export const PRICE_TILE_SOURCE = "farq-price-tiles";
export const PRICE_TILE_POINTS = "farq-price-points";
export const PRICE_TILE_CLUSTERS = "farq-price-clusters";
export const PRICE_TILE_ICONS = "farq-price-icons";

/** Mint disc, dark Farq teal number — never white on mint. */
export const PRICE_CIRCLE_FILL = FARQ_MINT;
export const PRICE_CIRCLE_STROKE = "#FFFFFF";
export const PRICE_CIRCLE_TEXT = FARQ_BRAND_900;

export const GPU_ICON_PREFIX = "farq-icon-";
export const GPU_ICON_FALLBACK = "farq-icon-fallback";
export const GPU_ICON_PX = 40;
export const GPU_DISC_PREFIX = "farq-disc-";

/** Disc diameters per approved tier (CSS px). Hero is a top-decile gap. */
export const DISC_PX: Record<OpportunityTier, number> = {
	hero: 38,
	strong: 30,
	regular: 24,
	faint: 14,
};
export const DISC_TEXT_PX: Record<OpportunityTier, number> = {
	hero: 15,
	strong: 13,
	regular: 12,
	faint: 0,
};
export const CLUSTER_DISC_PX = { sm: 40, md: 48, lg: 56 } as const;
export const CLUSTER_STEP_MD = 12;
export const CLUSTER_STEP_LG = 40;
export const CLUSTER_MAX_ZOOM = CLUSTER_BREAK_ZOOM - 1;
export const CLUSTER_RADIUS_PX = 64;
/** A thumb needs more room than a cursor: on coarse pointers clusters merge sooner. */
export const CLUSTER_RADIUS_COARSE_PX = 84;
export function clusterRadiusPx(): number {
	return typeof window !== "undefined" && window.matchMedia?.("(pointer: coarse)").matches
		? CLUSTER_RADIUS_COARSE_PX
		: CLUSTER_RADIUS_PX;
}

/* Kept for callers/tests that describe the far band in these terms. */
export const FAR_BEACON_PX = DISC_PX.hero;
export const FAR_BEACON_RADIUS = FAR_BEACON_PX / 2;
export const FAR_BEACON_TEXT_SIZE = DISC_TEXT_PX.hero;
export const GPU_CLUSTER_TEXT_SIZE = 15;
/** Near-band gap pill: text on a mint halo at the logo's corner. */
export const GPU_CHIP_PX = 24;
export const GPU_CHIP_RADIUS = GPU_CHIP_PX / 2;
export const GPU_CHIP_TEXT_SIZE = 13;

const TEXT_FONT = ["DIN Pro Bold", "Arial Unicode MS Bold"];

const lastTileHash = new WeakMap<MapboxMap, string>();

export function gpuIconId(key: PlatformKey | string | null | undefined): string {
	const normalized = normalizePlatformKey(key);
	return normalized ? `${GPU_ICON_PREFIX}${normalized}` : GPU_ICON_FALLBACK;
}

export function discImageId(tier: OpportunityTier | null | undefined): string {
	return `${GPU_DISC_PREFIX}${tier || "faint"}`;
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

/** Mapbox glyphs stop at U+FFFF: strip emoji and other astral characters from label text. */
export function mapSafeText(raw: unknown): string {
	return String(raw || "")
		.replace(/[\u{10000}-\u{10FFFF}]/gu, "")
		.replace(/\s+/g, " ")
		.trim();
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
			tier?: unknown;
			difference?: unknown;
			cheapest_provider_id?: unknown;
			product_name?: unknown;
		};
		if (props.feature_type === "cluster") continue;
		const placeId = String(props.place_id || "").trim();
		if (!placeId) continue;
		if (selected && placeId === selected) continue;
		const gap = pinGapAmount(props);
		const tier =
			(typeof props.tier === "string" ? (props.tier as OpportunityTier) : null) ||
			tierForGap(gap);
		const product = mapSafeText(props.product_name);
		features.push({
			type: "Feature",
			id: Number.isFinite(Number(placeId)) ? Number(placeId) : undefined,
			geometry: feature.geometry,
			properties: {
				place_id: placeId,
				name: String(props.name || ""),
				product_name: product,
				gap: gap != null ? Math.round(gap) : 0,
				tier: tier || "faint",
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
			tier?: string;
			icon?: string;
			product_name?: string;
		};
		parts.push(
			`${props.place_id || ""}|${props.gap ?? 0}|${props.tier || ""}|${props.icon || ""}|${props.product_name || ""}|${lng}|${lat}`,
		);
	}
	parts.sort();
	return `${parts.length}:${parts.join(";")}`;
}

/* ---------- images: provider logos and tier discs, drawn once ---------- */

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

/** Mint disc with a white ring; a faint inner teal line keeps it legible on mint-ish ground. */
export function discImageData(cssPx: number): ImageData {
	const size = cssPx * 2;
	const canvas = document.createElement("canvas");
	canvas.width = size;
	canvas.height = size;
	const ctx = canvas.getContext("2d");
	if (!ctx) return new ImageData(size, size);
	const c = size / 2;
	ctx.beginPath();
	ctx.arc(c, c, c - 1, 0, Math.PI * 2);
	ctx.fillStyle = PRICE_CIRCLE_STROKE;
	ctx.fill();
	ctx.beginPath();
	ctx.arc(c, c, c - 5, 0, Math.PI * 2);
	ctx.fillStyle = PRICE_CIRCLE_FILL;
	ctx.fill();
	ctx.beginPath();
	ctx.arc(c, c, c - 5, 0, Math.PI * 2);
	ctx.lineWidth = 1.5;
	ctx.strokeStyle = "rgba(4, 52, 52, 0.28)";
	ctx.stroke();
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

export function ensureDiscImages(map: MapboxMap): void {
	if (typeof document === "undefined") return;
	const add = (id: string, px: number) => {
		if (!map.hasImage(id)) map.addImage(id, discImageData(px), { pixelRatio: 2 });
	};
	for (const tier of Object.keys(DISC_PX) as OpportunityTier[]) {
		add(discImageId(tier), DISC_PX[tier]);
	}
	add(`${GPU_DISC_PREFIX}cluster-sm`, CLUSTER_DISC_PX.sm);
	add(`${GPU_DISC_PREFIX}cluster-md`, CLUSTER_DISC_PX.md);
	add(`${GPU_DISC_PREFIX}cluster-lg`, CLUSTER_DISC_PX.lg);
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

/* ---------- layers ---------- */

function pickPlaceFromEvent(
	map: MapboxMap,
	ev: MapLayerMouseEvent,
	layers: string[],
): string {
	const hit = map.queryRenderedFeatures(ev.point, { layers });
	return String(hit[0]?.properties?.place_id || "").trim();
}

const TIER_EXPR: ExpressionSpecification = ["coalesce", ["get", "tier"], "faint"];
const GAP_EXPR: ExpressionSpecification = ["coalesce", ["get", "gap"], 0];
/** Biggest gap first: lower sort keys are placed first, so negate the gap. */
const SORT_BY_GAP: ExpressionSpecification = ["-", 0, GAP_EXPR];

export function ensurePriceTileLayers(
	map: MapboxMap,
	onSelectPlace: (placeId: string) => void,
): void {
	if (map.getSource(PRICE_TILE_SOURCE)) {
		ensureDiscImages(map);
		void preloadPlatformAtlas(map);
		return;
	}
	ensureDiscImages(map);
	map.addSource(PRICE_TILE_SOURCE, {
		type: "geojson",
		data: { type: "FeatureCollection", features: [] },
		cluster: true,
		clusterMaxZoom: CLUSTER_MAX_ZOOM,
		clusterRadius: clusterRadiusPx(),
		clusterProperties: {
			/* the biggest observed gap inside the cluster — never a sum, never invented */
			max_gap: ["max", GAP_EXPR],
		},
	});

	/* AREA: clusters as discs carrying the biggest gap and the count. */
	map.addLayer({
		id: PRICE_TILE_CLUSTERS,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["has", "point_count"],
		layout: {
			"icon-image": [
				"step",
				["get", "point_count"],
				`${GPU_DISC_PREFIX}cluster-sm`,
				CLUSTER_STEP_MD,
				`${GPU_DISC_PREFIX}cluster-md`,
				CLUSTER_STEP_LG,
				`${GPU_DISC_PREFIX}cluster-lg`,
			],
			"icon-allow-overlap": true,
			"icon-ignore-placement": true,
			"text-field": [
				"format",
				["to-string", ["round", ["get", "max_gap"]]],
				{ "font-scale": 1 },
				"\n",
				{},
				["to-string", ["get", "point_count"]],
				{ "font-scale": 0.68 },
			],
			"text-font": TEXT_FONT,
			"text-size": GPU_CLUSTER_TEXT_SIZE,
			"text-line-height": 1.05,
			"text-allow-overlap": true,
			"text-ignore-placement": true,
			"symbol-sort-key": ["-", 0, ["coalesce", ["get", "max_gap"], 0]],
		},
		paint: {
			"text-color": PRICE_CIRCLE_TEXT,
			"text-emissive-strength": 1,
			"icon-emissive-strength": 1,
		},
	});

	/* AREA: lone opportunities as tiered discs; collision on, biggest gap wins. */
	map.addLayer({
		id: PRICE_TILE_POINTS,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		maxzoom: CLUSTER_BREAK_ZOOM,
		filter: ["!", ["has", "point_count"]],
		layout: {
			"icon-image": ["concat", GPU_DISC_PREFIX, TIER_EXPR],
			"icon-allow-overlap": false,
			"icon-ignore-placement": false,
			"icon-padding": 1,
			"text-field": [
				"case",
				["==", TIER_EXPR, "faint"],
				"",
				["to-string", ["get", "gap"]],
			],
			"text-font": TEXT_FONT,
			"text-size": [
				"match",
				TIER_EXPR,
				"hero",
				DISC_TEXT_PX.hero,
				"strong",
				DISC_TEXT_PX.strong,
				"regular",
				DISC_TEXT_PX.regular,
				10,
			],
			"text-allow-overlap": false,
			"text-ignore-placement": false,
			"symbol-sort-key": SORT_BY_GAP,
		},
		paint: {
			"text-color": PRICE_CIRCLE_TEXT,
			"text-emissive-strength": 1,
			"icon-emissive-strength": 1,
		},
	});

	/* NEAR: the cheapest app's logo, and under it one label — the gap on a mint
	 * pill, then the item. One symbol per place, so a label never outlives its logo. */
	map.addLayer({
		id: PRICE_TILE_ICONS,
		type: "symbol",
		source: PRICE_TILE_SOURCE,
		minzoom: CLUSTER_BREAK_ZOOM,
		filter: ["!", ["has", "point_count"]],
		layout: {
			"icon-image": ["coalesce", ["get", "icon"], GPU_ICON_FALLBACK],
			"icon-size": 1,
			"icon-anchor": "bottom",
			"icon-allow-overlap": false,
			"icon-ignore-placement": false,
			"icon-padding": 2,
			"text-field": [
				"case",
				["==", TIER_EXPR, "faint"],
				["get", "product_name"],
				[
					"format",
					["to-string", ["get", "gap"]],
					{ "font-scale": 1.15 },
					["case", [">", ["length", ["get", "product_name"]], 0], "\n", ""],
					{},
					["get", "product_name"],
					{ "font-scale": 0.86 },
				],
			],
			"text-font": TEXT_FONT,
			"text-size": GPU_CHIP_TEXT_SIZE,
			"text-anchor": "top",
			"text-offset": [0, 0.35],
			"text-max-width": 9,
			"text-line-height": 1.15,
			"text-allow-overlap": false,
			"text-ignore-placement": false,
			"text-optional": true,
			"symbol-sort-key": SORT_BY_GAP,
		},
		paint: {
			"text-color": PRICE_CIRCLE_TEXT,
			"text-halo-color": PRICE_CIRCLE_FILL,
			"text-halo-width": 2.2,
			"text-halo-blur": 0,
			"text-emissive-strength": 1,
			"icon-emissive-strength": 1,
		},
	});

	const pickLayers = [PRICE_TILE_POINTS, PRICE_TILE_ICONS];
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
				zoom: Math.min(zoom, CLUSTER_BREAK_ZOOM + 0.5),
				duration: 650,
			});
		});
	});
	for (const id of [...pickLayers, PRICE_TILE_CLUSTERS]) {
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
