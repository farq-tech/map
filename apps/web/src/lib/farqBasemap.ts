/**
 * Farq Basemap — the map's own visual language.
 *
 * Not "Mapbox with a tint on top": this is a Farq-owned style built on the
 * Mapbox Streets v8 vector source, so land, buildings, roads, parks, water and
 * type hierarchy are ours to design. Farq mint stays a *signal* colour — it is
 * never painted onto the basemap, only onto the focus layers below.
 *
 * Rules that keep this file honest:
 * - Colours live in FARQ_BASEMAP_COLORS. No hardcoded hex further down.
 * - Labels read Mapbox source fields (`name_ar` / `name_en` / `name`) only.
 *   Nothing is translated, transliterated or invented here.
 * - Layer count stays small on purpose (fewer layers than Mapbox Standard),
 *   and no layer animates per frame.
 */

import type {
	ExpressionSpecification,
	GeoJSONSource,
	LayerSpecification,
	Map as MapboxMap,
	StyleSpecification,
} from "mapbox-gl";

export type FarqMapLanguage = "ar" | "en";

const STREETS_V8 = "mapbox://mapbox.mapbox-streets-v8";
const SRC_BASE = "farq-base";
export const FARQ_FOCUS_SOURCE = "farq-focus";
export const FARQ_FOCUS_ROAD_SOURCE = "farq-focus-road";

/* ─────────────────────────── Farq basemap palette ───────────────────────────
 * Deep warm charcoal ground with a plum undertone, warm brown-charcoal
 * buildings, cool muted grey roads, muted Farq green parks, desaturated teal
 * water. The saturated mint (#83F1B1) belongs to opportunity UI, not the map.
 */
export const FARQ_BASEMAP_COLORS = {
	groundFar: "#100F14",
	groundNear: "#17161C",
	groundResidential: "#1A1920",
	groundCommercial: "#1D1B21",
	groundIndustrial: "#191820",
	sand: "#1F1B18",
	rock: "#1B1A1E",
	airport: "#1A1A21",
	parkFar: "#16281E",
	parkNear: "#1B3125",
	greenLow: "#182A20",
	water: "#0C2227",
	waterDeep: "#0A1C21",
	waterway: "#123037",
	buildingLow: "#211E1D",
	buildingMid: "#272322",
	buildingTall: "#302B27",
	buildingCommercial: "#2E2823",
	buildingFlat: "#201D1D",
	lightKey: "#F8EFE3",
	motorway: "#4E545C",
	trunk: "#454A52",
	primary: "#3C4046",
	secondary: "#33363C",
	street: "#2A2C31",
	minor: "#242429",
	tunnel: "#1D1C21",
	roadCasing: "#0D0C11",
	admin: "#3A3743",
	labelPrimary: "#E9EFEC",
	labelSecondary: "#B9C6C1",
	labelTertiary: "#8B9793",
	labelRoadMajor: "#A2AFAA",
	labelRoadMinor: "#7E8A86",
	labelWater: "#5C8C8D",
	labelPark: "#6F9179",
	labelPoi: "#93A09C",
	poiDot: "#4C5551",
	halo: "#0C0B10",
	/* Farq signal — focus layers only. */
	accent: "#83F1B1",
	fog: "#1A1922",
	fogHigh: "#233743",
	space: "#07070C",
} as const;

/* Mapbox-hosted stacks. DIN Pro carries the Latin, Arial Unicode MS the Arabic
 * — both ship with every Mapbox account, so labels can never 404 away. */
const FONT_BOLD = ["DIN Pro Bold", "Arial Unicode MS Bold"];
const FONT_MEDIUM = ["DIN Pro Medium", "Arial Unicode MS Regular"];
const FONT_REGULAR = ["DIN Pro Regular", "Arial Unicode MS Regular"];

/** Every label layer that follows the app locale. */
const LABEL_LAYER_IDS = [
	"farq-label-settlement-major",
	"farq-label-settlement-minor",
	"farq-label-neighborhood",
	"farq-label-water",
	"farq-label-park",
	"farq-label-poi",
	"farq-label-road-major",
	"farq-label-road-minor",
] as const;

/** Roads the opportunity accent may latch onto. */
const ROAD_LAYER_IDS = [
	"farq-road-motorway",
	"farq-road-trunk",
	"farq-road-primary",
	"farq-road-secondary",
	"farq-road-street",
] as const;

/** Source fields only — never a generated translation. */
export function farqLabelField(language: FarqMapLanguage): ExpressionSpecification {
	return language === "ar"
		? ["coalesce", ["get", "name_ar"], ["get", "name_en"], ["get", "name"]]
		: ["coalesce", ["get", "name_en"], ["get", "name"]];
}

const emptyCollection = (): GeoJSON.FeatureCollection => ({ type: "FeatureCollection", features: [] });

function roadWidth(stops: Array<[number, number]>): ExpressionSpecification {
	return ["interpolate", ["exponential", 1.5], ["zoom"], ...stops.flat()] as ExpressionSpecification;
}

function roadLayer(opts: {
	id: string;
	classes: string[];
	color: string;
	widths: Array<[number, number]>;
	minzoom: number;
	opacity?: ExpressionSpecification | number;
	blur?: number;
}): LayerSpecification {
	return {
		id: opts.id,
		type: "line",
		source: SRC_BASE,
		"source-layer": "road",
		minzoom: opts.minzoom,
		filter: [
			"all",
			["match", ["get", "class"], opts.classes, true, false],
			["!=", ["get", "structure"], "tunnel"],
		],
		layout: { "line-cap": "round", "line-join": "round" },
		paint: {
			"line-color": opts.color,
			"line-width": roadWidth(opts.widths),
			"line-opacity": opts.opacity ?? 1,
			...(opts.blur ? { "line-blur": opts.blur } : {}),
		},
	} as LayerSpecification;
}

function labelLayer(opts: {
	id: string;
	sourceLayer: string;
	language: FarqMapLanguage;
	filter?: unknown;
	minzoom?: number;
	maxzoom?: number;
	size: ExpressionSpecification | number;
	color: string;
	font: string[];
	letterSpacing?: number;
	haloWidth?: number;
	placement?: "point" | "line";
	transform?: "none" | "uppercase";
	opacity?: ExpressionSpecification | number;
	maxWidth?: number;
	offsetY?: number;
}): LayerSpecification {
	return {
		id: opts.id,
		type: "symbol",
		source: SRC_BASE,
		"source-layer": opts.sourceLayer,
		...(opts.minzoom == null ? {} : { minzoom: opts.minzoom }),
		...(opts.maxzoom == null ? {} : { maxzoom: opts.maxzoom }),
		...(opts.filter ? { filter: opts.filter } : {}),
		layout: {
			"text-field": farqLabelField(opts.language),
			"text-font": opts.font,
			"text-size": opts.size,
			"text-letter-spacing": opts.letterSpacing ?? 0,
			"text-max-width": opts.maxWidth ?? 8,
			"text-transform": opts.transform ?? "none",
			...(opts.placement === "line"
				? { "symbol-placement": "line", "text-rotation-alignment": "map", "text-pitch-alignment": "viewport", "symbol-spacing": 320 }
				: { "text-padding": 3, ...(opts.offsetY ? { "text-offset": [0, opts.offsetY], "text-anchor": "top" } : {}) }),
		},
		paint: {
			"text-color": opts.color,
			"text-halo-color": FARQ_BASEMAP_COLORS.halo,
			"text-halo-width": opts.haloWidth ?? 1.1,
			"text-halo-blur": 0.5,
			"text-opacity": opts.opacity ?? 1,
		},
	} as LayerSpecification;
}

/**
 * The Farq basemap style.
 *
 * Zoom story: land + motorways + city names far out, neighbourhoods and
 * secondary roads mid, 3D buildings + streets + POIs close in. Nothing is
 * drawn at every zoom "just in case" — richness arrives with the camera.
 */
export function buildFarqBasemapStyle(language: FarqMapLanguage = "ar"): StyleSpecification {
	const C = FARQ_BASEMAP_COLORS;

	const layers: LayerSpecification[] = [
		{
			id: "farq-ground",
			type: "background",
			paint: {
				"background-color": ["interpolate", ["linear"], ["zoom"], 4, C.groundFar, 11, C.groundNear],
			},
		},
		/* ── Land texture: enough to read the city, never enough to shout ── */
		{
			id: "farq-land-rock",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 8,
			filter: ["match", ["get", "class"], ["rock", "glacier"], true, false],
			paint: { "fill-color": C.rock, "fill-opacity": 0.5 },
		},
		{
			id: "farq-land-sand",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 7,
			filter: ["match", ["get", "class"], ["sand"], true, false],
			paint: { "fill-color": C.sand, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 7, 0.35, 12, 0.7] },
		},
		{
			id: "farq-land-residential",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 11,
			filter: ["match", ["get", "class"], ["residential"], true, false],
			paint: { "fill-color": C.groundResidential, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 11, 0, 13, 0.85] },
		},
		{
			id: "farq-land-commercial",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 11.5,
			filter: ["match", ["get", "class"], ["commercial_area"], true, false],
			paint: { "fill-color": C.groundCommercial, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 11.5, 0, 13.5, 0.9] },
		},
		{
			id: "farq-land-industrial",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 12,
			filter: ["match", ["get", "class"], ["industrial", "facility"], true, false],
			paint: { "fill-color": C.groundIndustrial, "fill-opacity": 0.8 },
		},
		{
			id: "farq-land-airport",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 9,
			filter: ["match", ["get", "class"], ["airport"], true, false],
			paint: { "fill-color": C.airport, "fill-opacity": 0.9 },
		},
		{
			id: "farq-landcover-green",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landcover",
			minzoom: 5,
			filter: ["match", ["get", "class"], ["wood", "scrub", "grass", "crop"], true, false],
			paint: { "fill-color": C.greenLow, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 5, 0.25, 12, 0.55] },
		},
		/* ── Parks: muted Farq green, deliberately behind the mint of an opportunity ── */
		{
			id: "farq-park",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 8,
			filter: ["match", ["get", "class"], ["park", "grass", "pitch", "cemetery", "piste", "agriculture"], true, false],
			paint: {
				"fill-color": ["interpolate", ["linear"], ["zoom"], 10, C.parkFar, 15, C.parkNear],
				"fill-opacity": ["interpolate", ["linear"], ["zoom"], 8, 0.55, 13, 0.9],
			},
		},
		{
			id: "farq-park-overlay",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse_overlay",
			minzoom: 6,
			filter: ["match", ["get", "class"], ["national_park", "wetland", "wetland_noveg"], true, false],
			paint: { "fill-color": C.parkFar, "fill-opacity": 0.55 },
		},
		/* ── Water: calm, low contrast, never competing with an opportunity ── */
		{
			id: "farq-water",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "water",
			paint: {
				"fill-color": ["interpolate", ["linear"], ["zoom"], 4, C.waterDeep, 10, C.water],
			},
		},
		{
			id: "farq-waterway",
			type: "line",
			source: SRC_BASE,
			"source-layer": "waterway",
			minzoom: 8,
			paint: {
				"line-color": C.waterway,
				"line-width": roadWidth([[8, 0.5], [14, 2], [18, 8]]),
				"line-opacity": 0.75,
			},
		},
		{
			id: "farq-aeroway",
			type: "line",
			source: SRC_BASE,
			"source-layer": "aeroway",
			minzoom: 10,
			paint: { "line-color": C.minor, "line-width": roadWidth([[10, 0.8], [14, 4], [17, 16]]), "line-opacity": 0.7 },
		},
		/* ── Roads: the hierarchy is the branding ── */
		{
			id: "farq-road-tunnel",
			type: "line",
			source: SRC_BASE,
			"source-layer": "road",
			minzoom: 12,
			filter: [
				"all",
				["==", ["get", "structure"], "tunnel"],
				["match", ["get", "class"], ["motorway", "trunk", "primary", "secondary", "tertiary", "street"], true, false],
			],
			layout: { "line-cap": "butt", "line-join": "round" },
			paint: { "line-color": C.tunnel, "line-width": roadWidth([[12, 0.8], [15, 3], [18, 12]]), "line-opacity": 0.8 },
		},
		roadLayer({
			id: "farq-road-path",
			classes: ["path", "pedestrian", "track", "steps"],
			color: C.minor,
			widths: [[15, 0.4], [17, 1.2], [19, 3]],
			minzoom: 15,
			opacity: 0.45,
		}),
		roadLayer({
			id: "farq-road-service",
			classes: ["service", "golf"],
			color: C.minor,
			widths: [[14.5, 0.5], [17, 2], [19, 6]],
			minzoom: 14.5,
			opacity: 0.7,
		}),
		roadLayer({
			id: "farq-road-street",
			classes: ["street", "street_limited", "construction"],
			color: C.street,
			widths: [[12, 0.35], [14, 0.9], [16, 3.2], [18, 10], [20, 24]],
			minzoom: 12,
			opacity: ["interpolate", ["linear"], ["zoom"], 12, 0.5, 14, 1],
		}),
		roadLayer({
			id: "farq-road-secondary",
			classes: ["secondary", "tertiary"],
			color: C.secondary,
			widths: [[10, 0.4], [13, 1.4], [16, 5], [18, 14], [20, 30]],
			minzoom: 10,
			opacity: ["interpolate", ["linear"], ["zoom"], 10, 0.55, 12.5, 1],
		}),
		roadLayer({
			id: "farq-road-primary",
			classes: ["primary"],
			color: C.primary,
			widths: [[8.5, 0.5], [12, 1.9], [16, 8], [18, 20], [20, 40]],
			minzoom: 8.5,
		}),
		{
			id: "farq-road-trunk-casing",
			type: "line",
			source: SRC_BASE,
			"source-layer": "road",
			minzoom: 11,
			filter: ["all", ["match", ["get", "class"], ["trunk", "motorway"], true, false], ["!=", ["get", "structure"], "tunnel"]],
			layout: { "line-cap": "round", "line-join": "round" },
			paint: {
				"line-color": C.roadCasing,
				"line-width": roadWidth([[11, 3.2], [14, 7.6], [16, 15], [18, 33], [20, 62]]),
				"line-opacity": 0.85,
			},
		},
		roadLayer({
			id: "farq-road-trunk",
			classes: ["trunk", "trunk_link"],
			color: C.trunk,
			widths: [[7, 0.5], [11, 1.6], [14, 4.2], [16, 9.5], [18, 24], [20, 46]],
			minzoom: 7,
		}),
		roadLayer({
			id: "farq-road-motorway",
			classes: ["motorway", "motorway_link"],
			color: C.motorway,
			widths: [[6, 0.5], [10, 1.5], [13, 4], [16, 11], [18, 26], [20, 50]],
			minzoom: 5.5,
		}),
		/* ── Boundaries: a whisper, undisputed lines only ── */
		{
			id: "farq-admin",
			type: "line",
			source: SRC_BASE,
			"source-layer": "admin",
			minzoom: 2,
			filter: ["all", ["<=", ["get", "admin_level"], 1], ["==", ["get", "maritime"], "false"], ["==", ["get", "disputed"], "false"], ["==", ["get", "worldview"], "all"]],
			paint: {
				"line-color": C.admin,
				"line-width": ["interpolate", ["linear"], ["zoom"], 3, 0.5, 10, 1.4],
				"line-opacity": 0.7,
				"line-dasharray": [3, 2],
			},
		},
		/* ── Buildings: atmosphere, not competition ──
		 * Flat footprints hand over to extrusions as the camera arrives; the
		 * extrusion grows out of the ground instead of popping in. */
		{
			id: "farq-building-flat",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "building",
			minzoom: 13.5,
			maxzoom: 16,
			filter: ["all", ["!=", ["get", "type"], "building:part"], ["!=", ["get", "underground"], "true"]],
			paint: {
				"fill-color": C.buildingFlat,
				"fill-opacity": ["interpolate", ["linear"], ["zoom"], 13.5, 0, 14.5, 0.75, 15.6, 0.2, 16, 0],
			},
		},
		{
			id: "farq-building-3d",
			type: "fill-extrusion",
			source: SRC_BASE,
			"source-layer": "building",
			minzoom: 15,
			filter: ["all", ["==", ["get", "extrude"], "true"], ["!=", ["get", "type"], "building:part"], ["!=", ["get", "underground"], "true"]],
			paint: {
				/* Selected opportunity lifts its building a touch — the only mint
				 * the basemap ever wears, and only while something is selected. */
				"fill-extrusion-color": [
					"case",
					["boolean", ["feature-state", "farqFocus"], false],
					C.accent,
					["match", ["get", "type"], ["commercial", "retail", "office", "hotel", "supermarket", "mall"], C.buildingCommercial, ["interpolate", ["linear"], ["number", ["get", "height"], 0], 0, C.buildingLow, 25, C.buildingMid, 90, C.buildingTall]],
				],
				"fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 15, 0, 16.2, ["number", ["get", "height"], 3]],
				"fill-extrusion-base": ["interpolate", ["linear"], ["zoom"], 15, 0, 16.2, ["number", ["get", "min_height"], 0]],
				"fill-extrusion-opacity": ["interpolate", ["linear"], ["zoom"], 15, 0.55, 16.5, 0.92],
				"fill-extrusion-vertical-gradient": true,
				"fill-extrusion-ambient-occlusion-intensity": 0.28,
				"fill-extrusion-ambient-occlusion-radius": 3,
			},
		},
		/* ── Farq focus: the only mint on the map, and only on selection ── */
		{
			id: "farq-focus-road-accent",
			type: "line",
			source: FARQ_FOCUS_ROAD_SOURCE,
			minzoom: 14,
			layout: { "line-cap": "round", "line-join": "round" },
			paint: {
				"line-color": C.accent,
				"line-width": roadWidth([[14, 1.6], [16, 5], [18, 13]]),
				"line-opacity": 0.34,
				"line-blur": 1.2,
			},
		},
		{
			id: "farq-focus-glow",
			type: "circle",
			source: FARQ_FOCUS_SOURCE,
			paint: {
				"circle-color": C.accent,
				"circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 10, 14, 26, 18, 70],
				"circle-opacity": 0.16,
				"circle-blur": 1,
				"circle-pitch-alignment": "map",
			},
		},
		/* ── Type: four weights, four jobs ── */
		labelLayer({
			id: "farq-label-water",
			sourceLayer: "natural_label",
			language,
			minzoom: 4,
			filter: ["match", ["get", "class"], ["ocean", "sea", "bay", "water", "reservoir"], true, false],
			size: ["interpolate", ["linear"], ["zoom"], 4, 10, 12, 14],
			color: C.labelWater,
			font: FONT_MEDIUM,
			letterSpacing: 0.12,
			opacity: 0.85,
		}),
		labelLayer({
			id: "farq-label-park",
			sourceLayer: "poi_label",
			language,
			minzoom: 13,
			filter: ["all", ["==", ["get", "class"], "park_like"], ["<=", ["get", "filterrank"], 2]],
			size: ["interpolate", ["linear"], ["zoom"], 13, 10, 17, 13],
			color: C.labelPark,
			font: FONT_MEDIUM,
		}),
		labelLayer({
			id: "farq-label-road-major",
			sourceLayer: "road",
			language,
			minzoom: 12,
			filter: ["match", ["get", "class"], ["motorway", "trunk", "primary"], true, false],
			size: ["interpolate", ["linear"], ["zoom"], 12, 9.5, 16, 12.5],
			color: C.labelRoadMajor,
			font: FONT_MEDIUM,
			placement: "line",
			haloWidth: 1.2,
		}),
		labelLayer({
			id: "farq-label-road-minor",
			sourceLayer: "road",
			language,
			minzoom: 14.5,
			filter: ["match", ["get", "class"], ["secondary", "tertiary", "street", "street_limited"], true, false],
			size: ["interpolate", ["linear"], ["zoom"], 14.5, 9, 18, 11.5],
			color: C.labelRoadMinor,
			font: FONT_REGULAR,
			placement: "line",
			opacity: ["interpolate", ["linear"], ["zoom"], 14.5, 0, 15.5, 1],
		}),
		labelLayer({
			id: "farq-label-poi",
			sourceLayer: "poi_label",
			language,
			minzoom: 15.5,
			filter: ["all", ["!=", ["get", "class"], "park_like"], ["<=", ["get", "filterrank"], ["step", ["zoom"], 1, 16.5, 2]]],
			size: ["interpolate", ["linear"], ["zoom"], 15.5, 9.5, 18, 11.5],
			color: C.labelPoi,
			font: FONT_REGULAR,
			maxWidth: 7,
			/* the dot is the marker, the name hangs under it */
			offsetY: 0.85,
			opacity: ["interpolate", ["linear"], ["zoom"], 15.5, 0, 16.2, 0.9],
		}),
		{
			id: "farq-poi-dot",
			type: "circle",
			source: SRC_BASE,
			"source-layer": "poi_label",
			minzoom: 16,
			filter: ["all", ["!=", ["get", "class"], "park_like"], ["<=", ["get", "filterrank"], 2]],
			paint: {
				"circle-color": FARQ_BASEMAP_COLORS.poiDot,
				"circle-radius": ["interpolate", ["linear"], ["zoom"], 16, 1.2, 18, 2.2],
				"circle-opacity": 0.8,
			},
		},
		labelLayer({
			id: "farq-label-neighborhood",
			sourceLayer: "place_label",
			language,
			minzoom: 11.5,
			filter: ["==", ["get", "class"], "settlement_subdivision"],
			size: ["interpolate", ["linear"], ["zoom"], 11.5, 10.5, 15, 13.5, 17, 15],
			color: C.labelSecondary,
			font: FONT_MEDIUM,
			letterSpacing: 0.07,
			opacity: ["interpolate", ["linear"], ["zoom"], 11.5, 0, 12.3, 1],
		}),
		labelLayer({
			id: "farq-label-settlement-minor",
			sourceLayer: "place_label",
			language,
			minzoom: 8,
			maxzoom: 15,
			filter: ["all", ["==", ["get", "class"], "settlement"], [">", ["get", "symbolrank"], 10]],
			size: ["interpolate", ["linear"], ["zoom"], 8, 10, 13, 13],
			color: C.labelTertiary,
			font: FONT_MEDIUM,
		}),
		labelLayer({
			id: "farq-label-settlement-major",
			sourceLayer: "place_label",
			language,
			maxzoom: 14,
			filter: ["all", ["==", ["get", "class"], "settlement"], ["<=", ["get", "symbolrank"], 10]],
			size: ["interpolate", ["linear"], ["zoom"], 3, 11, 8, 16, 12, 21],
			color: C.labelPrimary,
			font: FONT_BOLD,
			letterSpacing: 0.04,
			haloWidth: 1.4,
			opacity: ["interpolate", ["linear"], ["zoom"], 12, 1, 13.6, 0],
		}),
	];

	return {
		version: 8,
		name: "Farq Night",
		glyphs: "mapbox://fonts/mapbox/{fontstack}/{range}.pbf",
		/* Warm key light from above-left keeps building tops brighter than their
		 * sides without a single outline. */
		light: { anchor: "viewport", color: FARQ_BASEMAP_COLORS.lightKey, intensity: 0.3, position: [1.4, 205, 42] },
		fog: {
			range: [0.8, 8],
			color: FARQ_BASEMAP_COLORS.fog,
			"high-color": FARQ_BASEMAP_COLORS.fogHigh,
			"space-color": FARQ_BASEMAP_COLORS.space,
			"horizon-blend": 0.035,
			"star-intensity": 0.06,
		},
		transition: { duration: 260, delay: 0 },
		sources: {
			[SRC_BASE]: { type: "vector", url: STREETS_V8 },
			[FARQ_FOCUS_SOURCE]: { type: "geojson", data: emptyCollection() },
			[FARQ_FOCUS_ROAD_SOURCE]: { type: "geojson", data: emptyCollection() },
		},
		layers,
	} as StyleSpecification;
}

/** Swap label locale in place — cheaper and calmer than reloading the style. */
export function applyFarqLabelLanguage(map: MapboxMap, language: FarqMapLanguage): void {
	const field = farqLabelField(language);
	for (const id of LABEL_LAYER_IDS) {
		try {
			if (map.getLayer(id)) map.setLayoutProperty(id, "text-field", field);
		} catch {
			/* style not ours (satellite) — labels stay as Mapbox ships them */
		}
	}
}

function setGeoJson(map: MapboxMap, id: string, data: GeoJSON.FeatureCollection): void {
	try {
		const source = map.getSource(id) as GeoJSONSource | undefined;
		source?.setData(data);
	} catch {
		/* source only exists on the Farq style */
	}
}

/** Road segments under the selected pin — real geometry, clipped to the view. */
function focusRoadCollection(map: MapboxMap, coords: [number, number]): GeoJSON.FeatureCollection {
	const collection = emptyCollection();
	if (map.getZoom() < 14) return collection;
	const layers = ROAD_LAYER_IDS.filter((id) => {
		try {
			return Boolean(map.getLayer(id));
		} catch {
			return false;
		}
	});
	if (layers.length === 0) return collection;
	try {
		const point = map.project(coords);
		const pad = 46;
		const found = map.queryRenderedFeatures(
			[
				[point.x - pad, point.y - pad],
				[point.x + pad, point.y + pad],
			],
			{ layers: [...layers] },
		);
		const seen = new Set<string>();
		for (const feature of found) {
			const name = String((feature.properties as { name?: unknown } | undefined)?.name ?? "");
			const key = `${name}|${feature.id ?? ""}`;
			if (seen.has(key)) continue;
			seen.add(key);
			collection.features.push({ type: "Feature", properties: {}, geometry: feature.geometry as GeoJSON.Geometry });
			if (collection.features.length >= 6) break;
		}
	} catch {
		/* querying is best-effort — no accent is better than a broken map */
	}
	return collection;
}

let focusedBuilding: { source: string; sourceLayer: string; id: string | number } | null = null;

function clearFocusedBuilding(map: MapboxMap): void {
	if (!focusedBuilding) return;
	try {
		map.setFeatureState(focusedBuilding, { farqFocus: false });
	} catch {
		/* style swapped under us */
	}
	focusedBuilding = null;
}

/**
 * Point the Farq accent at one place — ground glow, the road it sits on, and
 * its building. Runs once per selection, never per frame.
 */
export function applyFarqFocus(map: MapboxMap, coords: [number, number] | null): void {
	clearFocusedBuilding(map);
	if (!coords) {
		setGeoJson(map, FARQ_FOCUS_SOURCE, emptyCollection());
		setGeoJson(map, FARQ_FOCUS_ROAD_SOURCE, emptyCollection());
		return;
	}
	setGeoJson(map, FARQ_FOCUS_SOURCE, {
		type: "FeatureCollection",
		features: [{ type: "Feature", properties: {}, geometry: { type: "Point", coordinates: coords } }],
	});
	setGeoJson(map, FARQ_FOCUS_ROAD_SOURCE, focusRoadCollection(map, coords));
	try {
		if (!map.getLayer("farq-building-3d")) return;
		const hit = map.queryRenderedFeatures(map.project(coords), { layers: ["farq-building-3d"] })[0];
		if (!hit || hit.id == null) return;
		focusedBuilding = { source: SRC_BASE, sourceLayer: "building", id: hit.id };
		map.setFeatureState(focusedBuilding, { farqFocus: true });
	} catch {
		focusedBuilding = null;
	}
}
