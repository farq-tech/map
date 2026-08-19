import { MapPin, Navigation, X } from "lucide-react";
import mapboxgl, { type Map as MapboxMap } from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useRef, useState } from "react";
import { useLanguage } from "../contexts/LanguageContext";
import { useLocation } from "../contexts/LocationContext";
import { useFocusTrap } from "../hooks/useFocusTrap";
import {
	applyMapLanguage,
	ensureRtlTextPlugin,
	getMapboxAccessToken,
	mapboxStyleUrl,
} from "../lib/mapboxAccess";
import {
	bindSearchBoxToMap,
	createFarqSearchBox,
	lngLatFromSearchRetrieve,
} from "../lib/mapboxSearch";
import { READY_CITIES } from "../lib/readyCities";
import { safeGet } from "../lib/safeStorage";
import { GeocodingService } from "../services/geocodingService";
import { Button } from "./ui/Button";
import "../styles/farq-mapbox.css";

const GEOLOCATION_ERROR_DISMISS_MS = 4000;

export function mapPaneHasSize(
	size: { x: number; y: number } | null | undefined,
): boolean {
	return size != null && size.x > 0 && size.y > 0;
}

interface MapPickerModalProps {
	isOpen: boolean;
	onClose: () => void;
	currentLocation: { lat: number; lng: number } | null;
	onLocationSelect: (lat: number, lng: number) => void;
}

async function reverseAddress(
	lat: number,
	lng: number,
	isRTL: boolean,
	token: string,
): Promise<string> {
	if (token) {
		try {
			const url = `https://api.mapbox.com/geocoding/v5/mapbox.places/${lng},${lat}.json?access_token=${encodeURIComponent(token)}&language=${isRTL ? "ar" : "en"}&limit=1`;
			const res = await fetch(url);
			if (res.ok) {
				const json = (await res.json()) as {
					features?: Array<{ place_name?: string }>;
				};
				const name = json.features?.[0]?.place_name;
				if (name) return name;
			}
		} catch {
			/* fall through to existing geocoder */
		}
	}
	const result = await GeocodingService.reverseGeocode(
		lat,
		lng,
		isRTL ? "ar" : "en",
	);
	return result.displayName;
}

function applyPickerBasemap(map: MapboxMap, isRTL: boolean) {
	try {
		map.setConfigProperty("basemap", "lightPreset", "dusk");
	} catch {
		/* Farq basemap brings its own light — this only matters if the style changes */
	}
	try {
		map.setConfigProperty("basemap", "show3dObjects", true);
	} catch {
		/* as above */
	}
	applyMapLanguage(map, isRTL);
}

export default function MapPickerModal({
	isOpen,
	onClose,
	currentLocation,
	onLocationSelect,
}: MapPickerModalProps) {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const { promptLocationIfNeeded, enableLocationOrOpenSettings, hideMapModal } =
		useLocation();

	const token = getMapboxAccessToken();
	const defaultLat = currentLocation?.lat || 24.7136;
	const defaultLng = currentLocation?.lng || 46.6753;

	const [selectedPosition, setSelectedPosition] = useState<[number, number]>([
		defaultLat,
		defaultLng,
	]);
	const [address, setAddress] = useState<string>("");
	const [geolocationError, setGeolocationError] = useState<string | null>(null);
	const geolocationErrorTimerRef = useRef<ReturnType<typeof setTimeout> | null>(
		null,
	);
	const dialogRef = useRef<HTMLDivElement>(null);
	const mapHostRef = useRef<HTMLDivElement>(null);
	const searchHostRef = useRef<HTMLDivElement>(null);
	const mapRef = useRef<MapboxMap | null>(null);
	const markerRef = useRef<mapboxgl.Marker | null>(null);
	const cityMarkersRef = useRef<mapboxgl.Marker[]>([]);
	const skipFlyRef = useRef(false);
	const selectedPositionRef = useRef(selectedPosition);
	selectedPositionRef.current = selectedPosition;
	const isRtlRef = useRef(isRTL);
	isRtlRef.current = isRTL;
	useFocusTrap(dialogRef, isOpen);

	useEffect(() => {
		return () => {
			if (geolocationErrorTimerRef.current) {
				clearTimeout(geolocationErrorTimerRef.current);
			}
		};
	}, []);

	useEffect(() => {
		if (!isOpen) return;
		const previouslyFocused = document.activeElement as HTMLElement | null;
		dialogRef.current?.focus();
		const onKeyDown = (e: KeyboardEvent) => {
			if (e.key === "Escape") {
				e.stopPropagation();
				onClose();
			}
		};
		document.addEventListener("keydown", onKeyDown);
		return () => {
			document.removeEventListener("keydown", onKeyDown);
			previouslyFocused?.focus?.();
		};
	}, [isOpen, onClose]);

	useEffect(() => {
		if (currentLocation) {
			setSelectedPosition([currentLocation.lat, currentLocation.lng]);
		}
	}, [currentLocation]);

	useEffect(() => {
		if (!isOpen) return;
		let cancelled = false;
		void reverseAddress(
			selectedPosition[0],
			selectedPosition[1],
			isRTL,
			token,
		).then((name) => {
			if (!cancelled) setAddress(name);
		});
		return () => {
			cancelled = true;
		};
	}, [selectedPosition, isRTL, isOpen, token]);

	// One Mapbox map per open — pin moves are handled below, not by remounting.
	useEffect(() => {
		if (!isOpen || !token || !mapHostRef.current || mapRef.current) return;
		ensureRtlTextPlugin();
		mapboxgl.accessToken = token;
		const [startLat, startLng] = selectedPositionRef.current;
		let map: MapboxMap;
		try {
			map = new mapboxgl.Map({
				container: mapHostRef.current,
				style: mapboxStyleUrl("standard"),
				center: [startLng, startLat],
				zoom: 13,
				pitch: 42,
				bearing: -12,
				projection: "globe",
				attributionControl: { compact: true } as unknown as boolean,
				accessToken: token,
			});
		} catch {
			return; /* no WebGL — the picker stays usable without a preview map */
		}
		mapRef.current = map;

		map.on("style.load", () => applyPickerBasemap(map, isRtlRef.current));

		map.once("load", () => {
			map.addControl(
				new mapboxgl.NavigationControl({ visualizePitch: true }),
				"bottom-right",
			);
			try {
				map.setConfigProperty("basemap", "lightPreset", "dusk");
			} catch {
				/* */
			}

			const pin = document.createElement("div");
			pin.innerHTML = `
				<div style="display:flex;flex-direction:column;align-items:center">
					<div style="width:48px;height:48px;background:rgb(4,52,52);border-radius:9999px;border:2px solid #fff;box-shadow:0 1px 6px rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center">
						<svg width="16" height="16" viewBox="0 0 24 24" fill="white"><path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"/></svg>
					</div>
					<div style="width:2px;height:10px;background:rgb(4,52,52)"></div>
				</div>`;
			markerRef.current = new mapboxgl.Marker({
				element: pin,
				anchor: "bottom",
			})
				.setLngLat([startLng, startLat])
				.addTo(map);

			for (const city of READY_CITIES) {
				const wrap = document.createElement("div");
				wrap.style.cssText =
					"display:flex;flex-direction:column;align-items:center;cursor:pointer";
				const dot = document.createElement("div");
				dot.style.cssText =
					"width:12px;height:12px;background:rgb(4,52,52);border:2px solid #fff;border-radius:9999px;box-shadow:0 1px 4px rgba(0,0,0,.35)";
				const label = document.createElement("div");
				label.className = "ready-city-mapbox-label";
				label.textContent = isRtlRef.current ? city.nameAr : city.nameEn;
				wrap.append(dot, label);
				wrap.addEventListener("click", (ev) => {
					ev.stopPropagation();
					setSelectedPosition([city.lat, city.lng]);
				});
				cityMarkersRef.current.push(
					new mapboxgl.Marker({ element: wrap, anchor: "bottom" })
						.setLngLat([city.lng, city.lat])
						.addTo(map),
				);
			}

			if (searchHostRef.current && !searchHostRef.current.childElementCount) {
				try {
					const box = createFarqSearchBox({
						token,
						isRTL: isRtlRef.current,
						marker: false,
					});
					box.addEventListener("retrieve", (ev) => {
						const ll = lngLatFromSearchRetrieve((ev as CustomEvent).detail);
						if (ll) setSelectedPosition([ll.lat, ll.lng]);
					});
					searchHostRef.current.appendChild(box as unknown as Node);
					bindSearchBoxToMap(box, map);
				} catch {
					/* geocoder optional */
				}
			}
		});

		map.on("click", (e) => {
			skipFlyRef.current = true;
			setSelectedPosition([e.lngLat.lat, e.lngLat.lng]);
		});

		const ro = new ResizeObserver(() => {
			try {
				map.resize();
			} catch {
				/* */
			}
		});
		ro.observe(mapHostRef.current);
		window.setTimeout(() => {
			try {
				map.resize();
			} catch {
				/* */
			}
		}, 80);

		return () => {
			ro.disconnect();
			for (const m of cityMarkersRef.current) m.remove();
			cityMarkersRef.current = [];
			markerRef.current?.remove();
			markerRef.current = null;
			if (searchHostRef.current) searchHostRef.current.innerHTML = "";
			map.remove();
			mapRef.current = null;
		};
		// Recreate when the modal opens so the pane has real pixels.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [isOpen, token]);

	useEffect(() => {
		const map = mapRef.current;
		markerRef.current?.setLngLat([selectedPosition[1], selectedPosition[0]]);
		if (!map) return;
		if (skipFlyRef.current) {
			skipFlyRef.current = false;
			return;
		}
		map.easeTo({
			center: [selectedPosition[1], selectedPosition[0]],
			duration: 550,
			zoom: Math.max(map.getZoom(), 12),
		});
	}, [selectedPosition]);

	const handleConfirm = () => {
		onLocationSelect(selectedPosition[0], selectedPosition[1]);
		onClose();
	};

	const showGeolocationError = () => {
		const message = isRTL
			? "تعذّر تحديد موقعك. تأكد من السماح بصلاحية الموقع وأعد المحاولة."
			: "Couldn't get your location. Make sure location permission is allowed and try again.";
		setGeolocationError(message);
		if (geolocationErrorTimerRef.current) {
			clearTimeout(geolocationErrorTimerRef.current);
		}
		geolocationErrorTimerRef.current = setTimeout(() => {
			setGeolocationError(null);
			geolocationErrorTimerRef.current = null;
		}, GEOLOCATION_ERROR_DISMISS_MS);
	};

	const handleUseCurrentLocation = () => {
		const prior = safeGet("localStorage", "locationPermission");
		if (prior === null) {
			hideMapModal();
			promptLocationIfNeeded();
			return;
		}
		if (prior === "denied") {
			hideMapModal();
			enableLocationOrOpenSettings();
			return;
		}
		if (!("geolocation" in navigator)) {
			showGeolocationError();
			return;
		}
		navigator.geolocation.getCurrentPosition(
			(position) => {
				const { latitude, longitude } = position.coords;
				setSelectedPosition([latitude, longitude]);
			},
			() => {
				showGeolocationError();
			},
			{
				enableHighAccuracy: true,
				timeout: 20_000,
				maximumAge: 0,
			},
		);
	};

	if (!isOpen) {
		return null;
	}

	return (
		<div
			ref={dialogRef}
			role="dialog"
			aria-modal="true"
			aria-label={isRTL ? "عنوان التوصيل" : "Delivery Address"}
			tabIndex={-1}
			className="fixed inset-0 z-[9999] flex items-end justify-center outline-none sm:items-center"
		>
			<button
				type="button"
				tabIndex={-1}
				aria-hidden="true"
				className="absolute inset-0 bg-black/50 backdrop-blur-sm"
				onClick={onClose}
			/>
			{geolocationError && (
				<div
					role="alert"
					aria-live="polite"
					className={`pointer-events-none absolute left-1/2 top-4 z-[10000] -translate-x-1/2 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800 shadow-lg max-w-[92vw] sm:max-w-md ${isRTL ? "font-arabic text-right" : "text-left"}`}
					style={{ top: "max(1rem, env(safe-area-inset-top))" }}
				>
					{geolocationError}
				</div>
			)}
			<div
				className={`relative z-[1] flex h-[100dvh] w-full max-h-[100dvh] flex-col overflow-hidden bg-surface-2 sm:h-auto sm:max-h-[90vh] sm:w-full sm:max-w-[736px] sm:rounded-ds-xl sm:bg-surface sm:shadow-2xl ${isRTL ? "font-arabic" : ""}`}
			>
				<div className="flex shrink-0 items-center justify-between border-b border-line/80 px-4 pt-[max(0.75rem,env(safe-area-inset-top))] pb-3 sm:px-8 sm:pt-6 sm:pb-4">
					<h2
						className={`text-xl font-semibold text-ink sm:text-2xl ${isRTL ? "font-arabic" : ""}`}
					>
						{isRTL ? "عنوان التوصيل" : "Delivery Address"}
					</h2>
					<button
						type="button"
						onClick={onClose}
						aria-label={isRTL ? "إغلاق" : "Close"}
						className="flex h-10 w-10 items-center justify-center rounded-full text-ink-muted hover:bg-surface-2 sm:h-6 sm:w-6 sm:rounded-none"
					>
						<X className="h-5 w-5" />
					</button>
				</div>

				<div className="flex shrink-0 items-center gap-3 px-3 py-3 sm:px-5">
					<div
						ref={searchHostRef}
						className="farq-mapbox-search min-w-0 flex-1"
						data-testid="map-picker-geocoder"
					/>
					<Button
						type="button"
						variant="primary"
						size="lg"
						className={`hidden sm:inline-flex ${isRTL ? "font-arabic text-lg" : "text-lg"}`}
						onClick={handleConfirm}
					>
						{isRTL ? "تأكيد" : "Confirm"}
					</Button>
				</div>

				<div className="relative min-h-0 flex-1 sm:h-[360px] sm:min-h-[200px] sm:flex-none sm:px-5 sm:pb-5">
					<div
						className="farq-mapbox-picker relative h-full min-h-[180px] overflow-hidden sm:rounded-2xl sm:border sm:border-line/80"
						data-testid="map-picker-mapbox"
					>
						{token ? (
							<div ref={mapHostRef} className="h-full min-h-[180px] w-full" />
						) : (
							<div className="flex h-full items-center justify-center bg-neutral-900 px-4 text-center text-sm text-white/80">
								{isRTL
									? "أضف VITE_MAPBOX_ACCESS_TOKEN في .env.local"
									: "Add VITE_MAPBOX_ACCESS_TOKEN to .env.local"}
							</div>
						)}
						<button
							type="button"
							onClick={handleUseCurrentLocation}
							aria-label={
								isRTL ? "استخدام الموقع الحالي" : "Use current location"
							}
							className={`absolute ${isRTL ? "left-3" : "right-3"} bottom-28 z-[2] flex items-center gap-1.5 rounded-lg border border-brand-900 bg-surface px-3 py-2.5 shadow-lg sm:bottom-4 ${isRTL ? "font-arabic" : ""}`}
						>
							<Navigation className="h-[18px] w-[18px] text-ink" />
							<span className="text-sm font-semibold text-brand-900 sm:text-lg">
								{isRTL ? "الموقع الحالي" : "Current location"}
							</span>
						</button>
					</div>
				</div>

				<div className="shrink-0 border-t border-line/60 bg-surface p-4 pb-[max(1rem,env(safe-area-inset-bottom))] sm:hidden">
					<div className="mb-4 flex items-center gap-1">
						<MapPin className="h-6 w-6 shrink-0 text-brand-900" />
						<p
							className={`line-clamp-2 text-sm leading-tight text-ink ${isRTL ? "text-right font-arabic" : ""}`}
						>
							{address ||
								(isRTL ? "جاري تحديد العنوان..." : "Loading address...")}
						</p>
					</div>
					<Button
						type="button"
						variant="primary"
						fullWidth
						size="lg"
						className={isRTL ? "font-arabic text-lg" : "text-lg"}
						onClick={handleConfirm}
					>
						{isRTL ? "تأكيد" : "Confirm"}
					</Button>
				</div>
			</div>
		</div>
	);
}
