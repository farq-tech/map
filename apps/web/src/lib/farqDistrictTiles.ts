/**
 * The district field — the city in the geography people already use.
 *
 * Below DISTRICT_FILL_MAX_ZOOM every حي is tinted by how many opportunities
 * fall inside it (geometric membership decided on the server, never by name)
 * and the busiest few carry their name and biggest gap. The fill fades out as
 * the clusters fade in — one entity changing resolution, like the H3 field it
 * replaces when a city has boundaries. A faint boundary line stays a little
 * longer for orientation and is gone before the pins own the picture.
 *
 * The selected حي keeps its outline at every zoom: it is the thing being
 * looked at, so its border survives all the way in while the others get out
 * of the way. Nothing here invents a boundary, a count or a name.
 */
import type {
	ExpressionSpecification,
	GeoJSONSource,
	Map as MapboxMap,
	MapMouseEvent,
} from "mapbox-gl";
import { FARQ_BRAND_900, FARQ_MINT } from "./farqBrandAssets";
import { PROVIDER_MAP_COLOR, PROVIDER_MAP_COLOR_TOO_CLOSE } from "./platformLogos";
import type { CityDistricts } from "../services/intelligenceService";

/**
 * What the district colour means.
 *   'gap' — how many observed opportunities the حي holds (the default).
 *   'app' — which app was cheapest most often there, drawn only where the
 *           sample is large enough for the server to name one at all.
 */
export type DistrictLens = "gap" | "app";

export const DISTRICT_SOURCE = "farq-districts";
/** Labels are points, one per حي, so a multi-part district speaks once. */
export const DISTRICT_LABEL_SOURCE = "farq-district-label-points";
export const DISTRICT_FILL = "farq-district-fill";
export const DISTRICT_HOVER_FILL = "farq-district-hover-fill";
export const DISTRICT_HOVER_LINE = "farq-district-hover-line";
export const DISTRICT_LINE = "farq-district-line";
export const DISTRICT_LABELS = "farq-district-labels";
export const DISTRICT_SELECTED_FILL = "farq-district-selected-fill";
export const DISTRICT_SELECTED_LINE = "farq-district-selected-line";

/**
 * The handover contract for the whole city zoom, and the only copy of it: the
 * field fades out as Mapbox's clusters fade in, so one picture changes
 * resolution instead of two layers trading places.
 */
export const DISTRICT_FILL_MAX_ZOOM = 11.5;
export const DISTRICT_FADE_START = 10.6;
/** Clusters appear here, inside the fade, so one picture hands over to the next. */
export const DISTRICT_HANDOVER_ZOOM = 10.9;
/** Boundary lines persist for orientation through the cluster band, never into the pins. */
export const DISTRICT_LINE_MIN_ZOOM = 9;
export const DISTRICT_LINE_MAX_ZOOM = 14.5;

/**
 * How strongly a حي is tinted by how many observed opportunities it holds.
 * The legend draws these same steps, so the map and its explanation cannot drift.
 */
export const DISTRICT_FILL_STEPS: ReadonlyArray<{ min: number; opacity: number }> = [
	{ min: 1, opacity: 0.12 },
	{ min: 10, opacity: 0.22 },
	{ min: 40, opacity: 0.34 },
	{ min: 120, opacity: 0.46 },
];

const COUNT: ExpressionSpecification = ["coalesce", ["get", "opportunities"], 0];
const NO_MATCH: ExpressionSpecification = ["==", ["get", "district_id"], "__none__"];
const HOVERED: ExpressionSpecification = ["boolean", ["feature-state", "hover"], false];
const FILL_BY_COUNT: ExpressionSpecification = [
	"step",
	COUNT,
	0,
	...DISTRICT_FILL_STEPS.flatMap((s) => [s.min, s.opacity]),
] as ExpressionSpecification;

/** A حي the server refused to call for an app is not painted for one. */
const HAS_VERDICT: ExpressionSpecification = [
	"all",
	["==", ["get", "enough_for_app_verdict"], true],
	["has", "cheapest_app"],
];

/** Enough comparisons, no clear leader — a different answer from "no data". */
const TOO_CLOSE: ExpressionSpecification = ["==", ["get", "app_verdict_too_close"], true];

/**
 * How far ahead the winner is, in points of share. The lead is what the reader
 * should feel: a 60-to-20 حي must not look like a 52-to-48 one.
 */
export const APP_MARGIN_STEPS: ReadonlyArray<{ min: number; opacity: number }> = [
	{ min: 0, opacity: 0.2 },
	{ min: 15, opacity: 0.3 },
	{ min: 30, opacity: 0.42 },
];

/** The soft grey a "too close to call" حي takes, so it is never bare ground. */
export const APP_TOO_CLOSE_OPACITY = 0.14;

const FILL_COLOR_BY_APP: ExpressionSpecification = [
	"case",
	TOO_CLOSE,
	PROVIDER_MAP_COLOR_TOO_CLOSE,
	[
		"match",
		["coalesce", ["get", "cheapest_app"], ""],
		...Object.entries(PROVIDER_MAP_COLOR).flatMap(([key, color]) => [key, color]),
		/* An app we have no colour for is still not "an opportunity" — grey, never mint. */
		PROVIDER_MAP_COLOR_TOO_CLOSE,
	],
] as ExpressionSpecification;

const APP_OPACITY_AT_FULL: ExpressionSpecification = [
	"case",
	HAS_VERDICT,
	[
		"step",
		["coalesce", ["get", "cheapest_app_margin"], 0],
		...[APP_MARGIN_STEPS[0].opacity],
		...APP_MARGIN_STEPS.slice(1).flatMap((s) => [s.min, s.opacity]),
	],
	TOO_CLOSE,
	APP_TOO_CLOSE_OPACITY,
	0,
] as ExpressionSpecification;

/**
 * The app lens outlives the count field. The map lands at z12.15, above the
 * count field's 11.5 handover, so a lens that stopped there answered nothing
 * at the zoom people actually arrive on — you toggled it and the map did not
 * change. "Which app wins around here" still means something at neighbourhood
 * scale, so it holds until the pins take over.
 */
export const APP_LENS_MAX_ZOOM = 13.6;

const FILL_OPACITY_BY_APP: ExpressionSpecification = [
	"interpolate",
	["linear"],
	["zoom"],
	DISTRICT_FADE_START,
	APP_OPACITY_AT_FULL,
	12.6,
	APP_OPACITY_AT_FULL,
	APP_LENS_MAX_ZOOM,
	0,
] as ExpressionSpecification;

function selectedFilter(id: string | null | undefined): ExpressionSpecification {
	const v = String(id || "").trim();
	return v ? ["==", ["get", "district_id"], v] : NO_MATCH;
}

/**
 * Name above, biggest gap below, with its unit — a bare "60" on a polygon reads
 * as a score or a rank, and this is riyals. The name is the identity of the
 * shape, so it is not shrunk below the number: at 0.82 of 13px it was 10.7px
 * Arabic, where dot clusters fuse and ظهرة البديعة stops being readable.
 * Digits stay Western on every locale (approved 2026-08-20).
 */
function labelField(isRTL: boolean): ExpressionSpecification {
	return [
		"format",
		["coalesce", ["get", isRTL ? "name_ar" : "name_en"], ""],
		{ "font-scale": 1, "text-font": ["literal", ["DIN Pro Medium", "Arial Unicode MS Regular"]] },
		"\n",
		{},
		["concat", ["to-string", ["coalesce", ["get", "max_gap"], ""]], isRTL ? " ر.س" : " SAR"],
		{ "font-scale": 1.05 },
	];
}

function beforeLayer(map: MapboxMap): string | undefined {
	/* Under every symbol we draw, over the basemap. */
	if (map.getLayer("farq-price-clusters")) return "farq-price-clusters";
	return undefined;
}

/** Repaint the field for the chosen lens without touching the source or the camera. */
export function setDistrictLens(map: MapboxMap, lens: DistrictLens): void {
	if (!map.getLayer(DISTRICT_FILL)) return;
	const app = lens === "app";
	/* The two lenses live to different zooms; the layer's range follows the lens. */
	map.setLayerZoomRange(DISTRICT_FILL, 0, app ? APP_LENS_MAX_ZOOM : DISTRICT_FILL_MAX_ZOOM);
	for (const id of [DISTRICT_HOVER_FILL, DISTRICT_HOVER_LINE]) {
		if (map.getLayer(id)) {
			map.setLayerZoomRange(id, 0, app ? APP_LENS_MAX_ZOOM : DISTRICT_FILL_MAX_ZOOM);
		}
	}
	map.setPaintProperty(DISTRICT_FILL, "fill-color", app ? FILL_COLOR_BY_APP : FARQ_MINT);
	map.setPaintProperty(
		DISTRICT_FILL,
		"fill-opacity",
		app
			? FILL_OPACITY_BY_APP
			: ([
					"interpolate",
					["linear"],
					["zoom"],
					DISTRICT_FADE_START,
					FILL_BY_COUNT,
					DISTRICT_FILL_MAX_ZOOM,
					0,
				] as ExpressionSpecification),
	);
}

export function ensureDistrictLayers(
	map: MapboxMap,
	opts: { isRTL: boolean; selectedId?: string | null; lens?: DistrictLens },
): void {
	if (map.getSource(DISTRICT_SOURCE)) return;
	map.addSource(DISTRICT_SOURCE, {
		type: "geojson",
		data: { type: "FeatureCollection", features: [] },
		promoteId: "district_id",
	});
	map.addSource(DISTRICT_LABEL_SOURCE, {
		type: "geojson",
		data: { type: "FeatureCollection", features: [] },
	});
	const before = beforeLayer(map);
	map.addLayer(
		{
			id: DISTRICT_FILL,
			type: "fill",
			source: DISTRICT_SOURCE,
			maxzoom: DISTRICT_FILL_MAX_ZOOM,
			paint: {
				"fill-color": FARQ_MINT,
				"fill-emissive-strength": 1,
				/* opacity by count, the whole field fading as clusters arrive
				 * (zoom must be the top-level interpolate input, counts are its outputs) */
				"fill-opacity": [
					"interpolate",
					["linear"],
					["zoom"],
					DISTRICT_FADE_START,
					FILL_BY_COUNT,
					DISTRICT_FILL_MAX_ZOOM,
					0,
				],
				"fill-antialias": false,
			},
		},
		before,
	);
	/* The حي under the pointer lifts a little and gets an edge — a cursor can see where a tap would land. */
	map.addLayer(
		{
			id: DISTRICT_HOVER_FILL,
			type: "fill",
			source: DISTRICT_SOURCE,
			maxzoom: DISTRICT_FILL_MAX_ZOOM,
			paint: {
				"fill-color": FARQ_MINT,
				"fill-emissive-strength": 1,
				"fill-opacity": ["case", HOVERED, 0.2, 0],
				"fill-antialias": false,
			},
		},
		before,
	);
	map.addLayer(
		{
			id: DISTRICT_HOVER_LINE,
			type: "line",
			source: DISTRICT_SOURCE,
			maxzoom: DISTRICT_FILL_MAX_ZOOM,
			layout: { "line-join": "round" },
			paint: {
				"line-color": FARQ_BRAND_900,
				"line-emissive-strength": 1,
				"line-width": 1.6,
				"line-opacity": ["case", HOVERED, 0.85, 0],
			},
		},
		before,
	);
	if (opts.lens === "app") setDistrictLens(map, "app");
	map.addLayer(
		{
			id: DISTRICT_LINE,
			type: "line",
			source: DISTRICT_SOURCE,
			minzoom: DISTRICT_LINE_MIN_ZOOM,
			maxzoom: DISTRICT_LINE_MAX_ZOOM,
			layout: { "line-join": "round" },
			paint: {
				/* Near-black at 0.26 over a dark basemap was invisible at every zoom I
				 * could find it at. The أحياء are the point of this field, so their
				 * edges are drawn light — the basemap is dark, so light reads. */
				"line-color": "#E8F3F1",
				"line-emissive-strength": 1,
				"line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.5, 13, 1.1],
				"line-opacity": ["interpolate", ["linear"], ["zoom"], 9, 0.22, 12, 0.34, DISTRICT_LINE_MAX_ZOOM, 0],
			},
		},
		before,
	);
	/**
	 * Selection is a casing, not a colour. A mint wash over the count tint used
	 * to push a حي up a whole step of the scale — selecting a 0-opportunity حي
	 * painted it exactly like a حي with one — so the selected shape now carries
	 * a white casing under a dark rule instead, which reads on any ground and
	 * on either lens without touching the value underneath.
	 */
	map.addLayer(
		{
			id: DISTRICT_SELECTED_FILL,
			type: "line",
			source: DISTRICT_SOURCE,
			filter: selectedFilter(opts.selectedId),
			layout: { "line-join": "round", "line-cap": "round" },
			paint: {
				"line-color": "#FFFFFF",
				"line-emissive-strength": 1,
				"line-width": ["interpolate", ["linear"], ["zoom"], 9, 4, 13, 6, 16, 8],
				"line-opacity": 0.55,
				"line-blur": 1.5,
			},
		},
		before,
	);
	map.addLayer(
		{
			id: DISTRICT_SELECTED_LINE,
			type: "line",
			source: DISTRICT_SOURCE,
			filter: selectedFilter(opts.selectedId),
			layout: { "line-join": "round", "line-cap": "round" },
			paint: {
				"line-color": FARQ_BRAND_900,
				"line-emissive-strength": 1,
				"line-width": ["interpolate", ["linear"], ["zoom"], 9, 1.6, 13, 2.4, 16, 3.2],
				"line-opacity": 0.9,
			},
		},
		before,
	);
	map.addLayer(
		{
			id: DISTRICT_LABELS,
			type: "symbol",
			source: DISTRICT_LABEL_SOURCE,
			maxzoom: DISTRICT_FILL_MAX_ZOOM,
			layout: {
				"text-field": labelField(opts.isRTL),
				"text-font": ["DIN Pro Bold", "Arial Unicode MS Bold"],
				"text-size": 13,
				"text-line-height": 1.15,
				"text-allow-overlap": false,
				"text-padding": 6,
				"symbol-sort-key": ["-", 0, COUNT],
			},
			paint: {
				"text-color": FARQ_BRAND_900,
				"text-halo-color": "#FFFFFF",
				"text-halo-width": 1.6,
				"text-emissive-strength": 1,
				"text-opacity": ["interpolate", ["linear"], ["zoom"], DISTRICT_FADE_START, 1, DISTRICT_FILL_MAX_ZOOM, 0],
			},
		},
		before,
	);
}

/** Every حي that has something to say, biggest gap first. Mapbox culls the rest. */
function labelCandidates(districts: CityDistricts): CityDistricts["features"] {
	return [...districts.features]
		.filter(
			(f) =>
				f.properties.opportunities > 0 &&
				(f.properties.max_gap || 0) > 0 &&
				Array.isArray(f.properties.label_point),
		)
		.sort(
			(a, b) =>
				(b.properties.max_gap || 0) - (a.properties.max_gap || 0) ||
				b.properties.opportunities - a.properties.opportunities ||
				a.properties.district_id.localeCompare(b.properties.district_id),
		);
}

/** Every حي is drawn, with everything both lenses need to paint it. */
export function toDistrictCollection(
	districts: CityDistricts | null | undefined,
): GeoJSON.FeatureCollection {
	if (!districts) return { type: "FeatureCollection", features: [] };
	return {
		type: "FeatureCollection",
		features: districts.features.map((f) => ({
			type: "Feature",
			id: f.properties.district_id,
			geometry: f.geometry,
			properties: {
				district_id: f.properties.district_id,
				name_ar: f.properties.name_ar,
				name_en: f.properties.name_en,
				opportunities: f.properties.opportunities,
				max_gap: f.properties.max_gap,
				/* Carried so the app lens can paint without a second source; the
				 * server decides whether a verdict exists, never the map. */
				cheapest_app: f.properties.cheapest_app,
				enough_for_app_verdict: f.properties.enough_for_app_verdict,
				app_verdict_too_close: f.properties.app_verdict_too_close,
				cheapest_app_margin: f.properties.cheapest_app_margin,
				cheapest_app_share: f.properties.cheapest_app_share,
				comparisons: f.properties.comparisons,
			},
		})),
	};
}

/** One point per حي, at the server's label point inside its largest part. */
export function toDistrictLabelCollection(
	districts: CityDistricts | null | undefined,
): GeoJSON.FeatureCollection {
	if (!districts) return { type: "FeatureCollection", features: [] };
	return {
		type: "FeatureCollection",
		features: labelCandidates(districts).map((f) => ({
			type: "Feature",
			id: f.properties.district_id,
			geometry: { type: "Point", coordinates: f.properties.label_point as [number, number] },
			properties: {
				district_id: f.properties.district_id,
				name_ar: f.properties.name_ar,
				name_en: f.properties.name_en,
				opportunities: f.properties.opportunities,
				max_gap: f.properties.max_gap,
			},
		})),
	};
}

export function syncDistrictData(map: MapboxMap, districts: CityDistricts | null | undefined): void {
	const src = map.getSource(DISTRICT_SOURCE) as GeoJSONSource | undefined;
	if (src && "setData" in src) src.setData(toDistrictCollection(districts));
	const labels = map.getSource(DISTRICT_LABEL_SOURCE) as GeoJSONSource | undefined;
	if (labels && "setData" in labels) labels.setData(toDistrictLabelCollection(districts));
}

export function setSelectedDistrict(map: MapboxMap, id: string | null | undefined): void {
	const filter = selectedFilter(id);
	if (map.getLayer(DISTRICT_SELECTED_FILL)) map.setFilter(DISTRICT_SELECTED_FILL, filter);
	if (map.getLayer(DISTRICT_SELECTED_LINE)) map.setFilter(DISTRICT_SELECTED_LINE, filter);
}

export function setDistrictLocale(map: MapboxMap, isRTL: boolean): void {
	if (map.getLayer(DISTRICT_LABELS)) map.setLayoutProperty(DISTRICT_LABELS, "text-field", labelField(isRTL));
}

/** Bounds from the polygon's own rings; a degenerate polygon gives null rather than a bad camera. */
export function districtBounds(
	feature: { geometry: GeoJSON.Geometry } | null | undefined,
): [number, number, number, number] | null {
	const g = feature?.geometry;
	if (!g) return null;
	const polys =
		g.type === "Polygon" ? [g.coordinates] : g.type === "MultiPolygon" ? g.coordinates : [];
	let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
	for (const rings of polys) {
		for (const [x, y] of rings[0] || []) {
			if (x < w) w = x;
			if (x > e) e = x;
			if (y < s) s = y;
			if (y > n) n = y;
		}
	}
	if (!Number.isFinite(w) || !Number.isFinite(s) || w >= e || s >= n) return null;
	return [w, s, e, n];
}

/**
 * A tap on the field picks the حي under it; the fill layer only exists where
 * the field is visible. A tap that lands on a cluster or a pin belongs to them.
 */
export function bindDistrictClick(
	map: MapboxMap,
	onSelect: (districtId: string) => void,
	opts: { unlessLayers?: string[] } = {},
): () => void {
	const onClick = (e: MapMouseEvent) => {
		const above = (opts.unlessLayers || []).filter((id) => map.getLayer(id));
		if (above.length && map.queryRenderedFeatures(e.point, { layers: above }).length) return;
		const f = map.queryRenderedFeatures(e.point, { layers: [DISTRICT_FILL] })[0];
		const id = String((f?.properties as { district_id?: unknown } | undefined)?.district_id || "").trim();
		if (id) onSelect(id);
	};
	const onEnter = () => {
		map.getCanvas().style.cursor = "pointer";
	};
	const onLeave = () => {
		map.getCanvas().style.cursor = "";
	};
	map.on("click", DISTRICT_FILL, onClick);
	map.on("mouseenter", DISTRICT_FILL, onEnter);
	map.on("mouseleave", DISTRICT_FILL, onLeave);
	return () => {
		map.off("click", DISTRICT_FILL, onClick);
		map.off("mouseenter", DISTRICT_FILL, onEnter);
		map.off("mouseleave", DISTRICT_FILL, onLeave);
	};
}

export type DistrictHover = {
	district_id: string;
	name_ar: string;
	name_en: string;
	opportunities: number;
	max_gap: number | null;
	/** What the app lens is encoding here, so the colour is never the only channel. */
	cheapest_app: string | null;
	cheapest_app_share: number | null;
	app_verdict_too_close: boolean;
	comparisons: number;
	/** Pointer position in container pixels, for a chip that follows the cursor. */
	x: number;
	y: number;
};

/**
 * Track the حي under the pointer with feature-state so the hover layers light
 * it up on the GPU, and tell the caller which one it is. Fine pointers only
 * in practice — touch never emits mousemove over the map.
 */
export function bindDistrictHover(map: MapboxMap, onHover: (hit: DistrictHover | null) => void): () => void {
	let current: string | null = null;
	const setHover = (id: string, hover: boolean) => {
		try {
			map.setFeatureState({ source: DISTRICT_SOURCE, id }, { hover });
		} catch {
			/* source mid-swap */
		}
	};
	const clear = () => {
		if (current) setHover(current, false);
		current = null;
		onHover(null);
	};
	const onMove = (e: MapMouseEvent) => {
		const f = map.queryRenderedFeatures(e.point, { layers: [DISTRICT_FILL] })[0];
		const p = (f?.properties || {}) as Partial<DistrictHover>;
		const id = String(p.district_id || "").trim();
		if (!id) {
			clear();
			return;
		}
		if (id !== current) {
			if (current) setHover(current, false);
			current = id;
			setHover(id, true);
		}
		onHover({
			district_id: id,
			name_ar: String(p.name_ar || ""),
			name_en: String(p.name_en || ""),
			opportunities: Number(p.opportunities) || 0,
			max_gap: Number.isFinite(Number(p.max_gap)) ? Number(p.max_gap) : null,
			cheapest_app: p.cheapest_app ? String(p.cheapest_app) : null,
			cheapest_app_share: Number.isFinite(Number(p.cheapest_app_share))
				? Number(p.cheapest_app_share)
				: null,
			/* Mapbox may hand feature properties back as strings after a round trip. */
			app_verdict_too_close: String(p.app_verdict_too_close) === "true",
			comparisons: Number(p.comparisons) || 0,
			x: e.point.x,
			y: e.point.y,
		});
	};
	map.on("mousemove", DISTRICT_FILL, onMove);
	map.on("mouseleave", DISTRICT_FILL, clear);
	map.on("zoomstart", clear);
	map.on("dragstart", clear);
	return () => {
		clear();
		map.off("mousemove", DISTRICT_FILL, onMove);
		map.off("mouseleave", DISTRICT_FILL, clear);
		map.off("zoomstart", clear);
		map.off("dragstart", clear);
	};
}
