import type { MapboxSearchBox } from "@mapbox/search-js-web";
import mapboxgl, { type Map as MapboxMap } from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useMemo, useRef, useState } from "react";
import {
	AURA_VIEWPORT_IDLE_MS,
	BUBBLE_CLEAR_CHANGE,
	BUBBLE_ENTER_MS,
	BUBBLE_ENTER_STAGGER_MAX,
	applyAuraRankClasses,
	auraPromoteCap,
	buildClusterPinElement,
	buildPlacePinElement,
	featureMarkerKey,
	observedClusterTopGap,
	observedDifferenceAmount,
	observedRestaurantImageUrl,
	pinPresentationForZoom,
	playBubbleEnter,
	playMaxGapPulse,
	promotedAuraLimit,
	rankAuraPlaceIds,
	setPinSelected,
	shouldReplayBubbleMotion,
} from "../../lib/farqMapPins";
import { applyMapLanguage, ensureRtlTextPlugin, getMapboxAccessToken, type MapboxBasemap, mapboxStyleUrl, RIYADH_LNG_LAT } from "../../lib/mapboxAccess";
import { createFarqSearchBox } from "../../lib/mapboxSearch";
import type { IntelligenceMapNeighborhoods, IntelligenceMapPlaceDetail, IntelligenceMapPlaces } from "../../services/intelligenceService";
import type { MapZoomMode } from "../../lib/mapExploration";
import "../../styles/farq-mapbox.css";

const INTRO_MS = 5600;
const FARQ_CLUSTERS = "farq-clusters";
const HOOD_SHAPES = "farq-hood-shapes";
const HOOD_LABELS = "farq-hood-labels";
const HOOD_FILL = "farq-hood-fill";
const HOOD_LINE = "farq-hood-line";
const HOOD_COUNT = "farq-hood-count";
const EMPTY_FC: GeoJSON.FeatureCollection = { type: "FeatureCollection", features: [] };

/** Neighbourhood choropleth: the count decides the tint, so a busy حي reads
 *  first without any colour competing with an opportunity pin. */
function ensureHoodLayers(map: MapboxMap) {
	try {
		if (!map.getSource(HOOD_SHAPES)) map.addSource(HOOD_SHAPES, { type: "geojson", data: EMPTY_FC });
		if (!map.getSource(HOOD_LABELS)) map.addSource(HOOD_LABELS, { type: "geojson", data: EMPTY_FC });
		if (!map.getLayer(HOOD_FILL)) map.addLayer({
			id: HOOD_FILL, type: "fill", source: HOOD_SHAPES, slot: "middle", maxzoom: 15,
			paint: {
				"fill-color": ["interpolate", ["linear"], ["coalesce", ["get", "count"], 0], 0, "#0B2F26", 5, "#155C43", 20, "#1E8A5F", 60, "#2FB877"],
				"fill-opacity": ["interpolate", ["linear"], ["zoom"], 9, 0.3, 13, 0.24, 15, 0],
			},
		} as never);
		if (!map.getLayer(HOOD_LINE)) map.addLayer({
			id: HOOD_LINE, type: "line", source: HOOD_SHAPES, slot: "middle", maxzoom: 15,
			paint: { "line-color": "#83F1B1", "line-width": 1, "line-opacity": ["interpolate", ["linear"], ["zoom"], 9, 0.35, 13, 0.5, 15, 0] },
		} as never);
		if (!map.getLayer(HOOD_COUNT)) map.addLayer({
			id: HOOD_COUNT, type: "symbol", source: HOOD_LABELS, maxzoom: 15,
			layout: {
				"text-field": ["get", "label"],
				"text-font": ["DIN Pro Medium", "Arial Unicode MS Regular"],
				"text-size": ["interpolate", ["linear"], ["zoom"], 9, 11, 13, 14],
				"text-line-height": 1.25,
				"symbol-sort-key": ["-", 0, ["coalesce", ["get", "count"], 0]],
			},
			paint: { "text-color": "#EAF7F0", "text-halo-color": "#04211C", "text-halo-width": 1.4, "text-halo-blur": 0.4 },
		} as never);
	} catch {
		/* a failure here must not take the map down with it */
	}
}
function setHoodData(map: MapboxMap, shapes: GeoJSON.FeatureCollection, labels: GeoJSON.FeatureCollection) {
	try {
		(map.getSource(HOOD_SHAPES) as mapboxgl.GeoJSONSource | undefined)?.setData(shapes);
		(map.getSource(HOOD_LABELS) as mapboxgl.GeoJSONSource | undefined)?.setData(labels);
	} catch {
		/* sources arrive with the style */
	}
}

/** `zoom` asks the camera to close in on the place, not just centre it. */
type CameraFocusRequest = { lat: number; lng: number; id: string; zoom?: number };
type PersistedCamera = { center: [number, number]; zoom: number; pitch: number; bearing: number };
const mapSession = { introStarted: false, camera: null as PersistedCamera | null };
function readCamera(map: MapboxMap): PersistedCamera { const c = map.getCenter(); return { center: [c.lng, c.lat], zoom: map.getZoom(), pitch: map.getPitch(), bearing: map.getBearing() }; }
function persistCamera(map: MapboxMap) { try { mapSession.camera = readCamera(map); } catch {} }
type PinRec = { key: string; marker: mapboxgl.Marker; el: HTMLElement; kind: "place" | "cluster"; placeId?: string; amount?: number | null };
function clearPinMarkers(markers: Map<string, PinRec>) { for (const rec of markers.values()) rec.marker.remove(); markers.clear(); }
/** Pins are sized by this attribute. Set it before the first pin exists, or they
 *  render at the wrong size until the user happens to move the map. */
function syncPinPresentation(container: HTMLElement | null, map: MapboxMap) {
	const root = container?.closest(".farq-mapbox-root");
	if (root instanceof HTMLElement) root.dataset.pinPresentation = pinPresentationForZoom(map.getZoom());
}
function applyBasemap(map: MapboxMap, isRTL: boolean) {
	try { map.setConfigProperty("basemap", "lightPreset", "dusk"); } catch {}
	try { map.setConfigProperty("basemap", "show3dObjects", true); } catch {}
	applyMapLanguage(map, isRTL);
	ensureHoodLayers(map);
	try { if (!map.getSource("mapbox-dem")) map.addSource("mapbox-dem", { type: "raster-dem", url: "mapbox://mapbox.mapbox-terrain-dem-v1", tileSize: 512, maxzoom: 14 }); map.setTerrain({ source: "mapbox-dem", exaggeration: 1.15 }); } catch {}
}
function applyViewportAuraRanks(map: MapboxMap, markers: Map<string, PinRec>, selectedPlaceId: string | undefined, lastPulseRef: { current: { placeId: string; amount: number } | null }, pulseTimerRef: { current: number }, pulseDelayMs: number) {
	let bounds: ReturnType<MapboxMap["getBounds"]>; try { bounds = map.getBounds(); } catch { return; } if (!bounds) return;
	const visible: { placeId: string; amount: number; el: HTMLElement }[] = [];
	for (const rec of markers.values()) { if (rec.kind !== "place" || !rec.placeId || rec.amount == null) continue; const ll = rec.marker.getLngLat(); if (!bounds.contains(ll)) { applyAuraRankClasses(rec.el, "demoted"); continue; } visible.push({ placeId: rec.placeId, amount: rec.amount, el: rec.el }); }
	const isMobile = typeof window !== "undefined" && window.matchMedia("(max-width: 1023px)").matches;
	const promoted = rankAuraPlaceIds(visible, promotedAuraLimit(visible.length, auraPromoteCap(isMobile)));
	let maxPlaceId: string | null = null; let maxAmount = -1; let maxEl: HTMLElement | null = null;
	for (const item of visible) { const selected = Boolean(selectedPlaceId) && item.placeId === selectedPlaceId; applyAuraRankClasses(item.el, selected || promoted.has(item.placeId) ? "promoted" : "demoted"); if (item.amount > maxAmount) { maxAmount = item.amount; maxPlaceId = item.placeId; maxEl = item.el; } }
	const last = lastPulseRef.current; const changed = maxPlaceId != null && maxAmount > 0 && (!last || last.placeId !== maxPlaceId || Math.abs(last.amount - maxAmount) >= BUBBLE_CLEAR_CHANGE);
	if (maxEl && maxPlaceId && changed) { window.clearTimeout(pulseTimerRef.current); const target = maxEl; pulseTimerRef.current = window.setTimeout(() => playMaxGapPulse(target), pulseDelayMs); lastPulseRef.current = { placeId: maxPlaceId, amount: maxAmount }; }
}

export default function FarqMap({
	places, neighborhoodShapes = null, neighborhoodLabels = null, neighborhoods: _neighborhoods, selectedPlaceId, selectedNeighborhoodId: _selectedNeighborhoodId, focusRequest = null, userLocation, showUserLocation = false, placeDetail: _placeDetail = null, isRTL = false, basemap: basemapProp, onBasemapChange, onSelectPlace, onSelectCluster, onUserPan, onSelectNeighborhood, onViewChange, hideAddressSearch = false, sheetOpen = false, mapMode = "discover",
}: {
	places: IntelligenceMapPlaces | null; neighborhoodShapes?: GeoJSON.FeatureCollection | null; neighborhoodLabels?: GeoJSON.FeatureCollection | null; neighborhoods: IntelligenceMapNeighborhoods | null; selectedPlaceId?: string; selectedNeighborhoodId?: string; focusRequest?: CameraFocusRequest | null; userLocation?: { lat: number; lng: number } | null; showUserLocation?: boolean; placeDetail?: IntelligenceMapPlaceDetail | null; basemap?: MapboxBasemap; onBasemapChange?: (kind: MapboxBasemap) => void; isRTL?: boolean; onSelectPlace: (placeId: string) => void; onSelectCluster?: (info: { lat: number; lng: number; count: number }) => void; onUserPan?: () => void; onSelectNeighborhood: (neighborhoodId: string) => void; onViewChange?: (bbox: string, zoom: number) => void; hideAddressSearch?: boolean; sheetOpen?: boolean; mapMode?: MapZoomMode;
}) {
	const token = getMapboxAccessToken(); const containerRef = useRef<HTMLDivElement | null>(null); const mapRef = useRef<MapboxMap | null>(null); const searchRef = useRef<MapboxSearchBox | null>(null); const userMarkerRef = useRef<mapboxgl.Marker | null>(null); const pinMarkersRef = useRef<Map<string, PinRec>>(new Map()); const prevAmountsRef = useRef<Map<string, number>>(new Map()); const lastPulseRef = useRef<{ placeId: string; amount: number } | null>(null); const pulseTimerRef = useRef(0); const rankTimerRef = useRef(0); const introDoneRef = useRef(false); const lastFocusIdRef = useRef<string | null>(null); const onViewChangeRef = useRef(onViewChange); const onSelectPlaceRef = useRef(onSelectPlace); const onSelectClusterRef = useRef(onSelectCluster); const onSelectHoodRef = useRef(onSelectNeighborhood); const onUserPanRef = useRef(onUserPan); const isRtlRef = useRef(isRTL); const selectedPlaceIdRef = useRef(selectedPlaceId); const appliedStyleRef = useRef<MapboxBasemap>("standard"); const [internalBasemap, setInternalBasemap] = useState<MapboxBasemap>("standard"); const basemap = basemapProp ?? internalBasemap; const setBasemap = (next: MapboxBasemap) => { onBasemapChange?.(next); if (basemapProp === undefined) setInternalBasemap(next); }; const [mapReady, setMapReady] = useState(false); const [introDone, setIntroDone] = useState(false); const [missingToken] = useState(() => !token); const [initFailed, setInitFailed] = useState(false);
	onViewChangeRef.current = onViewChange; onSelectPlaceRef.current = onSelectPlace; onSelectClusterRef.current = onSelectCluster; onSelectHoodRef.current = onSelectNeighborhood; onUserPanRef.current = onUserPan; isRtlRef.current = isRTL; selectedPlaceIdRef.current = selectedPlaceId;
	const placesData = useMemo((): GeoJSON.FeatureCollection => ({ type: "FeatureCollection", features: (places?.features || []).filter((f) => { const c = f.geometry?.coordinates; return Array.isArray(c) && c.length >= 2; }) as GeoJSON.Feature[] }), [places]);

	useEffect(() => {
		if (!token || !containerRef.current || mapRef.current) return; ensureRtlTextPlugin(); mapboxgl.accessToken = token; const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
		let map: MapboxMap;
		try { map = new mapboxgl.Map({ container: containerRef.current, style: mapboxStyleUrl("standard"), center: [20, 18], zoom: reduced ? 11.6 : 1.55, pitch: 0, bearing: 0, projection: "globe", attributionControl: { compact: true } as unknown as boolean, maxPitch: 75, accessToken: token }); }
		catch { setInitFailed(true); return; }
		mapRef.current = map; let introTimer = 0;
		const reportView = () => { try { const b = map.getBounds(); if (!b) return; onViewChangeRef.current?.(`${b.getWest()},${b.getSouth()},${b.getEast()},${b.getNorth()}`, map.getZoom()); } catch {} };
		map.on("style.load", () => { applyBasemap(map, isRtlRef.current); if (introDoneRef.current && mapSession.camera) map.jumpTo(mapSession.camera); });
		map.once("load", () => {
			map.addControl(new mapboxgl.NavigationControl({ visualizePitch: true }), "bottom-right"); const mobileChrome = window.matchMedia("(max-width: 1023px)").matches;
			if (!hideAddressSearch && !mobileChrome) { try { const box = createFarqSearchBox({ token, isRTL: isRtlRef.current }); searchRef.current = box; map.addControl(box, "top-right"); } catch {} }
			syncPinPresentation(containerRef.current, map);
			setMapReady(true);
			const land = (camera: PersistedCamera) => { map.jumpTo(camera); syncPinPresentation(containerRef.current, map); introDoneRef.current = true; mapSession.introStarted = true; persistCamera(map); setIntroDone(true); reportView(); };
			if (mapSession.introStarted && mapSession.camera) land(mapSession.camera); else if (mapSession.introStarted) land({ center: RIYADH_LNG_LAT, zoom: 12.15, pitch: 48, bearing: -18 }); else if (reduced) land({ center: RIYADH_LNG_LAT, zoom: 12.15, pitch: 48, bearing: -18 }); else { mapSession.introStarted = true; map.flyTo({ center: RIYADH_LNG_LAT, zoom: 12.15, pitch: 54, bearing: -20, duration: INTRO_MS, essential: true, curve: 1.55, speed: 0.55 }); introTimer = window.setTimeout(() => { if (mapRef.current !== map) return; introDoneRef.current = true; persistCamera(map); setIntroDone(true); reportView(); }, INTRO_MS + 120); }
		});
		map.on("moveend", () => { if (!introDoneRef.current) return; persistCamera(map); reportView(); syncPinPresentation(containerRef.current, map); window.clearTimeout(rankTimerRef.current); rankTimerRef.current = window.setTimeout(() => applyViewportAuraRanks(map, pinMarkersRef.current, selectedPlaceIdRef.current, lastPulseRef, pulseTimerRef, 0), AURA_VIEWPORT_IDLE_MS); });
		map.on("dragstart", () => onUserPanRef.current?.());
		map.on("click", HOOD_FILL, (ev) => { const id = ev.features?.[0]?.properties?.neighborhood_id; if (id) onSelectHoodRef.current?.(String(id)); });
		const ro = new ResizeObserver(() => { try { map.resize(); } catch {} }); ro.observe(containerRef.current);
		return () => { window.clearTimeout(introTimer); window.clearTimeout(pulseTimerRef.current); window.clearTimeout(rankTimerRef.current); persistCamera(map); ro.disconnect(); userMarkerRef.current?.remove(); clearPinMarkers(pinMarkersRef.current); searchRef.current = null; setMapReady(false); setIntroDone(false); map.remove(); mapRef.current = null; };
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [token]);

	useEffect(() => {
		const map = mapRef.current; if (!map || !mapReady) return; window.clearTimeout(pulseTimerRef.current); const nextKeys = new Set<string>(); const nextAmounts = new Map<string, number>(); const createdBubbles: { placeId: string; amount: number; el: HTMLElement }[] = [];
		for (const feature of placesData.features) {
			if (feature.geometry.type !== "Point") continue; const key = featureMarkerKey(feature); if (!key) continue; const props = (feature.properties || {}) as Record<string, unknown> & { feature_type?: string; place_id?: string; name?: string; count?: number; difference_count?: number; difference?: unknown; provider_count?: number | null };
			const isCluster = props.feature_type === "cluster"; const shouldShow = mapMode === "discover" ? isCluster : mapMode === "opportunity" ? isCluster || !isCluster : true; if (!shouldShow) continue;
			nextKeys.add(key); if (pinMarkersRef.current.has(key)) continue; const coords = feature.geometry.coordinates as [number, number]; let el: HTMLElement; let kind: PinRec["kind"]; let placeId: string | undefined; let amount: number | null = null;
			if (isCluster) { kind = "cluster"; el = buildClusterPinElement({ count: Number(props.count) || 0, differenceCount: Number(props.difference_count) || 0, topGap: observedClusterTopGap(props), isRTL: isRtlRef.current }); el.classList.add(FARQ_CLUSTERS); el.addEventListener("click", (ev) => { ev.stopPropagation(); map.easeTo({ center: coords, zoom: Math.min(16.5, map.getZoom() + 2.2), duration: 650 }); onSelectClusterRef.current?.({ lng: coords[0], lat: coords[1], count: Number(props.count) || 0 }); }); }
			else { kind = "place"; placeId = String(props.place_id || ""); if (!placeId) continue; amount = observedDifferenceAmount(props.difference); el = buildPlacePinElement({ name: String(props.name || ""), difference: props.difference, providerCount: props.provider_count, selected: placeId === selectedPlaceIdRef.current, isRTL: isRtlRef.current, imageUrl: observedRestaurantImageUrl(props) }); el.addEventListener("click", (ev) => { ev.stopPropagation(); onSelectPlaceRef.current(placeId as string); }); if (amount != null) createdBubbles.push({ placeId, amount, el }); }
			const marker = new mapboxgl.Marker({ element: el, anchor: "bottom" }).setLngLat(coords).addTo(map); pinMarkersRef.current.set(key, { key, marker, el, kind, placeId, amount });
		}
		for (const [key, rec] of pinMarkersRef.current) { if (nextKeys.has(key)) continue; rec.marker.remove(); pinMarkersRef.current.delete(key); }
		for (const rec of pinMarkersRef.current.values()) if (rec.kind === "place" && rec.placeId != null && rec.amount != null) nextAmounts.set(rec.placeId, rec.amount);
		const prev = prevAmountsRef.current; const entering = createdBubbles.filter((b) => shouldReplayBubbleMotion(b.placeId, b.amount, prev)); const stagger = entering.length > 0 && entering.length <= BUBBLE_ENTER_STAGGER_MAX; entering.forEach((b, i) => playBubbleEnter(b.el, stagger ? i * 24 : 0)); const pulseDelay = entering.length > 0 ? BUBBLE_ENTER_MS + (stagger ? (entering.length - 1) * 24 : 0) : 0; applyViewportAuraRanks(map, pinMarkersRef.current, selectedPlaceIdRef.current, lastPulseRef, pulseTimerRef, pulseDelay); prevAmountsRef.current = nextAmounts;
	}, [placesData, mapReady, mapMode]);

	useEffect(() => { for (const rec of pinMarkersRef.current.values()) if (rec.kind === "place") setPinSelected(rec.el, Boolean(selectedPlaceId) && rec.placeId === selectedPlaceId); }, [selectedPlaceId, placesData, mapReady]);
	useEffect(() => { const map = mapRef.current; if (!map || !mapReady) return; applyMapLanguage(map, isRTL); }, [isRTL, mapReady]);
	useEffect(() => { const map = mapRef.current; if (!map || !mapReady) return; ensureHoodLayers(map); setHoodData(map, neighborhoodShapes ?? EMPTY_FC, neighborhoodLabels ?? EMPTY_FC); }, [neighborhoodShapes, neighborhoodLabels, mapReady, basemap]);
	useEffect(() => { const map = mapRef.current; if (!map || !introDone) return; if (!showUserLocation || !userLocation) { userMarkerRef.current?.remove(); userMarkerRef.current = null; return; } if (!userMarkerRef.current) { const el = document.createElement("div"); el.className = "farq-user-pulse"; userMarkerRef.current = new mapboxgl.Marker({ element: el }).setLngLat([userLocation.lng, userLocation.lat]).addTo(map); } else userMarkerRef.current.setLngLat([userLocation.lng, userLocation.lat]); }, [showUserLocation, userLocation, introDone]);
	useEffect(() => { const map = mapRef.current; if (!map || !introDone || !focusRequest || lastFocusIdRef.current === focusRequest.id) return; lastFocusIdRef.current = focusRequest.id; const target = focusRequest.zoom; map.easeTo({ center: [focusRequest.lng, focusRequest.lat], ...(target == null ? {} : { zoom: Math.max(map.getZoom(), target) }), duration: target == null ? 700 : 1100, pitch: map.getPitch(), essential: true }); }, [focusRequest, introDone]);
	useEffect(() => { const map = mapRef.current; if (!map || appliedStyleRef.current === basemap) return; persistCamera(map); appliedStyleRef.current = basemap; map.setStyle(mapboxStyleUrl(basemap)); }, [basemap]);
	if (missingToken) return <div className="flex h-full min-h-[50vh] items-center justify-center bg-neutral-900 px-6 text-center text-sm text-white/80" data-testid="intelligence-map-canvas">{isRTL ? "أضف VITE_MAPBOX_ACCESS_TOKEN في Frontend/.env.local ثم أعد تشغيل Vite." : "Add VITE_MAPBOX_ACCESS_TOKEN to Frontend/.env.local and restart Vite."}</div>;
	if (initFailed) return <div className="flex h-full min-h-[50vh] items-center justify-center bg-neutral-900 px-6 text-center text-sm text-white/80" data-testid="intelligence-map-canvas">{isRTL ? "تعذّر تشغيل الخريطة على هذا المتصفح. فعّل WebGL أو جرّب متصفحاً آخر." : "This browser could not start the map. Enable WebGL or try another browser."}</div>;
	return <div className="farq-mapbox-root relative h-full min-h-[50vh] w-full" dir={isRTL ? "rtl" : "ltr"} data-testid="intelligence-map-canvas" data-sheet-open={sheetOpen ? "true" : undefined} data-map-mode={mapMode}><div ref={containerRef} className="h-full min-h-[50vh] w-full" />{onBasemapChange ? null : <div className="absolute bottom-3 end-3 z-[20] flex overflow-hidden rounded-lg bg-[#e6eef0] p-0.5 text-[11px] font-bold"><button type="button" className={`rounded-md px-2.5 py-1 ${basemap === "satellite" ? "bg-brand-900 text-mint-500" : "text-[#6b7c7c]"}`} onClick={() => setBasemap("satellite")}>{isRTL ? "قمر صناعي" : "Satellite"}</button><button type="button" className={`rounded-md px-2.5 py-1 ${basemap === "standard" ? "bg-brand-900 text-mint-500" : "text-[#6b7c7c]"}`} onClick={() => setBasemap("standard")}>{isRTL ? "خريطة" : "Map"}</button></div>}</div>;
}
