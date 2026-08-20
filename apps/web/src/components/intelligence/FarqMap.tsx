/**
 * Farq difference map — Mapbox GL Standard, comparison-row coords.
 * Neighborhood polygons are never a choropleth mosaic. An optional line-outline
 * toggle (Golden NCP, default off) may stroke rings — no fill.
 * Never invents pins, never remints place_id, never fakes GPS.
 * App logo is the pin hero. The price chip is always smaller.
 * GPU symbols at every zoom for unselected places. One HTML pin = selected.
 * Pin tap selects the place — no Mapbox infowindow; the split sheet owns the moment.
 * Bubbles are overlay-only: this file must not restyle 3D buildings, terrain,
 * camera, zoom, or the Standard/Satellite basemap.
 */
import type { MapboxSearchBox } from "@mapbox/search-js-web";
import mapboxgl, { type Map as MapboxMap } from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useMemo, useRef, useState } from "react";
import {
	shouldShow3dObjects,
	shouldSkipGlobeIntro,
} from "../../lib/farqMapDevice";
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
import { ensureAreaLayers, syncAreaData } from "../../lib/farqAreaTiles";
import type { CityAreas } from "../../services/intelligenceService";
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
function applyBasemap(map: MapboxMap, isRTL: boolean) {
	try {
		map.setConfigProperty("basemap", "lightPreset", "dusk");
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
	try {
		map.setTerrain(null);
	} catch {
		/* */
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
	selectedNeighborhoodId: _selectedNeighborhoodId,
	focusRequest = null,
	userLocation,
	showUserLocation = false,
	placeDetail = null,
	isRTL = false,
	basemap: basemapProp,
	onBasemapChange,
	onSelectPlace,
	onSelectNeighborhood: _onSelectNeighborhood,
	onViewChange,
	bottomInset = 0,
	initialCamera = null,
	areas = null,
	hideAddressSearch = false,
	sheetOpen = false,
	gisNeighborhoods = null,
	onMapInteraction,
	onLeftUserLocation,
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
	showUserLocation?: boolean;
	placeDetail?: IntelligenceMapPlaceDetail | null;
	basemap?: MapboxBasemap;
	onBasemapChange?: (kind: MapboxBasemap) => void;
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
	/** H3 cells for the city zoom — the opportunity field under the clusters. */
	areas?: CityAreas | null;
	hideAddressSearch?: boolean;
	sheetOpen?: boolean;
	onMapInteraction?: (phase: "start" | "end") => void;
	onLeftUserLocation?: (left: boolean) => void;
}) {
	const token = getMapboxAccessToken();
	const containerRef = useRef<HTMLDivElement | null>(null);
	const mapRef = useRef<MapboxMap | null>(null);
	const searchRef = useRef<MapboxSearchBox | null>(null);
	const userMarkerRef = useRef<mapboxgl.Marker | null>(null);
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
	const userLocationRef = useRef(userLocation);
	const isRtlRef = useRef(isRTL);
	const selectedPlaceIdRef = useRef(selectedPlaceId);
	const gisNeighborhoodsRef = useRef(gisNeighborhoods);
	const appliedStyleRef = useRef<MapboxBasemap>("standard");
	const lastPinSigRef = useRef("");
	const placeDetailRef = useRef(placeDetail);
	const syncPinsRef = useRef<() => void>(() => {});
	const [internalBasemap, setInternalBasemap] =
		useState<MapboxBasemap>("standard");
	const basemap = basemapProp ?? internalBasemap;
	const setBasemap = (next: MapboxBasemap) => {
		onBasemapChange?.(next);
		if (basemapProp === undefined) setInternalBasemap(next);
	};
	const [missingToken] = useState(() => !token);
	const [mapReady, setMapReady] = useState(false);
	const [introDone, setIntroDone] = useState(false);

	onViewChangeRef.current = onViewChange;
	onSelectPlaceRef.current = onSelectPlace;
	onMapInteractionRef.current = onMapInteraction;
	onLeftUserLocationRef.current = onLeftUserLocation;
	userLocationRef.current = userLocation;
	isRtlRef.current = isRTL;
	selectedPlaceIdRef.current = selectedPlaceId;
	gisNeighborhoodsRef.current = gisNeighborhoods;
	placeDetailRef.current = placeDetail;

	const areasRef = useRef(areas);
	areasRef.current = areas;
	useEffect(() => {
		const map = mapRef.current;
		if (!map || !mapReady) return;
		try {
			ensureAreaLayers(map);
			syncAreaData(map, areas);
		} catch {
			/* style mid-swap — the style.load handler re-adds layers */
		}
	}, [areas, mapReady, basemap]);

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
		const landing = initialCamera && !mapSession.introStarted
			? { center: initialCamera.center, zoom: initialCamera.zoom, pitch: 0, bearing: 0 }
			: { center: RIYADH_LNG_LAT, zoom: 12.15, pitch: 32, bearing: -12 };

		const map = new mapboxgl.Map({
			container: containerRef.current,
			style: mapboxStyleUrl("standard"),
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

		map.on("style.load", () => {
			applyBasemap(map, isRtlRef.current);
			try {
				ensureAreaLayers(map);
				syncAreaData(map, areasRef.current);
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
			try {
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
					pitch: 32,
					bearing: -12,
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
			persistCamera(map);
			ro.disconnect();
			userMarkerRef.current?.remove();
			clearPinMarkers(pinMarkersRef.current);
			searchRef.current = null;
			setMapReady(false);
			setIntroDone(false);
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
		if (!map || !introDoneRef.current) return;
		if (!showUserLocation || !userLocation) {
			userMarkerRef.current?.remove();
			userMarkerRef.current = null;
			return;
		}
		if (!userMarkerRef.current) {
			const el = document.createElement("div");
			el.className = "farq-user-pulse";
			el.dataset.testid = "farq-map-user-pulse";
			const ringA = document.createElement("span");
			ringA.className = "farq-user-pulse-ring";
			const ringB = document.createElement("span");
			ringB.className = "farq-user-pulse-ring farq-user-pulse-ring--delay";
			const core = document.createElement("span");
			core.className = "farq-user-pulse-core";
			core.setAttribute("aria-hidden", "true");
			const label = document.createElement("span");
			label.className = "farq-user-here";
			label.textContent = isRtlRef.current ? "أنت هنا" : "You are here";
			el.append(ringA, ringB, core, label);
			userMarkerRef.current = new mapboxgl.Marker({ element: el })
				.setLngLat([userLocation.lng, userLocation.lat])
				.addTo(map);
		} else {
			const label = userMarkerRef.current.getElement().querySelector(".farq-user-here");
			if (label) {
				label.textContent = isRtlRef.current ? "أنت هنا" : "You are here";
			}
			userMarkerRef.current.setLngLat([userLocation.lng, userLocation.lat]);
		}
	}, [showUserLocation, userLocation]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !introDone || !focusRequest) return;
		if (lastFocusIdRef.current === focusRequest.id) return;
		lastFocusIdRef.current = focusRequest.id;
		if (focusRequest.bounds) {
			const [w, s, e, n] = focusRequest.bounds;
			const pad = cameraPadding("select", bottomInsetRef.current);
			map.fitBounds([[w, s], [e, n]], {
				padding: { top: pad.top, bottom: pad.bottom, left: pad.left + 16, right: pad.right + 16 },
				duration: 900,
				maxZoom: 15.5,
				essential: true,
			});
			return;
		}
		map.easeTo({
			center: [focusRequest.lng, focusRequest.lat],
			duration:
				focusRequest.kind === "select"
					? 880
					: focusRequest.kind === "locate"
						? 820
						: 740,
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
				className="flex h-full items-center justify-center bg-neutral-900 px-6 text-center text-sm text-white/80"
				data-testid="intelligence-map-canvas"
			>
				{isRTL
					? "أضف VITE_MAPBOX_ACCESS_TOKEN في Frontend/.env.local ثم أعد تشغيل Vite."
					: "Add VITE_MAPBOX_ACCESS_TOKEN to Frontend/.env.local and restart Vite."}
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
			{onBasemapChange ? null : (
				<div className="absolute bottom-3 end-3 z-[20] flex overflow-hidden rounded-lg bg-[#e6eef0] p-0.5 text-[11px] font-bold">
					<button
						type="button"
						data-testid="farq-map-style-satellite"
						className={`rounded-md px-2.5 py-1 ${basemap === "satellite" ? "bg-brand-900 text-mint-500" : "text-[#6b7c7c]"}`}
						onClick={() => setBasemap("satellite")}
					>
						{isRTL ? "قمر صناعي" : "Satellite"}
					</button>
					<button
						type="button"
						data-testid="farq-map-style-standard"
						className={`rounded-md px-2.5 py-1 ${basemap === "standard" ? "bg-brand-900 text-mint-500" : "text-[#6b7c7c]"}`}
						onClick={() => setBasemap("standard")}
					>
						{isRTL ? "خريطة" : "Map"}
					</button>
				</div>
			)}
		</div>
	);
}
