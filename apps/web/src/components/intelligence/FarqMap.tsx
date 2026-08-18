/**
 * Farq difference map — Mapbox GL Standard, comparison-row coords.
 * Neighborhood polygons are intentionally not painted (not a choropleth mosaic).
 * Never invents pins, never remints place_id, never fakes GPS.
 * Place pins are 3D HTML markers: large cheapest-app logo when observed,
 * smaller expensive/other chips underneath from real ids only, else restaurant initials.
 */
import type { MapboxSearchBox } from "@mapbox/search-js-web";
import mapboxgl, { type Map as MapboxMap } from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useMemo, useRef, useState } from "react";
import { localizeDigitString } from "../../lib/formatPrice";
import {
	buildClusterPinElement,
	buildPlacePinElement,
	featureMarkerKey,
	parseDifference,
	setPinSelected,
} from "../../lib/farqMapPins";
import {
	getMapboxAccessToken,
	type MapboxBasemap,
	mapboxStyleUrl,
	RIYADH_LNG_LAT,
} from "../../lib/mapboxAccess";
import { createFarqSearchBox } from "../../lib/mapboxSearch";
import type {
	IntelligenceMapNeighborhoods,
	IntelligenceMapPlaceDetail,
	IntelligenceMapPlaces,
} from "../../services/intelligenceService";
import "../../styles/farq-mapbox.css";

const INTRO_MS = 5600;
const FARQ_CLUSTERS = "farq-clusters";

type CameraFocusRequest = {
	lat: number;
	lng: number;
	id: string;
};

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
};

function escapeHtml(value: string): string {
	return String(value)
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;");
}

function popupHtml(opts: {
	name: string;
	difference?: {
		difference_amount?: number | null;
		product_name?: string | null;
		cheapest_provider_id?: string | null;
		expensive_provider_id?: string | null;
	} | null;
	isRTL: boolean;
}): string {
	const name = escapeHtml(opts.name || (opts.isRTL ? "مكان" : "Place"));
	const diff = opts.difference;
	if (
		diff &&
		(diff.difference_amount != null ||
			diff.product_name ||
			diff.cheapest_provider_id)
	) {
		const amount =
			diff.difference_amount != null
				? localizeDigitString(String(diff.difference_amount), opts.isRTL)
				: "—";
		const product = diff.product_name
			? `<p class="farq-mapbox-popup-product">${escapeHtml(String(diff.product_name))}</p>`
			: "";
		return `<div dir="${opts.isRTL ? "rtl" : "ltr"}">
			<p class="farq-mapbox-popup-name">${name}</p>
			<p class="farq-mapbox-popup-gap">${opts.isRTL ? "فرق مرصود" : "Observed فرق"}</p>
			<p class="farq-mapbox-popup-amount">${amount} <span style="font-size:13px;font-weight:700">ر.س</span></p>
			${product}
		</div>`;
	}
	return `<div dir="${opts.isRTL ? "rtl" : "ltr"}">
		<p class="farq-mapbox-popup-name">${name}</p>
		<p class="farq-mapbox-popup-empty">${
			opts.isRTL
				? "ما عندنا فرق سعر مرصود لهذا المكان بعد."
				: "No observed price gap for this place yet."
		}</p>
	</div>`;
}

function applyBasemap(map: MapboxMap) {
	try {
		map.setConfigProperty("basemap", "lightPreset", "dusk");
	} catch {
		/* classic styles ignore Standard config */
	}
	try {
		map.setConfigProperty("basemap", "show3dObjects", true);
	} catch {
		/* */
	}
	try {
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
		/* terrain optional if DEM unavailable */
	}
	try {
		map.setFog({
			color: "rgb(186, 210, 235)",
			"high-color": "rgb(36, 92, 223)",
			"horizon-blend": 0.03,
			"space-color": "rgb(11, 11, 25)",
			"star-intensity": 0.55,
		});
	} catch {
		/* */
	}
}

function clearPinMarkers(markers: Map<string, PinRec>) {
	for (const rec of markers.values()) {
		rec.marker.remove();
	}
	markers.clear();
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
}: {
	places: IntelligenceMapPlaces | null;
	/** Accepted for IntelligenceMapSplit compatibility — not painted on the consumer map. */
	neighborhoods: IntelligenceMapNeighborhoods | null;
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
	onViewChange?: (bbox: string, zoom: number) => void;
}) {
	const token = getMapboxAccessToken();
	const containerRef = useRef<HTMLDivElement | null>(null);
	const mapRef = useRef<MapboxMap | null>(null);
	const searchRef = useRef<MapboxSearchBox | null>(null);
	const popupRef = useRef<mapboxgl.Popup | null>(null);
	const userMarkerRef = useRef<mapboxgl.Marker | null>(null);
	const pinMarkersRef = useRef<Map<string, PinRec>>(new Map());
	const introDoneRef = useRef(false);
	const lastFocusIdRef = useRef<string | null>(null);
	const onViewChangeRef = useRef(onViewChange);
	const onSelectPlaceRef = useRef(onSelectPlace);
	const isRtlRef = useRef(isRTL);
	const selectedPlaceIdRef = useRef(selectedPlaceId);
	const appliedStyleRef = useRef<MapboxBasemap>("standard");
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
	isRtlRef.current = isRTL;
	selectedPlaceIdRef.current = selectedPlaceId;

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

		const reduced = Boolean(
			window.matchMedia("(prefers-reduced-motion: reduce)").matches,
		);

		const map = new mapboxgl.Map({
			container: containerRef.current,
			style: mapboxStyleUrl("standard"),
			center: [20, 18],
			zoom: reduced ? 11.6 : 1.55,
			pitch: 0,
			bearing: 0,
			projection: "globe",
			attributionControl: { compact: true } as unknown as boolean,
			maxPitch: 75,
			accessToken: token,
		});
		mapRef.current = map;
		let introTimer = 0;

		const reportView = () => {
			try {
				const b = map.getBounds();
				if (!b) return;
				const bbox = `${b.getWest()},${b.getSouth()},${b.getEast()},${b.getNorth()}`;
				onViewChangeRef.current?.(bbox, map.getZoom());
			} catch {
				/* */
			}
		};

		map.on("style.load", () => {
			applyBasemap(map);
			if (introDoneRef.current && mapSession.camera) {
				map.jumpTo(mapSession.camera);
			}
		});

		map.once("load", () => {
			map.addControl(
				new mapboxgl.NavigationControl({ visualizePitch: true }),
				"bottom-right",
			);
			try {
				const box = createFarqSearchBox({ token, isRTL: isRtlRef.current });
				searchRef.current = box;
				map.addControl(box, "top-right");
			} catch {
				/* Search Box optional if the token lacks Search scope */
			}

			setMapReady(true);

			const landQuietly = (camera: PersistedCamera) => {
				map.jumpTo(camera);
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
					pitch: 48,
					bearing: -18,
				});
			} else if (reduced) {
				mapSession.introStarted = true;
				map.jumpTo({
					center: RIYADH_LNG_LAT,
					zoom: 12.15,
					pitch: 48,
					bearing: -18,
				});
				introDoneRef.current = true;
				persistCamera(map);
				setIntroDone(true);
				reportView();
			} else {
				mapSession.introStarted = true;
				map.flyTo({
					center: RIYADH_LNG_LAT,
					zoom: 12.15,
					pitch: 54,
					bearing: -20,
					duration: INTRO_MS,
					essential: true,
					curve: 1.55,
					speed: 0.55,
				});
				introTimer = window.setTimeout(() => {
					if (mapRef.current !== map) return;
					introDoneRef.current = true;
					persistCamera(map);
					setIntroDone(true);
					reportView();
				}, INTRO_MS + 120);
			}
		});

		map.on("moveend", () => {
			if (!introDoneRef.current) return;
			persistCamera(map);
			reportView();
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
			persistCamera(map);
			ro.disconnect();
			popupRef.current?.remove();
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

		const openPlacePopup = (
			lngLat: [number, number],
			name: string,
			difference: ReturnType<typeof parseDifference>,
		) => {
			popupRef.current?.remove();
			popupRef.current = new mapboxgl.Popup({
				offset: 30,
				className: "farq-mapbox-popup",
				maxWidth: "18rem",
				closeButton: true,
			})
				.setLngLat(lngLat)
				.setHTML(
					popupHtml({
						name,
						difference,
						isRTL: isRtlRef.current,
					}),
				)
				.addTo(map);
		};

		const nextKeys = new Set<string>();
		for (const feature of placesData.features) {
			const key = featureMarkerKey(feature);
			if (!key || feature.geometry.type !== "Point") continue;
			nextKeys.add(key);
			if (pinMarkersRef.current.has(key)) continue;

			const coords = feature.geometry.coordinates as [number, number];
			const props = (feature.properties || {}) as {
				feature_type?: string;
				place_id?: string;
				name?: string;
				count?: number;
				difference_count?: number;
				difference?: unknown;
				provider_count?: number | null;
			};

			let el: HTMLElement;
			let kind: PinRec["kind"];
			let placeId: string | undefined;

			if (props.feature_type === "cluster") {
				kind = "cluster";
				el = buildClusterPinElement({
					count: Number(props.count) || 0,
					differenceCount: Number(props.difference_count) || 0,
					isRTL: isRtlRef.current,
				});
				el.classList.add(FARQ_CLUSTERS);
				el.addEventListener("click", (ev) => {
					ev.stopPropagation();
					map.easeTo({
						center: coords,
						zoom: Math.min(16.5, map.getZoom() + 2.2),
						duration: 650,
					});
				});
			} else {
				kind = "place";
				placeId = String(props.place_id || "");
				if (!placeId) continue;
				el = buildPlacePinElement({
					name: String(props.name || ""),
					difference: props.difference,
					providerCount: props.provider_count,
					selected: placeId === selectedPlaceIdRef.current,
					isRTL: isRtlRef.current,
				});
				el.addEventListener("click", (ev) => {
					ev.stopPropagation();
					onSelectPlaceRef.current(placeId as string);
					openPlacePopup(
						coords,
						String(props.name || ""),
						parseDifference(props.difference),
					);
				});
			}

			const marker = new mapboxgl.Marker({
				element: el,
				anchor: "bottom",
			})
				.setLngLat(coords)
				.addTo(map);

			pinMarkersRef.current.set(key, { key, marker, el, kind, placeId });
		}

		for (const [key, rec] of pinMarkersRef.current) {
			if (nextKeys.has(key)) continue;
			rec.marker.remove();
			pinMarkersRef.current.delete(key);
		}
	}, [placesData, mapReady]);

	useEffect(() => {
		for (const rec of pinMarkersRef.current.values()) {
			if (rec.kind !== "place") continue;
			setPinSelected(rec.el, Boolean(selectedPlaceId) && rec.placeId === selectedPlaceId);
		}
	}, [selectedPlaceId, placesData, mapReady]);

	useEffect(() => {
		if (!placeDetail || !selectedPlaceId) return;
		if (placeDetail.place_id !== selectedPlaceId) return;
		const map = mapRef.current;
		if (!map) return;
		const lngLat: [number, number] = [placeDetail.lng, placeDetail.lat];
		if (!popupRef.current) {
			popupRef.current = new mapboxgl.Popup({
				offset: 30,
				className: "farq-mapbox-popup",
				maxWidth: "18rem",
			});
		}
		popupRef.current
			.setLngLat(lngLat)
			.setHTML(
				popupHtml({
					name: placeDetail.name,
					difference: placeDetail.difference,
					isRTL,
				}),
			)
			.addTo(map);
	}, [placeDetail, selectedPlaceId, isRTL]);

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
			userMarkerRef.current = new mapboxgl.Marker({ element: el })
				.setLngLat([userLocation.lng, userLocation.lat])
				.addTo(map);
		} else {
			userMarkerRef.current.setLngLat([userLocation.lng, userLocation.lat]);
		}
	}, [showUserLocation, userLocation]);

	useEffect(() => {
		const map = mapRef.current;
		if (!map || !introDone || !focusRequest) return;
		if (lastFocusIdRef.current === focusRequest.id) return;
		lastFocusIdRef.current = focusRequest.id;
		map.easeTo({
			center: [focusRequest.lng, focusRequest.lat],
			duration: 700,
			pitch: map.getPitch(),
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

	if (missingToken) {
		return (
			<div
				className="flex h-full min-h-[50vh] items-center justify-center bg-neutral-900 px-6 text-center text-sm text-white/80"
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
			className="farq-mapbox-root relative h-full min-h-[50vh] w-full"
			dir={isRTL ? "rtl" : "ltr"}
			data-testid="intelligence-map-canvas"
		>
			<div ref={containerRef} className="h-full min-h-[50vh] w-full" />
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
