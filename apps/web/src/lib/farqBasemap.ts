/**
 * Farq Dusk — the map's own cartography.
 *
 * Not "Mapbox with a tint on top": a Farq-owned style on the Mapbox Streets v8
 * vector source, so land, buildings, roads, bridges, parks, water and type
 * hierarchy are ours to design. The hour is blue-hour, not midnight — a cool
 * ambient sky over a warm low key light, so roofs read brighter than facades
 * and the city looks like an architectural model rather than a field of blocks.
 *
 * Rules that keep this file honest:
 * - Colours live in FARQ_BASEMAP_COLORS. No hardcoded hex further down.
 * - Labels and shields read Mapbox source fields (`name_ar`, `name_en`, `ref`,
 *   `shield`) only. Nothing is translated, transliterated or invented here.
 * - The basemap is the stage; mint is a signal. Mint never paints the map —
 *   it only lights the selected opportunity.
 * - No layer animates per frame, and the layer budget stays far under the
 *   ~200 that Mapbox Standard carries at every zoom.
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
export const FARQ_SHIELD_IMAGE = "farq-road-shield";

/* ──────────────────────────── Farq Dusk palette ────────────────────────────
 * Warm charcoal ground with a plum undertone, matte brown-charcoal buildings,
 * cool grey road infrastructure, muted green parks, desaturated teal water and
 * warm off-white type. Lifted off pure black so the city has air in it.
 */
export type FarqBasemapTheme = "day" | "dusk";

/** Farq Day — the default. Warm off-white ground, sand-tinted desert, pale
 *  stone buildings, white road infrastructure over warm grey casings, muted
 *  green parks, soft teal water, dark green-ink type. Bright and calm; the
 *  opportunity layer is the only saturated thing on screen. */
const FARQ_DAY = {
	groundFar: "#E8E4DD",
	groundNear: "#F0ECE5",
	groundResidential: "#EDE8DF",
	groundCommercial: "#F3ECDE",
	groundIndustrial: "#E6E1D8",
	sand: "#F0E4CE",
	rock: "#E7E2D9",
	airport: "#E4E2DE",
	parkFar: "#D6E4CE",
	parkNear: "#CDE0C4",
	greenLow: "#DDE7D6",
	water: "#C4DBDD",
	waterDeep: "#B4D0D6",
	waterway: "#A6C7CD",
	buildingLow: "#DAD2C6",
	buildingMid: "#D2C8BA",
	buildingTall: "#C6BAA9",
	buildingCommercial: "#D6C7AE",
	buildingFlat: "#DCD5CA",
	motorway: "#FFFFFF",
	trunk: "#FEFCF8",
	primary: "#FBF8F2",
	secondary: "#F7F3EB",
	street: "#F4EFE6",
	minor: "#EDE8DE",
	tunnel: "#E0DACF",
	roadCasing: "#CFC3B0",
	bridgeShadow: "#B6A997",
	shieldFill: "#FFFFFF",
	shieldEdge: "#C6BAA6",
	shieldText: "#4A544F",
	admin: "#C3B8A7",
	labelPrimary: "#2E3A36",
	labelSecondary: "#4E5A55",
	labelTertiary: "#77837E",
	labelRoadMajor: "#5A6560",
	labelRoadMinor: "#7C8782",
	labelWater: "#4E8188",
	labelPark: "#4F7A57",
	labelPoi: "#6E7A75",
	poiDot: "#A9B2AD",
	halo: "#FFFFFF",
	/* Farq signal — focus layers only. Mint-700 from the design tokens, because
	 * mint-500 has no contrast left to give against a bright ground. */
	accent: "#18A66A",
	accentBuilding: "#2FA875",
	accentEmissive: 0.14,
	buildingEmissive: 0.02,
	focusGlowOpacity: 0.22,
	focusRoadOpacity: 0.45,
	/* Late-morning sun: an almost-white sky and a soft warm key. */
	lightAmbient: "#F2EFE8",
	lightKey: "#FFF4E2",
	ambientIntensity: 0.72,
	keyIntensity: 0.32,
	fog: "#E4E0D8",
	fogHigh: "#BDD6E6",
	space: "#CFDCE8",
	starIntensity: 0,
};

/** Every colour the basemap is allowed to use, plus the light rig it is lit by. */
export type FarqPalette = typeof FARQ_DAY;

/** Farq Dusk — the blue-hour counterpart. Kept whole so the map can switch
 *  hours without a second style to maintain. */
const FARQ_DUSK: FarqPalette = {
	groundFar: "#141219",
	groundNear: "#1B1921",
	groundResidential: "#221E28",
	groundCommercial: "#2A2432",
	groundIndustrial: "#1D1B23",
	sand: "#251F1A",
	rock: "#201D22",
	airport: "#1D1D25",
	parkFar: "#182C21",
	parkNear: "#1E3629",
	greenLow: "#1A2C22",
	water: "#0E262C",
	waterDeep: "#0B1E24",
	waterway: "#154049",
	buildingLow: "#3A342F",
	buildingMid: "#463E37",
	buildingTall: "#51473D",
	buildingCommercial: "#4B4034",
	buildingFlat: "#262221",
	motorway: "#5B616A",
	trunk: "#4F555D",
	primary: "#43484F",
	secondary: "#383C42",
	street: "#2F3237",
	minor: "#282A30",
	tunnel: "#1F1E25",
	roadCasing: "#121117",
	bridgeShadow: "#0A090D",
	shieldFill: "#2B3037",
	shieldEdge: "#5B616A",
	shieldText: "#D8DFDB",
	admin: "#403C4A",
	labelPrimary: "#EFF2ED",
	labelSecondary: "#C3CCC6",
	labelTertiary: "#939F9A",
	labelRoadMajor: "#AAB6B1",
	labelRoadMinor: "#848F8B",
	labelWater: "#5F9294",
	labelPark: "#75987F",
	labelPoi: "#98A5A0",
	poiDot: "#525B57",
	halo: "#0D0C11",
	accent: "#83F1B1",
	accentBuilding: "#1F3A2D",
	lightAmbient: "#8FA6BE",
	lightKey: "#FFE7CA",
	fog: "#1D1B24",
	fogHigh: "#26404E",
	space: "#07070C",
	accentEmissive: 0.3,
	buildingEmissive: 0.05,
	focusGlowOpacity: 0.16,
	focusRoadOpacity: 0.34,
	ambientIntensity: 0.82,
	keyIntensity: 0.55,
	starIntensity: 0.06,
};

export const FARQ_PALETTES: Record<FarqBasemapTheme, FarqPalette> = { day: FARQ_DAY, dusk: FARQ_DUSK };

/** The palette the map ships with. */
export const FARQ_BASEMAP_THEME: FarqBasemapTheme = "day";
export const FARQ_BASEMAP_COLORS = FARQ_PALETTES[FARQ_BASEMAP_THEME];

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
	"farq-bridge-major",
	"farq-bridge-minor",
] as const;

/** Source fields only — never a generated translation. */
export function farqLabelField(language: FarqMapLanguage): ExpressionSpecification {
	return language === "ar"
		? ["coalesce", ["get", "name_ar"], ["get", "name_en"], ["get", "name"]]
		: ["coalesce", ["get", "name_en"], ["get", "name"]];
}

const emptyCollection = (): GeoJSON.FeatureCollection => ({ type: "FeatureCollection", features: [] });

/** Selected-opportunity switch, reused wherever the focus changes a paint value. */
const whenFocused = (on: number | string, off: number | string): ExpressionSpecification =>
	["case", ["boolean", ["feature-state", "farqFocus"], false], on, off] as ExpressionSpecification;

function zoomRamp(stops: Array<[number, number]>): ExpressionSpecification {
	return ["interpolate", ["exponential", 1.5], ["zoom"], ...stops.flat()] as ExpressionSpecification;
}

/* Ground-plane layers opt out of the 3D lighting rig: the palette above is the
 * design, and only buildings should react to the sun. */
const UNLIT = 1;

const GROUND = ["match", ["get", "structure"], ["bridge", "tunnel"], false, true] as ExpressionSpecification;

/**
 * One road tier. `border` is Mapbox's own line casing — real infrastructure
 * weight without a second layer per class to keep in order.
 */
function roadLayer(opts: {
	id: string;
	classes: string[];
	color: string;
	widths: Array<[number, number]>;
	minzoom: number;
	structure?: ExpressionSpecification;
	border?: Array<[number, number]>;
	borderColor?: string;
	opacity?: ExpressionSpecification | number;
}): LayerSpecification {
	return {
		id: opts.id,
		type: "line",
		source: SRC_BASE,
		"source-layer": "road",
		minzoom: opts.minzoom,
		filter: ["all", ["match", ["get", "class"], opts.classes, true, false], opts.structure ?? GROUND],
		layout: { "line-cap": "round", "line-join": "round" },
		paint: {
			"line-color": opts.color,
			"line-width": zoomRamp(opts.widths),
			"line-opacity": opts.opacity ?? 1,
			"line-emissive-strength": UNLIT,
			...(opts.border
				? { "line-border-width": zoomRamp(opts.border), "line-border-color": opts.borderColor ?? FARQ_DAY.roadCasing }
				: {}),
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
	opacity?: ExpressionSpecification | number;
	maxWidth?: number;
	offsetY?: number;
	sortKey?: ExpressionSpecification;
	halo: string;
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
			...(opts.sortKey ? { "symbol-sort-key": opts.sortKey } : {}),
			...(opts.placement === "line"
				? { "symbol-placement": "line", "text-rotation-alignment": "map", "text-pitch-alignment": "viewport", "symbol-spacing": 340 }
				: { "text-padding": 4, ...(opts.offsetY ? { "text-offset": [0, opts.offsetY], "text-anchor": "top" } : {}) }),
		},
		paint: {
			"text-color": opts.color,
			"text-halo-color": opts.halo,
			"text-halo-width": opts.haloWidth ?? 1.2,
			"text-halo-blur": 0.6,
			"text-opacity": opts.opacity ?? 1,
			"text-emissive-strength": UNLIT,
		},
	} as LayerSpecification;
}

/**
 * Farq Dusk.
 *
 * Zoom story: land and motorways far out, city structure at z12, neighbourhood
 * fabric at z14, urban fabric at z16, buildings and streets past z17. Each band
 * tells a different story instead of enlarging the last one.
 */
export function buildFarqBasemapStyle(language: FarqMapLanguage = "ar", theme: FarqBasemapTheme = FARQ_BASEMAP_THEME): StyleSpecification {
	const C = FARQ_PALETTES[theme];
	const label = (opts: Omit<Parameters<typeof labelLayer>[0], "halo">) => labelLayer({ ...opts, halo: C.halo });

	const layers: LayerSpecification[] = [
		{
			id: "farq-ground",
			type: "background",
			paint: {
				"background-color": ["interpolate", ["linear"], ["zoom"], 4, C.groundFar, 11, C.groundNear],
				"background-emissive-strength": UNLIT,
			},
		},
		/* ── City texture: enough to tell a district from a suburb, no more ── */
		{
			id: "farq-landcover-green",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landcover",
			minzoom: 5,
			filter: ["match", ["get", "class"], ["wood", "scrub", "grass", "crop"], true, false],
			paint: { "fill-color": C.greenLow, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 5, 0.25, 12, 0.55], "fill-emissive-strength": UNLIT },
		},
		{
			id: "farq-land-rock",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 8,
			filter: ["match", ["get", "class"], ["rock", "glacier"], true, false],
			paint: { "fill-color": C.rock, "fill-opacity": 0.5, "fill-emissive-strength": UNLIT },
		},
		{
			id: "farq-land-sand",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 7,
			filter: ["match", ["get", "class"], ["sand"], true, false],
			paint: { "fill-color": C.sand, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 7, 0.35, 12, 0.7], "fill-emissive-strength": UNLIT },
		},
		{
			id: "farq-land-residential",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 11,
			filter: ["match", ["get", "class"], ["residential"], true, false],
			paint: { "fill-color": C.groundResidential, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 11, 0, 12.5, 0.85], "fill-emissive-strength": UNLIT },
		},
		{
			id: "farq-land-commercial",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 11.5,
			filter: ["match", ["get", "class"], ["commercial_area"], true, false],
			paint: { "fill-color": C.groundCommercial, "fill-opacity": ["interpolate", ["linear"], ["zoom"], 11.5, 0, 13, 0.9], "fill-emissive-strength": UNLIT },
		},
		{
			id: "farq-land-industrial",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 12,
			filter: ["match", ["get", "class"], ["industrial", "facility"], true, false],
			paint: { "fill-color": C.groundIndustrial, "fill-opacity": 0.8, "fill-emissive-strength": UNLIT },
		},
		{
			id: "farq-land-airport",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse",
			minzoom: 9,
			filter: ["match", ["get", "class"], ["airport"], true, false],
			paint: { "fill-color": C.airport, "fill-opacity": 0.9, "fill-emissive-strength": UNLIT },
		},
		/* ── Parks: muted Farq green, deliberately behind an opportunity's mint ── */
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
				"fill-emissive-strength": UNLIT,
			},
		},
		{
			id: "farq-park-overlay",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "landuse_overlay",
			minzoom: 6,
			filter: ["match", ["get", "class"], ["national_park", "wetland", "wetland_noveg"], true, false],
			paint: { "fill-color": C.parkFar, "fill-opacity": 0.55, "fill-emissive-strength": UNLIT },
		},
		/* ── Water: calm, low contrast, never competing with an opportunity ── */
		{
			id: "farq-water",
			type: "fill",
			source: SRC_BASE,
			"source-layer": "water",
			paint: {
				"fill-color": ["interpolate", ["linear"], ["zoom"], 4, C.waterDeep, 10, C.water],
				"fill-emissive-strength": UNLIT,
			},
		},
		{
			id: "farq-waterway",
			type: "line",
			source: SRC_BASE,
			"source-layer": "waterway",
			minzoom: 8,
			paint: { "line-color": C.waterway, "line-width": zoomRamp([[8, 0.5], [14, 2], [18, 8]]), "line-opacity": 0.75, "line-emissive-strength": UNLIT },
		},
		{
			id: "farq-aeroway",
			type: "line",
			source: SRC_BASE,
			"source-layer": "aeroway",
			minzoom: 10,
			paint: { "line-color": C.minor, "line-width": zoomRamp([[10, 0.8], [14, 4], [17, 16]]), "line-opacity": 0.7, "line-emissive-strength": UNLIT },
		},
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
				"line-emissive-strength": UNLIT,
			},
		},
		/* ── Tunnels: recessed, still traceable ── */
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
			paint: {
				"line-color": C.tunnel,
				"line-width": zoomRamp([[12, 0.9], [15, 3.4], [18, 13]]),
				"line-dasharray": [2.4, 1.4],
				"line-opacity": 0.85,
				"line-border-width": zoomRamp([[12, 0.4], [16, 1.4]]),
				"line-border-color": C.bridgeShadow,
				"line-emissive-strength": UNLIT,
			},
		},
		/* ── Roads: the hierarchy is the branding ──
		 * Majors carry a casing so they read as built infrastructure; locals stay
		 * hairlines so the fabric never turns to noise. */
		roadLayer({ id: "farq-road-path", classes: ["path", "pedestrian", "track", "steps"], color: C.minor, widths: [[15, 0.4], [17, 1.2], [19, 3]], minzoom: 15, opacity: 0.45 }),
		roadLayer({ id: "farq-road-service", classes: ["service", "golf"], color: C.minor, widths: [[14.5, 0.5], [17, 2], [19, 6]], minzoom: 14.5, opacity: 0.7 }),
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
			border: [[13, 0], [14, 0.6], [17, 1.2]],
		}),
		roadLayer({
			id: "farq-road-trunk",
			classes: ["trunk", "trunk_link"],
			color: C.trunk,
			widths: [[7, 0.5], [11, 1.6], [14, 4.2], [16, 9.5], [18, 24], [20, 46]],
			minzoom: 7,
			border: [[11, 0], [12.5, 0.7], [16, 1.5], [18, 2.2]],
		}),
		roadLayer({
			id: "farq-road-motorway",
			classes: ["motorway", "motorway_link"],
			color: C.motorway,
			widths: [[6, 0.5], [10, 1.5], [13, 4], [16, 11], [18, 26], [20, 50]],
			minzoom: 5.5,
			border: [[10, 0], [11.5, 0.9], [16, 1.9], [18, 2.8]],
		}),
		/* ── Buildings: a matte architectural model ──
		 * Flat footprints hand over to extrusions as the camera arrives, and the
		 * extrusion grows out of the ground rather than popping in. */
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
				"fill-emissive-strength": UNLIT,
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
				/* Taller buildings gain presence; commercial stock carries its own
				 * character. The selected opportunity turns a dark mint — lit from
				 * within, never painted over. */
				"fill-extrusion-color": [
					"case",
					["boolean", ["feature-state", "farqFocus"], false],
					C.accentBuilding,
					["match", ["get", "type"], ["commercial", "retail", "office", "hotel", "supermarket", "mall"], C.buildingCommercial, ["interpolate", ["linear"], ["number", ["get", "height"], 0], 0, C.buildingLow, 25, C.buildingMid, 90, C.buildingTall]],
				],
				"fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 15, 0, 16.2, ["number", ["get", "height"], 3]],
				"fill-extrusion-base": ["interpolate", ["linear"], ["zoom"], 15, 0, 16.2, ["number", ["get", "min_height"], 0]],
				"fill-extrusion-opacity": ["interpolate", ["linear"], ["zoom"], 15, 0.55, 16.5, 0.94],
				/* Roof brighter than facade, facade brighter than base. */
				"fill-extrusion-vertical-gradient": true,
				"fill-extrusion-ambient-occlusion-intensity": 0.42,
				"fill-extrusion-ambient-occlusion-radius": 4,
				/* A floor of self-lit so nothing sinks to pure black, and a real
				 * glow on the one building that matters. */
				"fill-extrusion-emissive-strength": whenFocused(C.accentEmissive, C.buildingEmissive),
				"fill-extrusion-flood-light-color": C.accent,
				"fill-extrusion-flood-light-intensity": 0.4,
				"fill-extrusion-flood-light-ground-radius": whenFocused(26, 0),
				"fill-extrusion-flood-light-wall-radius": whenFocused(14, 0),
				/* Distant extrusions fade instead of piling up on the horizon. */
				"fill-extrusion-cutoff-fade-range": 0.4,
				"fill-extrusion-cast-shadows": false,
			},
		},
		/* ── Bridges: drawn after the buildings they fly over ── */
		{
			id: "farq-bridge-shadow",
			type: "line",
			source: SRC_BASE,
			"source-layer": "road",
			minzoom: 13,
			filter: ["all", ["==", ["get", "structure"], "bridge"], ["match", ["get", "class"], ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "secondary", "tertiary", "street"], true, false]],
			layout: { "line-cap": "butt", "line-join": "round" },
			paint: {
				"line-color": C.bridgeShadow,
				"line-width": zoomRamp([[13, 3], [16, 16], [18, 38], [20, 70]]),
				"line-blur": zoomRamp([[13, 1], [16, 4], [18, 9]]),
				"line-opacity": 0.55,
				"line-translate": [0, 2],
				"line-translate-anchor": "viewport",
				"line-emissive-strength": UNLIT,
			},
		},
		roadLayer({
			id: "farq-bridge-minor",
			classes: ["secondary", "tertiary", "street", "street_limited", "service"],
			color: C.secondary,
			widths: [[13, 1], [16, 5], [18, 14], [20, 30]],
			minzoom: 13,
			structure: ["==", ["get", "structure"], "bridge"],
			border: [[13, 0.4], [16, 1.2], [18, 1.8]],
		}),
		roadLayer({
			id: "farq-bridge-major",
			classes: ["motorway", "motorway_link", "trunk", "trunk_link", "primary"],
			color: C.motorway,
			widths: [[13, 2.4], [16, 11], [18, 26], [20, 50]],
			minzoom: 12,
			structure: ["==", ["get", "structure"], "bridge"],
			border: [[12, 0.8], [16, 2.1], [18, 3]],
		}),
		/* ── Farq focus: the only mint on the map, and only on selection ── */
		{
			id: "farq-focus-road-accent",
			type: "line",
			source: FARQ_FOCUS_ROAD_SOURCE,
			minzoom: 14,
			layout: { "line-cap": "round", "line-join": "round" },
			paint: {
				"line-color": C.accent,
				"line-width": zoomRamp([[14, 1.6], [16, 5], [18, 13]]),
				"line-opacity": C.focusRoadOpacity,
				"line-blur": 1.2,
				"line-emissive-strength": UNLIT,
			},
		},
		{
			id: "farq-focus-glow",
			type: "circle",
			source: FARQ_FOCUS_SOURCE,
			paint: {
				"circle-color": C.accent,
				"circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 10, 14, 26, 18, 70],
				"circle-opacity": C.focusGlowOpacity,
				"circle-blur": 1,
				"circle-pitch-alignment": "map",
				"circle-emissive-strength": UNLIT,
			},
		},
		/* ── Type: orientation, not information overload ── */
		label({
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
		label({
			id: "farq-label-park",
			sourceLayer: "poi_label",
			language,
			minzoom: 13,
			filter: ["all", ["==", ["get", "class"], "park_like"], ["<=", ["get", "filterrank"], 2]],
			size: ["interpolate", ["linear"], ["zoom"], 13, 10, 17, 13],
			color: C.labelPark,
			font: FONT_MEDIUM,
		}),
		/* Farq-drawn shield, filled from the source `ref`. No invented numbers. */
		{
			id: "farq-label-road-shield",
			type: "symbol",
			source: SRC_BASE,
			"source-layer": "road",
			minzoom: 11,
			filter: ["all", ["has", "ref"], ["<=", ["get", "reflen"], 6], ["match", ["get", "class"], ["motorway", "trunk", "primary"], true, false]],
			layout: {
				"text-field": ["get", "ref"],
				"text-font": FONT_BOLD,
				"text-size": ["interpolate", ["linear"], ["zoom"], 11, 9, 16, 11],
				"text-rotation-alignment": "viewport",
				"text-pitch-alignment": "viewport",
				"icon-image": FARQ_SHIELD_IMAGE,
				"icon-text-fit": "both",
				"icon-text-fit-padding": [1, 4, 1, 4],
				"icon-rotation-alignment": "viewport",
				"icon-pitch-alignment": "viewport",
				"symbol-placement": "line",
				"symbol-spacing": 420,
				"symbol-avoid-edges": true,
			},
			paint: {
				"text-color": C.shieldText,
				"text-emissive-strength": UNLIT,
				"icon-emissive-strength": UNLIT,
				"icon-opacity": ["interpolate", ["linear"], ["zoom"], 11, 0, 12, 0.92],
				"text-opacity": ["interpolate", ["linear"], ["zoom"], 11, 0, 12, 1],
			},
		},
		label({
			id: "farq-label-road-major",
			sourceLayer: "road",
			language,
			minzoom: 12.5,
			filter: ["match", ["get", "class"], ["motorway", "trunk", "primary"], true, false],
			size: ["interpolate", ["linear"], ["zoom"], 12.5, 9.5, 16, 12.5],
			color: C.labelRoadMajor,
			font: FONT_MEDIUM,
			placement: "line",
			haloWidth: 1.3,
		}),
		label({
			id: "farq-label-road-minor",
			sourceLayer: "road",
			language,
			minzoom: 15,
			filter: ["match", ["get", "class"], ["secondary", "tertiary", "street", "street_limited"], true, false],
			size: ["interpolate", ["linear"], ["zoom"], 15, 9, 18, 11.5],
			color: C.labelRoadMinor,
			font: FONT_REGULAR,
			placement: "line",
			opacity: ["interpolate", ["linear"], ["zoom"], 15, 0, 16, 1],
		}),
		{
			id: "farq-poi-dot",
			type: "circle",
			source: SRC_BASE,
			"source-layer": "poi_label",
			minzoom: 16,
			filter: ["all", ["!=", ["get", "class"], "park_like"], ["<=", ["get", "filterrank"], 2]],
			paint: {
				"circle-color": C.poiDot,
				"circle-radius": ["interpolate", ["linear"], ["zoom"], 16, 1.2, 18, 2.2],
				"circle-opacity": 0.8,
				"circle-emissive-strength": UNLIT,
			},
		},
		/* POIs arrive last and thinnest — one rank at a time, never all at once. */
		label({
			id: "farq-label-poi",
			sourceLayer: "poi_label",
			language,
			minzoom: 16,
			filter: ["all", ["!=", ["get", "class"], "park_like"], ["<=", ["get", "filterrank"], ["step", ["zoom"], 1, 17, 2, 18, 3]]],
			size: ["interpolate", ["linear"], ["zoom"], 16, 9.5, 18, 11.5],
			color: C.labelPoi,
			font: FONT_REGULAR,
			maxWidth: 7,
			/* the dot is the marker, the name hangs under it */
			offsetY: 0.85,
			sortKey: ["get", "filterrank"],
			opacity: ["interpolate", ["linear"], ["zoom"], 16, 0, 16.6, 0.9],
		}),
		label({
			id: "farq-label-neighborhood",
			sourceLayer: "place_label",
			language,
			minzoom: 11.5,
			filter: ["==", ["get", "class"], "settlement_subdivision"],
			size: ["interpolate", ["linear"], ["zoom"], 11.5, 10.5, 15, 13.5, 17, 15],
			color: C.labelSecondary,
			font: FONT_MEDIUM,
			letterSpacing: 0.07,
			sortKey: ["get", "filterrank"],
			opacity: ["interpolate", ["linear"], ["zoom"], 11.5, 0, 12.3, 1],
		}),
		label({
			id: "farq-label-settlement-minor",
			sourceLayer: "place_label",
			language,
			minzoom: 8,
			maxzoom: 14,
			filter: ["all", ["==", ["get", "class"], "settlement"], [">", ["get", "symbolrank"], 10]],
			size: ["interpolate", ["linear"], ["zoom"], 8, 10, 13, 13],
			color: C.labelTertiary,
			font: FONT_MEDIUM,
			sortKey: ["get", "symbolrank"],
		}),
		label({
			id: "farq-label-settlement-major",
			sourceLayer: "place_label",
			language,
			maxzoom: 13.5,
			filter: ["all", ["==", ["get", "class"], "settlement"], ["<=", ["get", "symbolrank"], 10]],
			size: ["interpolate", ["linear"], ["zoom"], 3, 11, 8, 16, 12, 21],
			color: C.labelPrimary,
			font: FONT_BOLD,
			letterSpacing: 0.04,
			haloWidth: 1.5,
			sortKey: ["get", "symbolrank"],
			opacity: ["interpolate", ["linear"], ["zoom"], 11.5, 1, 13.2, 0],
		}),
	];

	return {
		version: 8,
		name: theme === "day" ? "Farq Day" : "Farq Dusk",
		glyphs: "mapbox://fonts/mapbox/{fontstack}/{range}.pbf",
		/* Blue hour: a cool sky washing everything, a warm sun low in the west.
		 * Roofs catch both, facades catch one, bases catch neither. */
		lights: [
			{ id: "farq-ambient", type: "ambient", properties: { color: C.lightAmbient, intensity: C.ambientIntensity } },
			{ id: "farq-key", type: "directional", properties: { direction: [205, 35], color: C.lightKey, intensity: C.keyIntensity, "cast-shadows": false } },
		],
		fog: {
			range: [0.8, 8],
			color: C.fog,
			"high-color": C.fogHigh,
			"space-color": C.space,
			"horizon-blend": 0.035,
			"star-intensity": C.starIntensity,
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

/**
 * The Farq route shield — drawn once, stretched around whatever `ref` the
 * source supplies. Small, muted, and never louder than a street name.
 */
export function ensureFarqShieldImage(map: MapboxMap, theme: FarqBasemapTheme = FARQ_BASEMAP_THEME): void {
	try {
		if (map.hasImage(FARQ_SHIELD_IMAGE)) return;
		if (typeof document === "undefined") return;
		const scale = 2;
		const w = 26 * scale;
		const h = 20 * scale;
		const r = 5 * scale;
		const canvas = document.createElement("canvas");
		canvas.width = w;
		canvas.height = h;
		const ctx = canvas.getContext("2d");
		if (!ctx) return;
		const inset = 1 * scale;
		ctx.beginPath();
		if (typeof ctx.roundRect === "function") ctx.roundRect(inset, inset, w - inset * 2, h - inset * 2, r);
		else ctx.rect(inset, inset, w - inset * 2, h - inset * 2);
		ctx.fillStyle = FARQ_PALETTES[theme].shieldFill;
		ctx.fill();
		ctx.lineWidth = scale;
		ctx.strokeStyle = FARQ_PALETTES[theme].shieldEdge;
		ctx.stroke();
		const image = ctx.getImageData(0, 0, w, h);
		map.addImage(
			FARQ_SHIELD_IMAGE,
			{ width: w, height: h, data: new Uint8Array(image.data.buffer) },
			{ pixelRatio: scale, stretchX: [[8 * scale, 18 * scale]], stretchY: [[7 * scale, 13 * scale]], content: [4 * scale, 3 * scale, 22 * scale, 17 * scale] },
		);
	} catch {
		/* no shield is better than a broken style — road names still carry it */
	}
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
 * its building, which lights from within rather than turning green.
 * Runs once per selection, never per frame.
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
