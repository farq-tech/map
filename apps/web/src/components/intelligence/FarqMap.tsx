/**
 * Farq difference map — Mapbox GL Standard, comparison-row coords.
 * At city zoom the field is the official أحياء (MOMRAH polygons), each tinted
 * only by how many observed opportunities fall inside it; H3 cells are the
 * fallback for a city without boundaries. An optional line-outline toggle
 * (Golden NCP, default off) may stroke rings — no fill.
 * Never invents pins, never remints place_id, never fakes GPS.
 * App logo is the pin hero. The price chip is always smaller.
 * GPU symbols at every zoom for unselected places. One HTML pin = selected.
 * Pin tap selects the place — no Mapbox infowindow; the split sheet owns the moment.
 * Bubbles are overlay-only: this file must not restyle 3D buildings, terrain,
 * camera, zoom, or the Standard/Satellite basemap.
 */
import {
	AVATAR_CHANGED,
	loadAvatar,
	loadVehicleColor,
	vehicleColorHex,
	normalizeHeading,
} from "../../lib/farqAvatar";
import { buildUserMarker, updateUserMarker } from "../../lib/farqUserMarker";
import type { MapboxSearchBox } from "@mapbox/search-js-web";
import mapboxgl, { type Map as MapboxMap } from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import { localizeDigitString } from "../../lib/formatPrice";
import { getProviderLabel } from "../../lib/platformLogos";
import {
	shouldEnableTerrain,
	shouldShow3dObjects,
	shouldSkipGlobeIntro,
} from "../../lib/farqMapDevice";
import {
	ensureSaryLayers,
	setSaryTerrain,
	syncSaryData,
} from "../../lib/sary/mapLayers";
import { bearingBetween, distanceMeters, ensureVehicleLayer, removeVehicle, setVehicle, VEHICLE_LAYER } from "../../lib/sary/vehicleLayer";
import { matchOnMap, RoadMatcher, snapRadius } from "../../lib/sary/roadSnap";
import { lerp } from "../../lib/outings/motion";
import type { OutdoorLayerId } from "../../routes/map";
import {
	AURA_VIEWPORT_IDLE_MS,
	BUBBLE_CLEAR_CHANGE,
	BUBBLE_ENTER_MS,
	applyAuraRankClasses,
	buildPlacePinElement,
	differenceFromPinProps,
	featureMarkerKey,
	observedDifferenceAmount,
	pinIdentityReveal,
	pinPresentationForZoom,
	pinZoomBand,
	playBubbleEnter,
	playMaxGapPulse,
	setPinSelected,
	syncPinPhoto,
	updatePlacePinChip,
} from "../../lib/farqMapPins";
import {
	ensurePriceTileLayers,
	syncPriceTileData,
} from "../../lib/farqPriceTiles";
import {
	bindDistrictClick,
	bindDistrictHover,
	ensureDistrictLayers,
	setDistrictLens,
	setDistrictLocale,
	setSelectedDistrict,
	syncDistrictData,
	type DistrictLens,
} from "../../lib/farqDistrictTiles";
import {
	PRICE_TILE_CLUSTERS,
	PRICE_TILE_ICONS,
	PRICE_TILE_POINTS,
} from "../../lib/farqPriceTiles";
import type { CityDistricts } from "../../services/intelligenceService";
import type { MapViewChangeMeta } from "../../lib/farqMapViewport";
import {
	getMapboxAccessToken,
	type MapboxBasemap,
	mapboxStyleUrl,
	RIYADH_LNG_LAT, ensureRtlTextPlugin } from "../../lib/mapboxAccess";
import { createFarqSearchBox } from "../../lib/mapboxSearch";
import type {
	IntelligenceMapNeighborhoods,
	IntelligenceMapPlaceDetail,
	IntelligenceMapPlaces,
} from "../../services/intelligenceService";
import "../../styles/farq-mapbox.css";

const INTRO_MS = 5600;

type CameraFocusRequest = {
	lat: number;
	lng: number;
	id: string;
	zoom?: number;
	/** Select pads the popup; locate/cluster keep more map around the point. */
	kind?: "select" | "locate" | "cluster" | "bounds";
	/** When set, the camera fits these bounds instead of centring on lat/lng. */
	bounds?: [number, number, number, number] | null;
	/** Screen px covered from the top by the page's own bars (bounds fits keep clear of them). */
	topInset?: number;
	/** Closest the bounds fit may zoom (default 15.5). */
	maxZoom?: number;
};

function cameraPadding(
	kind: CameraFocusRequest["kind"],
	bottomInset = 0,
): {
	top: number;
	bottom: number;
	left: number;
	right: number;
} {
	const mobile =
		typeof window !== "undefined" &&
		window.matchMedia("(max-width: 1023px)").matches;
	if (!mobile) {
		return { top: 88, bottom: 40, left: 40, right: 40 };
	}
	if (kind === "select") {
		/* the sheet's real height, so the chosen pin lands above it — never under it */
		return { top: 132, bottom: Math.max(160, bottomInset + 28), left: 24, right: 24 };
	}
	if (kind === "locate") {
		return { top: 120, bottom: 112, left: 28, right: 28 };
	}
	return { top: 96, bottom: 96, left: 24, right: 24 };
}

function leftUserDot(
	center: { lat: number; lng: number },
	user: { lat: number; lng: number } | null | undefined,
): boolean {
	if (!user) return false;
	const dlat = center.lat - user.lat;
	const dlng = center.lng - user.lng;
	return dlat * dlat + dlng * dlng > 0.000012;
}

type PersistedCamera = {
	center: [number, number];
	zoom: number;
	pitch: number;
	bearing: number;
};

/** Intro + last camera survive React remounts (Strict Mode / search patches). */
const mapSession = {
	introStarted: false,
	camera: null as PersistedCamera | null,
};

function readCamera(map: MapboxMap): PersistedCamera {
	const c = map.getCenter();
	return {
		center: [c.lng, c.lat],
		zoom: map.getZoom(),
		pitch: map.getPitch(),
		bearing: map.getBearing(),
	};
}

function persistCamera(map: MapboxMap) {
	try {
		mapSession.camera = readCamera(map);
	} catch {
		/* map may be mid-remove */
	}
}

type PinRec = {
	key: string;
	marker: mapboxgl.Marker;
	el: HTMLElement;
	kind: "place" | "cluster";
	placeId?: string;
	amount?: number | null;
	imageUrl?: string | null;
};

/**
 * Mapbox DEM terrain (`mapbox-dem` + setTerrain) paints a city-wide diagonal
 * hatch on Safari / WebKit and freezes the canvas. 3D buildings stay.
 */
function applyBasemap(map: MapboxMap, isRTL: boolean, outdoor = false) {
	try {
		map.setConfigProperty("basemap", "lightPreset", outdoor ? "day" : "dusk");
	} catch {
		/* classic styles ignore Standard config */
	}
	try {
		map.setConfigProperty("basemap", "show3dObjects", shouldShow3dObjects());
	} catch {
		/* */
	}
	try {
		map.setConfigProperty("basemap", "showPointOfInterestLabels", false);
	} catch {
		/* Standard-only; leave classic styles untouched */
	}
	try {
		map.setConfigProperty("basemap", "showTransitLabels", false);
	} catch {
		/* */
	}
	try {
		/* Arabic map product — hide English-heavy road names that fight Farq pins. */
		map.setConfigProperty("basemap", "showRoadLabels", false);
	} catch {
		/* */
	}
	try {
		/* Standard has no `language` config key (it silently ignored the old call);
		 * labels follow the map's own language setting, which GL JS v3 exposes here. */
		map.setLanguage(isRTL ? "ar" : "en");
	} catch {
		/* classic styles without Mapbox vector sources keep local names */
	}
	if (!outdoor) {
		try {
			map.setTerrain(null);
		} catch {
			/* */
		}
	}
}

const GIS_HOODS_SOURCE = "farq-gis-hoods";
const GIS_HOODS_LAYER = "farq-gis-hoods-outline";

const EMPTY_GIS: GeoJSON.FeatureCollection = {
	type: "FeatureCollection",
	features: [],
};

/** Stroke Golden neighborhood rings only — never fill, never a mosaic. */
function applyGisOverlays(
	map: MapboxMap,
	opts: {
		neighborhoodsOn: boolean;
		neighborhoods: { type: string; features?: unknown[] } | null;
	},
) {
	const data = (
		opts.neighborhoodsOn && opts.neighborhoods?.features?.length
			? opts.neighborhoods
			: EMPTY_GIS
	) as GeoJSON.FeatureCollection;
	const src = map.getSource(GIS_HOODS_SOURCE);
	if (!src) {
		map.addSource(GIS_HOODS_SOURCE, { type: "geojson", data });
		map.addLayer({
			id: GIS_HOODS_LAYER,
			type: "line",
			source: GIS_HOODS_SOURCE,
			minzoom: 10,
			layout: {
				visibility: opts.neighborhoodsOn ? "visible" : "none",
				"line-cap": "round",
				"line-join": "round",
			},
			paint: {
				"line-color": "#8aa0a0",
				"line-width": 0.7,
				"line-opacity": 0.28,
			},
		});
		return;
	}
	if ("setData" in src && typeof src.setData === "function") {
		src.setData(data);
	}
	if (map.getLayer(GIS_HOODS_LAYER)) {
		map.setLayoutProperty(
			GIS_HOODS_LAYER,
			"visibility",
			opts.neighborhoodsOn ? "visible" : "none",
		);
	}
}

function clearPinMarkers(markers: Map<string, PinRec>) {
	for (const rec of markers.values()) {
		rec.marker.remove();
	}
	markers.clear();
}

/** Same-frame pin select — class toggle only, never remint markers. */
function applyInstantPinSelection(
	markers: Map<string, PinRec>,
	placeId: string,
	roots: Array<Element | null | undefined>,
) {
	for (const rec of markers.values()) {
		if (rec.kind !== "place") continue;
		setPinSelected(rec.el, rec.placeId === placeId);
	}
	for (const root of roots) {
		if (!(root instanceof HTMLElement)) continue;
		root.classList.add("is-pin-selected");
		root.setAttribute("data-sheet-open", "true");
	}
}

function cullPinsToViewport(
	map: MapboxMap,
	markers: Map<string, PinRec>,
	selectedPlaceId: string | undefined,
): void {
	let bounds: ReturnType<MapboxMap["getBounds"]>;
	try {
		bounds = map.getBounds();
	} catch {
		return;
	}
	if (!bounds) return;
	for (const [key, rec] of markers) {
		const keep =
			(Boolean(selectedPlaceId) && rec.placeId === selectedPlaceId) ||
			bounds.contains(rec.marker.getLngLat());
		if (keep) continue;
		rec.marker.remove();
		markers.delete(key);
	}
}

/** Rank loaded HTML auras after camera idle. Class toggles only — no refetch, no remint. */
function applyViewportAuraRanks(
	map: MapboxMap,
	markers: Map<string, PinRec>,
	selectedPlaceId: string | undefined,
	lastPulseRef: { current: { placeId: string; amount: number } | null },
	pulseTimerRef: { current: number },
	pulseDelayMs: number,
): void {
	let bounds: ReturnType<MapboxMap["getBounds"]>;
	try {
		bounds = map.getBounds();
	} catch {
		return;
	}
	if (!bounds) return;

	const visible: { placeId: string; amount: number; el: HTMLElement }[] = [];
	for (const rec of markers.values()) {
		if (rec.kind !== "place" || !rec.placeId || rec.amount == null) continue;
		const ll = rec.marker.getLngLat();
		if (!bounds.contains(ll)) {
			applyAuraRankClasses(rec.el, "visible");
			continue;
		}
		visible.push({ placeId: rec.placeId, amount: rec.amount, el: rec.el });
	}

	let maxPlaceId: string | null = null;
	let maxAmount = -1;
	let maxEl: HTMLElement | null = null;
	for (const item of visible) {
		if (item.amount > maxAmount) {
			maxAmount = item.amount;
			maxPlaceId = item.placeId;
			maxEl = item.el;
		}
	}
	for (const item of visible) {
		const isSelected =
			Boolean(selectedPlaceId) && item.placeId === selectedPlaceId;
		applyAuraRankClasses(
			item.el,
			isSelected || item.placeId === maxPlaceId ? "promoted" : "visible",
		);
	}

	const lastPulse = lastPulseRef.current;
	const maxChanged =
		maxPlaceId != null &&
		maxAmount > 0 &&
		(!lastPulse ||
			lastPulse.placeId !== maxPlaceId ||
			Math.abs(lastPulse.amount - maxAmount) >= BUBBLE_CLEAR_CHANGE);
	if (maxEl && maxPlaceId && maxChanged) {
		window.clearTimeout(pulseTimerRef.current);
		const target = maxEl;
		pulseTimerRef.current = window.setTimeout(() => {
			playMaxGapPulse(target);
		}, pulseDelayMs);
		lastPulseRef.current = { placeId: maxPlaceId, amount: maxAmount };
	}
}

export default function FarqMap({
	places,
	neighborhoods: _neighborhoods,
	selectedPlaceId,
	selectedNeighborhoodId = "",
	focusRequest = null,
	userLocation,
	userHeading = null,
	showUserLocation = false,
	placeDetail = null,
	isRTL = false,
	basemap: basemapProp,
	onSelectPlace,
	onSelectNeighborhood,
	onViewChange,
	bottomInset = 0,
	initialCamera = null,
	districts = null,
	districtLens = "gap",
	hideAddressSearch = false,
	sheetOpen = false,
	gisNeighborhoods = null,
	onMapInteraction,
	onLeftUserLocation,
	mode = "comparison",
	followMode = false,
	tracks = null,
	userTrack = null,
	vehicleMode = "dot",
	vehicleHex,
	vehicleLabel,
	vehicleNote,
	userAccuracy = null,
	onVehicleTap,
	vehicleMotion = "idle",
	outdoorLayer = "around",
	onBreakFollow,
	onMapReady,
}: {
	places: IntelligenceMapPlaces | null;
	/** Accepted for IntelligenceMapSplit compatibility — not painted as a mosaic. */
	neighborhoods: IntelligenceMapNeighborhoods | null;
	/** Golden NCP polygons stroked as line outlines when the drawer toggle is on. */
	gisNeighborhoods?: IntelligenceMapNeighborhoods | null;
	selectedPlaceId?: string;
	selectedNeighborhoodId?: string;
	/** One-shot camera move (locate click or newly selected pin). Never a live GPS/Riyadh follow. */
	focusRequest?: CameraFocusRequest | null;
	zoom?: number;
	userLocation?: { lat: number; lng: number } | null;
	/** Degrees clockwise from north when the device reports one, else null. */
	userHeading?: number | null;
	showUserLocation?: boolean;
	placeDetail?: IntelligenceMapPlaceDetail | null;
	/** Kept so a future style choice has a seam; today the map is always Standard. */
	basemap?: MapboxBasemap;
	isRTL?: boolean;
	onSelectPlace: (placeId: string) => void;
	onSelectNeighborhood: (neighborhoodId: string) => void;
	onViewChange?: (
		bbox: string,
		zoom: number,
		meta?: MapViewChangeMeta,
	) => void;
	/** Mobile Farq search already covers find — hide Mapbox address Search Box. */
	/** Height of UI covering the bottom of the map (the sheet), for camera padding. */
	bottomInset?: number;
	/** A link's camera; used once, on the first landing, instead of the city default. */
	initialCamera?: { center: [number, number]; zoom: number } | null;
	/** The city's أحياء with their counts; when present they are the field and the H3 cells stay hidden. */
	districts?: CityDistricts | null;
	/** What the district colour means: how many opportunities, or which app wins. */
	districtLens?: DistrictLens;
	hideAddressSearch?: boolean;
	sheetOpen?: boolean;
	onMapInteraction?: (phase: "start" | "end") => void;
	onLeftUserLocation?: (left: boolean) => void;
	mode?: "comparison" | "outdoor";
	followMode?: boolean;
	tracks?: GeoJSON.FeatureCollection | null;
	userTrack?: GeoJSON.FeatureCollection | null;
	vehicleMode?: "dot" | "prado";
	/** GPS accuracy of userLocation in metres: how far the car may be moved onto a street. */
	userAccuracy?: number | null;
	/** Body colour of your 3D car; defaults to the colour saved in your profile. */
	vehicleHex?: string;
	/** A name chip floated above your 3D car (shared outings: «أنت»). */
	vehicleLabel?: string;
	/** Your short line over your car («بوقف عند المحطة»). */
	vehicleNote?: string | null;
	/** Tapping your car (or its name chip). */
	onVehicleTap?: () => void;
	vehicleMotion?: "idle" | "moving";
	outdoorLayer?: OutdoorLayerId;
	onBreakFollow?: () => void;
	/** The map instance once loaded (null on unmount), for overlays drawn by the caller. */
	onMapReady?: (map: MapboxMap | null) => void;
}) {
	const token = getMapboxAccessToken();
	const containerRef = useRef<HTMLDivElement | null>(null);
	const mapRef = useRef<MapboxMap | null>(null);
	const searchRef = useRef<MapboxSearchBox | null>(null);
	const userMarkerRef = useRef<mapboxgl.Marker | null>(null);
	const [avatarVersion, setAvatarVersion] = useState(0);
	/* Read at render rather than held in state: the store is synchronous, so the
	 * first frame already has the photo and there is no swap from dot to face. */
	const userMarkerState = useCallback(
		() => ({
			avatar: loadAvatar(),
			vehicleColor: loadVehicleColor(),
			heading: normalizeHeading(userHeading),
			isRTL: isRtlRef.current,
		}),
		[userHeading, avatarVersion],
	);
	const pinMarkersRef = useRef<Map<string, PinRec>>(new Map());
	const lastPulseRef = useRef<{ placeId: string; amount: number } | null>(
		null,
	);
	const pulseTimerRef = useRef(0);
	const rankTimerRef = useRef(0);
	const introDoneRef = useRef(false);
	const lastFocusIdRef = useRef<string | null>(null);
	const onViewChangeRef = useRef(onViewChange);
	const bottomInsetRef = useRef(bottomInset);
	bottomInsetRef.current = bottomInset;
	const onSelectPlaceRef = useRef(onSelectPlace);
	const onMapInteractionRef = useRef(onMapInteraction);
	const onLeftUserLocationRef = useRef(onLeftUserLocation);
	const onBreakFollowRef = useRef(onBreakFollow);
	const userLocationRef = useRef(userLocation);
	const modeRef = useRef(mode);
	const followModeRef = useRef(followMode);
	const vehicleModeRef = useRef(vehicleMode);
	const vehicleMotionRef = useRef(vehicleMotion);
	const outdoorLayerRef = useRef(outdoorLayer);
	const tracksRef = useRef(tracks);
	const userTrackRef = useRef(userTrack);
	/* The 3D car: where it is drawn now (tweened toward each real fix) and its last real heading. */
	const vehicleShownRef = useRef<{ lng: number; lat: number } | null>(null);
	const vehicleHeadingRef = useRef<number | null>(null);
	const vehicleAnchorRef = useRef<{ lng: number; lat: number } | null>(null);
	/* Keeps our car on the same street from fix to fix (display only). */
	const roadMatcherRef = useRef(new RoadMatcher());
	const vehicleLabelRef = useRef<mapboxgl.Marker | null>(null);
	const onVehicleTapRef = useRef(onVehicleTap);
	onVehicleTapRef.current = onVehicleTap;
	const vehicleRafRef = useRef(0);
	const isRtlRef = useRef(isRTL);
	const selectedPlaceIdRef = useRef(selectedPlaceId);
	const gisNeighborhoodsRef = useRef(gisNeighborhoods);
	const lastPinSigRef = useRef("");
	const placeDetailRef = useRef(placeDetail);
	const syncPinsRef = useRef<() => void>(() => {});
	/* Standard only. Satellite imagery drowned the mint field — measured: one
	 * whole step of the opportunity ramp was ΔE ~6 against imagery whose own
	 * texture is σ 14–26 RGB — and mint over an arid city reads as vegetation. */
	const basemap = basemapProp ?? "standard";
	const appliedStyleRef = useRef<MapboxBasemap>(basemap);
	const [missingToken] = useState(() => !token);
	const [mapReady, setMapReady] = useState(false);
	const [introDone, setIntroDone] = useState(false);

	onViewChangeRef.current = onViewChange;
	onSelectPlaceRef.current = onSelectPlace;
	onMapInteractionRef.current = onMapInteraction;
	onLeftUserLocationRef.current = onLeftUserLocation;
	onBreakFollowRef.current = onBreakFollow;
	const onMapReadyRef = useRef(onMapReady);
	onMapReadyRef.current = onMapReady;
	userLocationRef.current = userLocation;
	modeRef.current = mode;
	followModeRef.current = followMode;
	vehicleModeRef.current = vehicleMode;
	vehicleMotionRef.current = vehicleMotion;
	outdoorLayerRef.current = outdoorLayer;
	tracksRef.current = tracks;
	userTrackRef.current = userTrack;
	isRtlRef.current = isRTL;
	selectedPlaceIdRef.current = selectedPlaceId;
	gisNeighborhoodsRef.current = gisNeighborhoods;
	placeDetailRef.current = placeDetail;

	const districtsRef = useRef(districts);
	districtsRef.current = districts;
	const districtLensRef = useRef(districtLens);
	districtLensRef.current = districtLens;
	const reducedMotion = usePrefersReducedMotion();
	const reducedMotionRef = useRef(reducedMotion);
	reducedMotionRef.current = reducedMotion;
	const selectedDistrictRef = useRef(selectedNeighborhoodId);
	selectedDistrictRef.current = selectedNeighborhoodId;
	const onSelectNeighborhoodRef = useRef(onSelectNeighborhood);
	onSelectNeighborhoodRef.current = onSelectNeighborhood;
	/* One HTML chip names the حي under the cursor; moved by hand, never through React state. */
	const hoverChipRef = useRef<HTMLDivElement | null>(null);

	/* One field at city zoom: the city's أحياء. */
	const syncField = (map: MapboxMap) => {
		const hoods = districtsRef.current;
		ensureDistrictLayers(map, {
			isRTL: isRtlRef.current,
			selectedId: selectedDistrictRef.current,
			lens: districtLensRef.current,
		});
		syncDistrictData(map, hoods);
		setSelectedDistrict(map, selectedDistrictRef.current);
		setDistrictLens(map, districtLensRef.current);
	};
	const syncFieldRef = useRef(syncField);
	syncFieldRef.current = syncField;
	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;
		try {
			syncFieldRef.current(map);
		} catch {
			/* style mid-swap — the style.load handler re-adds layers */
		}
	}, [districts, mapReady, basemap]);
	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;
		try {
			setSelectedDistrict(map, selectedNeighborhoodId);
		} catch {
			/* style mid-swap */
		}
	}, [selectedNeighborhoodId, mapReady]);
	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;
		try {
			setDistrictLocale(map, isRTL);
		} catch {
			/* style mid-swap */
		}
	}, [isRTL, mapReady]);
	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;
		try {
			setDistrictLens(map, districtLens);
		} catch {
			/* style mid-swap — the style.load handler reapplies */
		}
	}, [districtLens, mapReady]);

	const placesData = useMemo((): GeoJSON.FeatureCollection => {
		const features = (places?.features || []).filter((f) => {
			const coords = f.geometry?.coordinates;
			return Array.isArray(coords) && coords.length >= 2;
		});
		return {
			type: "FeatureCollection",
			features: features as GeoJSON.Feature[],
		};
	}, [places]);

	useEffect(() => {
		if (!token || !containerRef.current || mapRef.current) return;
		mapboxgl.accessToken = token;
		ensureRtlTextPlugin();

		const reduced = Boolean(
			window.matchMedia("(prefers-reduced-motion: reduce)").matches,
		);
		/* The globe intro is retired: the first useful frame is Riyadh with numbers,
		 * on every device, and the first data request no longer waits 5.6s for it. */
		const skipGlobe = true;
		void shouldSkipGlobeIntro;
		/* Flat and north-up by default. At city zoom the picture is the أحياء and
		 * their numbers; a 32° tilt foreshortens the far half of every polygon,
		 * crowds the Arabic labels into each other, and costs a phone GPU frames
		 * for a view no decision needs. Tilt stays one gesture away for anyone
		 * who wants it, and a saved camera is restored exactly as it was left. */
		const landing = initialCamera && !mapSession.introStarted
			? { center: initialCamera.center, zoom: initialCamera.zoom, pitch: 0, bearing: 0 }
			: { center: RIYADH_LNG_LAT, zoom: 12.15, pitch: 0, bearing: 0 };

		const map = new mapboxgl.Map({
			container: containerRef.current,
			style: mapboxStyleUrl(basemap),
			center: skipGlobe ? landing.center : [20, 18],
			zoom: skipGlobe ? landing.zoom : reduced ? 11.6 : 1.55,
			pitch: skipGlobe ? landing.pitch : 0,
			bearing: skipGlobe ? landing.bearing : 0,
			projection: skipGlobe ? "mercator" : "globe",
			attributionControl: { compact: true } as unknown as boolean,
			maxPitch: 75,
			accessToken: token,
			cooperativeGestures: false,
			dragPan: true,
			language: isRtlRef.current ? "ar" : "en",
		});
		mapRef.current = map;
		if (import.meta.env.DEV) {
			/* Dev-only handle for browser QA scripts (camera, layers). Never shipped. */
			(window as unknown as { __farqMap?: MapboxMap }).__farqMap = map;
		}
		try {
			map.dragPan.enable();
		} catch {
			/* */
		}
		let introTimer = 0;

		const reportView = (userGesture = false) => {
			try {
				const b = map.getBounds();
				if (!b) return;
				const bbox = `${b.getWest()},${b.getSouth()},${b.getEast()},${b.getNorth()}`;
				onViewChangeRef.current?.(bbox, map.getZoom(), { userGesture });
			} catch {
				/* */
			}
		};

		let unbindDistrictClick: () => void = () => {};
		let unbindDistrictHover: () => void = () => {};
		map.on("style.load", () => {
			applyBasemap(map, isRtlRef.current, modeRef.current === "outdoor");
			if (modeRef.current === "outdoor") {
				try {
					ensureSaryLayers(map, (id) => onSelectPlaceRef.current(id));
					setSaryTerrain(map, shouldEnableTerrain({ outdoor: true }));
					syncSaryData(map, {
						places: { type: "FeatureCollection", features: [] },
						tracks: tracksRef.current || { type: "FeatureCollection", features: [] },
						myTrack: userTrackRef.current || { type: "FeatureCollection", features: [] },
						layer: outdoorLayerRef.current,
					});
				} catch {
					/* */
				}
			}
			try {
				if (modeRef.current === "comparison") syncFieldRef.current(map);
			} catch {
				/* added again once the style settles */
			}
			if (introDoneRef.current && mapSession.camera) {
				map.jumpTo(mapSession.camera);
			}
			const hoods = gisNeighborhoodsRef.current;
			try {
				applyGisOverlays(map, {
					neighborhoodsOn: Boolean(hoods?.features?.length),
					neighborhoods: hoods,
				});
			} catch {
				/* style mid-swap */
			}
			try {
				if (modeRef.current === "comparison") {
					ensurePriceTileLayers(map, (id) => {
						applyInstantPinSelection(pinMarkersRef.current, id, [
							containerRef.current?.closest(".farq-mapbox-root"),
							containerRef.current?.closest(".farq-map-split"),
						]);
						selectedPlaceIdRef.current = id;
						onSelectPlaceRef.current(id);
						lastPinSigRef.current = "";
						syncPinsRef.current();
					});
					syncPinsRef.current();
				}
			} catch {
				/* */
			}
		});

		const applyPinPresentation = () => {
			const root = containerRef.current?.closest(".farq-mapbox-root");
			if (!(root instanceof HTMLElement)) return;
			let z = 12;
			try {
				z = map.getZoom();
			} catch {
				return;
			}
			root.dataset.pinPresentation = pinPresentationForZoom(z);
			root.dataset.pinBand = pinZoomBand(z);
			root.style.setProperty(
				"--farq-identity-reveal",
				pinIdentityReveal(z).toFixed(3),
			);
		};

		map.once("load", () => {
			const mobileChrome =
				typeof window !== "undefined" &&
				window.matchMedia("(max-width: 1023px)").matches;
			/* Zoom buttons earn nothing on a phone with pinch; they only cover the map. */
			if (!mobileChrome) {
				map.addControl(
					new mapboxgl.NavigationControl({ visualizePitch: true }),
					"bottom-right",
				);
			}
			if (!hideAddressSearch && !mobileChrome) {
				try {
					const box = createFarqSearchBox({ token, isRTL: isRtlRef.current });
					searchRef.current = box;
					map.addControl(box, "top-right");
				} catch {
					/* Search Box optional if the token lacks Search scope */
				}
			}

			try {
				applyPinPresentation();
			} catch {
				/* */
			}

			setMapReady(true);
			onMapReadyRef.current?.(map);
			try {
				/* Layer-scoped listeners survive a style swap; bind once. A tap on a
				 * cluster or a pin is theirs — the حي only takes the empty field. */
				unbindDistrictClick = bindDistrictClick(
					map,
					(id) => onSelectNeighborhoodRef.current?.(id),
					{ unlessLayers: [PRICE_TILE_CLUSTERS, PRICE_TILE_POINTS, PRICE_TILE_ICONS] },
				);
				const coarse =
					typeof window !== "undefined" && window.matchMedia?.("(pointer: coarse)").matches;
				unbindDistrictHover = bindDistrictHover(map, (hit) => {
					const el = hoverChipRef.current;
					if (!el) return;
					if (!hit || coarse) {
						el.hidden = true;
						return;
					}
					const rtl = isRtlRef.current;
					const name = rtl ? hit.name_ar : hit.name_en;
					/* This chip is HTML chrome, not a glyph drawn on the map, so it
					 * speaks the interface's numerals and carries the unit — the
					 * headline beside it says the same sentence the same way. */
					const n = (v: number) => localizeDigitString(String(v), rtl);
					const lens =
						districtLensRef.current === "app"
							? hit.cheapest_app
								? rtl
									? ` · الأرخص غالبًا: ${getProviderLabel(hit.cheapest_app, { isRTL: true }) || hit.cheapest_app}${hit.cheapest_app_share ? ` (${n(hit.cheapest_app_share)}٪)` : ""}`
									: ` · mostly cheapest: ${getProviderLabel(hit.cheapest_app, { isRTL: false }) || hit.cheapest_app}${hit.cheapest_app_share ? ` (${hit.cheapest_app_share}%)` : ""}`
								: hit.app_verdict_too_close
									? rtl
										? " · متقارب — لا فائز واضح"
										: " · too close to call"
									: rtl
										? " · مقارنات غير كافية"
										: " · not enough comparisons"
							: "";
					el.textContent =
						hit.opportunities > 0
							? rtl
								? `${name} · ${n(hit.opportunities)} فرصة${hit.max_gap ? ` · أكبرها ${n(hit.max_gap)} ر.س` : ""}${lens}`
								: `${name} · ${hit.opportunities} opportunities${hit.max_gap ? ` · biggest ${hit.max_gap} SAR` : ""}${lens}`
							: rtl
								? `${name} · لا فرص مرصودة${lens}`
								: `${name} · no observed gaps${lens}`;
					el.style.transform = `translate(${Math.round(hit.x)}px, ${Math.round(hit.y)}px)`;
					el.hidden = false;
				});
			} catch {
				/* */
			}
			try {
				if (modeRef.current === "comparison") {
					ensurePriceTileLayers(map, (id) => {
						applyInstantPinSelection(pinMarkersRef.current, id, [
							containerRef.current?.closest(".farq-mapbox-root"),
							containerRef.current?.closest(".farq-map-split"),
						]);
						selectedPlaceIdRef.current = id;
						onSelectPlaceRef.current(id);
						lastPinSigRef.current = "";
						syncPinsRef.current();
					});
				}
			} catch {
				/* style not ready */
			}

			const landQuietly = (camera: PersistedCamera) => {
				try {
					map.setProjection("mercator");
				} catch {
					/* */
				}
				map.jumpTo({ ...camera, pitch: Math.min(camera.pitch, 36) });
				introDoneRef.current = true;
				mapSession.introStarted = true;
				persistCamera(map);
				setIntroDone(true);
				reportView();
			};

			if (mapSession.introStarted && mapSession.camera) {
				landQuietly(mapSession.camera);
			} else if (mapSession.introStarted) {
				landQuietly({
					center: RIYADH_LNG_LAT,
					zoom: 12.15,
					pitch: 0,
					bearing: 0,
				});
			} else if (skipGlobe) {
				mapSession.introStarted = true;
				map.jumpTo(landing);
				try {
					map.setProjection("mercator");
				} catch {
					/* */
				}
				introDoneRef.current = true;
				persistCamera(map);
				setIntroDone(true);
				reportView();
			} else {
				mapSession.introStarted = true;
				map.flyTo({
					center: RIYADH_LNG_LAT,
					zoom: 12.15,
					pitch: 32,
					bearing: -12,
					duration: INTRO_MS,
					essential: true,
					curve: 1.55,
					speed: 0.55,
				});
				introTimer = window.setTimeout(() => {
					if (mapRef.current !== map) return;
					try {
						map.setProjection("mercator");
					} catch {
						/* globe intro only */
					}
					introDoneRef.current = true;
					persistCamera(map);
					setIntroDone(true);
					reportView();
				}, INTRO_MS + 120);
			}
		});

		let zoomRaf = 0;
		const onZoomFrame = () => {
			zoomRaf = 0;
			applyPinPresentation();
		};
		map.on("zoom", () => {
			if (zoomRaf) return;
			zoomRaf = window.requestAnimationFrame(onZoomFrame);
		});

		const stopProgrammaticCamera = () => {
			if (!introDoneRef.current) return;
			try {
				map.stop();
			} catch {
				/* leftover flyTo/easeTo only — user drag has not started */
			}
		};
		const canvasHost = map.getCanvasContainer();
		canvasHost.addEventListener("pointerdown", stopProgrammaticCamera, true);
		let userGesture = false;
		const markUserGesture = (ev: unknown) => {
			if (
				ev &&
				typeof ev === "object" &&
				"originalEvent" in ev &&
				(ev as { originalEvent?: Event }).originalEvent
			) {
				userGesture = true;
			}
		};
		const isUserEvent = (ev: unknown) =>
			Boolean(
				ev &&
					typeof ev === "object" &&
					"originalEvent" in ev &&
					(ev as { originalEvent?: Event }).originalEvent,
			);
		const onInteractStart = (ev: unknown) => {
			markUserGesture(ev);
			if (!introDoneRef.current) return;
			/* Only a finger or a wheel is an interaction; our own easeTo must not collapse the sheet. */
			if (!isUserEvent(ev)) return;
			if (followModeRef.current) onBreakFollowRef.current?.();
			onMapInteractionRef.current?.("start");
		};
		const onInteractEnd = () => {
			if (!introDoneRef.current) return;
			onMapInteractionRef.current?.("end");
		};
		map.on("dragstart", onInteractStart);
		map.on("zoomstart", onInteractStart);
		map.on("rotatestart", onInteractStart);
		map.on("pitchstart", onInteractStart);
		map.on("dragend", onInteractEnd);
		map.on("zoomend", () => {
			onInteractEnd();
			syncPinsRef.current();
		});
		map.on("rotateend", onInteractEnd);
		map.on("pitchend", onInteractEnd);

		map.on("moveend", () => {
			if (!introDoneRef.current) return;
			const wasUser = userGesture;
			userGesture = false;
			persistCamera(map);
			reportView(wasUser);
			try {
				onLeftUserLocationRef.current?.(
					leftUserDot(map.getCenter(), userLocationRef.current),
				);
			} catch {
				/* */
			}
			applyPinPresentation();
			cullPinsToViewport(map, pinMarkersRef.current, selectedPlaceIdRef.current);
			window.clearTimeout(rankTimerRef.current);
			rankTimerRef.current = window.setTimeout(() => {
				applyViewportAuraRanks(
					map,
					pinMarkersRef.current,
					selectedPlaceIdRef.current,
					lastPulseRef,
					pulseTimerRef,
					0,
				);
			}, AURA_VIEWPORT_IDLE_MS);
		});

		const ro = new ResizeObserver(() => {
			try {
				map.resize();
			} catch {
				/* */
			}
		});
		ro.observe(containerRef.current);

		return () => {
			window.clearTimeout(introTimer);
			window.clearTimeout(pulseTimerRef.current);
			window.clearTimeout(rankTimerRef.current);
			if (zoomRaf) window.cancelAnimationFrame(zoomRaf);
			canvasHost.removeEventListener("pointerdown", stopProgrammaticCamera, true);
			unbindDistrictClick();
			unbindDistrictHover();
			persistCamera(map);
			ro.disconnect();
			userMarkerRef.current?.remove();
			cancelAnimationFrame(vehicleRafRef.current);
			clearPinMarkers(pinMarkersRef.current);
			searchRef.current = null;
			setMapReady(false);
			setIntroDone(false);
			onMapReadyRef.current?.(null);
			map.remove();
			mapRef.current = null;
		};
		// Mount once — data syncs in later effects.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [token]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;

		const syncPins = () => {
			if (mapRef.current !== map) return;
			if (modeRef.current === "outdoor") return;
			let zoom = 12;
			try {
				zoom = map.getZoom();
			} catch {
				return;
			}
			const selectedId = String(selectedPlaceIdRef.current || "").trim();
			try {
				syncPriceTileData(map, placesData, zoom, selectedId);
			} catch {
				/* */
			}

			const selectedFeature = selectedId
				? placesData.features.find((feature) => {
						const placeId = String(
							(feature.properties as { place_id?: string } | null)
								?.place_id || "",
						).trim();
						return placeId === selectedId && feature.geometry.type === "Point";
					})
				: undefined;

			for (const [key, rec] of pinMarkersRef.current) {
				if (selectedId && rec.placeId === selectedId && selectedFeature) continue;
				rec.marker.remove();
				pinMarkersRef.current.delete(key);
			}

			if (!selectedFeature || selectedFeature.geometry.type !== "Point") {
				lastPinSigRef.current = selectedId;
				return;
			}

			const key = featureMarkerKey(selectedFeature) || `place:${selectedId}`;
			const coords = selectedFeature.geometry.coordinates as [number, number];
			const props = (selectedFeature.properties || {}) as {
				place_id?: string;
				name?: string;
				difference?: unknown;
				gap?: unknown;
				cheapest_provider_id?: unknown;
				provider_count?: number | null;
				image_url?: string | null;
			};
			const difference =
				differenceFromPinProps(props) ||
				differenceFromPinProps(placeDetailRef.current);
			const amount =
				observedDifferenceAmount(difference) ??
				observedDifferenceAmount({
					difference_amount: Number(props.gap),
				});
			const imageUrl =
				placeDetailRef.current?.image_url || props.image_url || null;
			const existing = pinMarkersRef.current.get(key);
			if (existing) {
				updatePlacePinChip(existing.el, amount);
				setPinSelected(existing.el, true);
				if (imageUrl) syncPinPhoto(existing.el, imageUrl);
				existing.marker.setLngLat(coords);
				existing.amount = amount;
				existing.imageUrl = imageUrl;
				lastPinSigRef.current = key;
				return;
			}

			const el = buildPlacePinElement({
				name:
					String(placeDetailRef.current?.name || props.name || ""),
				difference,
				providerCount:
					placeDetailRef.current?.provider_count ?? props.provider_count,
				selected: true,
				isRTL: isRtlRef.current,
				imageUrl,
				includePhoto: true,
				quiet: false,
			});
			el.addEventListener("pointerdown", (ev) => ev.stopPropagation());
			el.addEventListener("click", (ev) => {
				ev.stopPropagation();
				applyInstantPinSelection(pinMarkersRef.current, selectedId, [
					containerRef.current?.closest(".farq-mapbox-root"),
					containerRef.current?.closest(".farq-map-split"),
				]);
				selectedPlaceIdRef.current = selectedId;
				onSelectPlaceRef.current(selectedId);
			});
			const marker = new mapboxgl.Marker({
				element: el,
				anchor: "bottom",
			})
				.setLngLat(coords)
				.addTo(map);
			pinMarkersRef.current.set(key, {
				key,
				marker,
				el,
				kind: "place",
				placeId: selectedId,
				amount,
				imageUrl,
			});
			if (amount != null) playBubbleEnter(el, 0);
			applyViewportAuraRanks(
				map,
				pinMarkersRef.current,
				selectedId,
				lastPulseRef,
				pulseTimerRef,
				BUBBLE_ENTER_MS,
			);
			lastPinSigRef.current = key;
		};

		syncPinsRef.current = syncPins;
		syncPins();
	}, [placesData, mapReady, placeDetail]);

	useEffect(() => {
		const root = containerRef.current?.closest(".farq-mapbox-root");
		if (root instanceof HTMLElement) {
			root.classList.toggle("is-pin-selected", Boolean(selectedPlaceId));
			if (selectedPlaceId) root.setAttribute("data-sheet-open", "true");
			else root.removeAttribute("data-sheet-open");
		}
		for (const rec of pinMarkersRef.current.values()) {
			if (rec.kind !== "place") continue;
			setPinSelected(
				rec.el,
				Boolean(selectedPlaceId) && rec.placeId === selectedPlaceId,
			);
		}
		lastPinSigRef.current = "";
		syncPinsRef.current();
	}, [selectedPlaceId]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;
		if (mode !== "outdoor") return;
		try {
			ensureSaryLayers(map, (id) => onSelectPlaceRef.current(id));
			syncSaryData(map, {
				places: placesData,
				tracks: tracks || { type: "FeatureCollection", features: [] },
				myTrack: userTrack || { type: "FeatureCollection", features: [] },
				layer: outdoorLayer,
			});
		} catch {
			/* style mid-swap */
		}
	}, [mode, mapReady, placesData, tracks, userTrack, outdoorLayer]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !introDone || !followMode || !userLocation) return;
		try {
			map.easeTo({
				center: [userLocation.lng, userLocation.lat],
				duration: reducedMotionRef.current ? 0 : 420,
				essential: true,
				/* Following the 3D car: tilt enough that it reads as a car, not a roof. */
				pitch: vehicleModeRef.current === "prado" ? Math.max(map.getPitch(), 50) : map.getPitch(),
				bearing: typeof userHeading === "number" ? userHeading : map.getBearing(),
			});
		} catch {
			/* */
		}
	}, [followMode, userLocation, userHeading, introDone]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !introDoneRef.current) return;
		const car3d = vehicleMode === "prado" && showUserLocation && userLocation ? ensureVehicleLayer(map, vehicleHex || vehicleColorHex(loadVehicleColor())) : null;
		/* The name chip rides with the car; without a car or a label there is none. */
		if (car3d && vehicleLabel) {
			if (!vehicleLabelRef.current) {
				const el = document.createElement("button");
				el.type = "button";
				el.className = "sary-peer is-car is-me";
				el.dataset.testid = "sary-my-car";
				el.innerHTML = `<span class="sary-peer__note" hidden></span><span class="sary-peer__name"><i class="sary-peer__dot" aria-hidden="true"></i><b></b></span>`;
				el.addEventListener("click", (e) => {
					e.stopPropagation();
					onVehicleTapRef.current?.();
				});
				vehicleLabelRef.current = new mapboxgl.Marker({ element: el, anchor: "bottom", offset: [0, -22] });
				/* The car itself is tappable too. */
				map.on("click", VEHICLE_LAYER, () => onVehicleTapRef.current?.());
			}
			const el = vehicleLabelRef.current.getElement();
			el.style.setProperty("--peer-color", vehicleHex || vehicleColorHex(loadVehicleColor()));
			el.querySelector("b")!.textContent = vehicleLabel;
			(el.querySelector(".sary-peer__name") as HTMLElement).dir = isRTL ? "rtl" : "ltr";
			const note = el.querySelector(".sary-peer__note") as HTMLElement;
			note.hidden = !vehicleNote;
			note.textContent = vehicleNote || "";
			note.dir = isRTL ? "rtl" : "ltr";
			el.setAttribute("aria-label", vehicleNote ? `${vehicleLabel}: ${vehicleNote}` : vehicleLabel);
			vehicleLabelRef.current.setLngLat(vehicleShownRef.current || userLocation!).addTo(map);
		} else {
			vehicleLabelRef.current?.remove();
		}
		/* Observable state for QA scripts: which vehicle the map is drawing. */
		map.getContainer().dataset.vehicle = car3d === null ? "none" : car3d ? "model" : "fallback";
		if (car3d && userLocation) {
			userMarkerRef.current?.remove();
			userMarkerRef.current = null;
			/* Keep the last real heading while parked; never invent one. */
			/* The course of this fix, if it has one: reported, or from real movement. */
			let course: number | null = null;
			if (typeof userHeading === "number" && Number.isFinite(userHeading)) {
				vehicleHeadingRef.current = userHeading;
				course = userHeading;
				vehicleAnchorRef.current = { lng: userLocation.lng, lat: userLocation.lat };
			} else {
				/* Some phones report no course. Take it from real movement instead:
				 * two real fixes far enough apart that GPS jitter cannot fake it. */
				const a = vehicleAnchorRef.current;
				if (!a) vehicleAnchorRef.current = { lng: userLocation.lng, lat: userLocation.lat };
				else if (distanceMeters(a, userLocation) >= 12) {
					vehicleHeadingRef.current = bearingBetween(a, userLocation);
					course = vehicleHeadingRef.current;
					vehicleAnchorRef.current = { lng: userLocation.lng, lat: userLocation.lat };
				}
			}
			const from = vehicleShownRef.current;
			/* In town, on the street it is driving along rather than inside the house beside it. */
			const matched = matchOnMap(map, roadMatcherRef.current, { lng: userLocation.lng, lat: userLocation.lat }, course, snapRadius(userAccuracy));
			const to = matched.point;
			/* Moving along a matched road: point the car down the road, not a few degrees into the kerb. */
			if (course != null && matched.heading != null) vehicleHeadingRef.current = matched.heading;
			map.getContainer().dataset.road = matched.key ?? "";
			cancelAnimationFrame(vehicleRafRef.current);
			if (!from || reducedMotionRef.current) {
				vehicleShownRef.current = to;
				setVehicle(map, to, vehicleHeadingRef.current);
				vehicleLabelRef.current?.setLngLat(to);
			} else {
				/* Glide to the new real fix over under a second; never past it. */
				const start = performance.now();
				const step = () => {
					const t = Math.min(1, (performance.now() - start) / 800);
					const p = lerp(from, to, t);
					vehicleShownRef.current = p;
					try {
						setVehicle(map, p, vehicleHeadingRef.current);
						vehicleLabelRef.current?.setLngLat(p);
					} catch {
						return;
					}
					if (t < 1) vehicleRafRef.current = requestAnimationFrame(step);
				};
				vehicleRafRef.current = requestAnimationFrame(step);
			}
			return;
		}
		cancelAnimationFrame(vehicleRafRef.current);
		vehicleShownRef.current = null;
		try {
			removeVehicle(map);
		} catch {
			/* */
		}
		if (!showUserLocation || !userLocation) {
			userMarkerRef.current?.remove();
			userMarkerRef.current = null;
			return;
		}
		if (!userMarkerRef.current) {
			userMarkerRef.current = new mapboxgl.Marker({
				element: buildUserMarker(userMarkerState()),
			})
				.setLngLat([userLocation.lng, userLocation.lat])
				.addTo(map);
		} else {
			updateUserMarker(userMarkerRef.current.getElement(), userMarkerState());
			userMarkerRef.current.setLngLat([userLocation.lng, userLocation.lat]);
		}
	}, [
		showUserLocation,
		userLocation,
		userHeading,
		userMarkerState,
		avatarVersion,
		vehicleMode,
		vehicleMotion,
		vehicleHex,
		vehicleLabel,
		vehicleNote,
		isRTL,
	]);

	/* The photo lives in this browser and is changed from a control elsewhere in
	 * the tree, so the marker listens rather than being handed it. */
	useEffect(() => {
		const onChange = () => setAvatarVersion((v) => v + 1);
		window.addEventListener(AVATAR_CHANGED, onChange);
		return () => window.removeEventListener(AVATAR_CHANGED, onChange);
	}, []);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !introDone || !focusRequest) return;
		if (lastFocusIdRef.current === focusRequest.id) return;
		lastFocusIdRef.current = focusRequest.id;
		/* Reduced motion means arrive, not travel: the same camera, no journey. */
		const travel = (ms: number) => (reducedMotionRef.current ? 0 : ms);
		if (focusRequest.bounds) {
			const [w, s, e, n] = focusRequest.bounds;
			const pad = cameraPadding("select", bottomInsetRef.current);
			map.fitBounds([[w, s], [e, n]], {
				padding: { top: Math.max(pad.top, focusRequest.topInset ?? 0), bottom: pad.bottom, left: pad.left + 16, right: pad.right + 16 },
				duration: travel(900),
				maxZoom: focusRequest.maxZoom ?? 15.5,
				essential: true,
			});
			return;
		}
		map.easeTo({
			center: [focusRequest.lng, focusRequest.lat],
			duration: travel(
				focusRequest.kind === "select"
					? 880
					: focusRequest.kind === "locate"
						? 820
						: 740,
			),
			essential: true,
			easing: (t) => 1 - (1 - t) ** 3,
			padding: cameraPadding(focusRequest.kind, bottomInsetRef.current),
			pitch: map.getPitch(),
			...(typeof focusRequest.zoom === "number"
				? { zoom: focusRequest.zoom }
				: {}),
		});
	}, [focusRequest, introDone]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map) return;
		if (appliedStyleRef.current === basemap) return;
		persistCamera(map);
		appliedStyleRef.current = basemap;
		map.setStyle(mapboxStyleUrl(basemap));
	}, [basemap]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;
		try {
			applyGisOverlays(map, {
				neighborhoodsOn: Boolean(gisNeighborhoods?.features?.length),
				neighborhoods: gisNeighborhoods,
			});
		} catch {
			/* style mid-swap — style.load reapplies */
		}
	}, [gisNeighborhoods, mapReady]);

	if (missingToken) {
		return (
			<div
				className="flex h-full flex-col items-center justify-center bg-neutral-900 px-6 text-center text-sm text-white/80"
				data-testid="intelligence-map-canvas"
			>
				{isRTL
					? "تعذّر تحميل الخريطة الآن. أعد المحاولة بعد قليل."
					: "The map could not load right now. Try again shortly."}
				{import.meta.env.DEV ? (
					<span className="mt-2 block text-xs opacity-70" dir="ltr">
						dev: set VITE_MAPBOX_ACCESS_TOKEN in .env.local at the repo root, then restart Vite.
					</span>
				) : null}
			</div>
		);
	}

	return (
		<div
			className="farq-mapbox-root relative h-full w-full"
			dir="ltr"
			data-testid="intelligence-map-canvas"
			data-sheet-open={sheetOpen ? "true" : undefined}
			data-hide-address-search={hideAddressSearch ? "true" : undefined}
		>
			<div ref={containerRef} className="absolute inset-0 h-full w-full" />
			<div
				ref={hoverChipRef}
				hidden
				className="farq-district-hover-chip"
				dir="auto"
				aria-hidden
				data-testid="intelligence-map-district-hover"
			/>
		</div>
	);
}
