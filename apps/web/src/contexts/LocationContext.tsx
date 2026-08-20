import {
	createContext,
	lazy,
	Suspense,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { useLanguage } from "./LanguageContext";
import { safeGet, safeSet } from "../lib/safeStorage";

const MapPickerModal = lazy(() => import("../components/MapPickerModal"));

export const RIYADH_FALLBACK = { lat: 24.7136, lng: 46.6753 };
export const RIYADH_COVERAGE_DEFAULT = RIYADH_FALLBACK;

export type LocationPinKind = "gps" | "manual" | "fallback" | null;
export type GeoLocationErrorKind =
	| "denied"
	| "unavailable"
	| "timeout"
	| "unsupported";

type LocationContextType = {
	hasLocationPermission: boolean | null;
	showLocationModal: boolean;
	showMapModal: boolean;
	userLocation: { lat: number; lng: number } | null;
	locationAddress: string | null;
	isManualLocation: boolean;
	locationPinKind: LocationPinKind;
	locationError: string | null;
	isLocating: boolean;
	requestLocation: () => void;
	allowLocation: () => void;
	enableLocationOrOpenSettings: () => void;
	denyLocation: () => void;
	closeModal: () => void;
	openMapModal: () => void;
	closeMapModal: () => void;
	hideMapModal: () => void;
	setManualLocation: (lat: number, lng: number) => void;
	dismissError: () => void;
	promptLocationIfNeeded: () => void;
};

const LocationContext = createContext<LocationContextType | undefined>(
	undefined,
);

export function geoErrorKindFromCode(
	code?: number,
): GeoLocationErrorKind {
	if (code === 2) return "unavailable";
	if (code === 3) return "timeout";
	return "denied";
}

/** Honest Safari / iPhone instructions — never invents coordinates. */
export function geoLocationHelpMessage(
	isRTL: boolean,
	kind: GeoLocationErrorKind,
): string {
	if (kind === "unsupported") {
		return isRTL
			? "هذا المتصفح لا يدعم تحديد الموقع. استخدم سفاري وفعّل خدمة الموقع."
			: "This browser cannot determine your location. Use Safari with Location Services on.";
	}
	if (kind === "unavailable") {
		return isRTL
			? "تعذّر تحديد موقعك الآن. تأكد أن خدمة الموقع مفعّلة على الآيفون، ثم اضغط «موقعي» مرة ثانية."
			: "Your location is unavailable right now. Turn on Location Services on iPhone, then tap My location again.";
	}
	if (kind === "timeout") {
		return isRTL
			? "انتهى وقت تحديد الموقع. اضغط «موقعي» وحاول مرة ثانية — لا نضع موقعاً افتراضياً."
			: "Locating timed out. Tap My location and try again — we will not invent a place.";
	}
	return isRTL
		? "ما قدرنا نحدد موقعك. اسمح للموقع من نافذة سفاري، أو من إعدادات الآيفون: الإعدادات ← الخصوصية والأمان ← خدمة الموقع ← Safari، ثم اضغط «موقعي» مرة ثانية."
		: "We could not determine your location. Allow it in the Safari prompt, or on iPhone: Settings → Privacy & Security → Location Services → Safari, then tap My location again.";
}

const GPS_OPTIONS: PositionOptions = {
	enableHighAccuracy: true,
	timeout: 15_000,
	maximumAge: 0,
};

const WATCH_OPTIONS: PositionOptions = {
	enableHighAccuracy: true,
	timeout: 20_000,
	maximumAge: 8_000,
};

export function LocationProvider({ children }: { children: ReactNode }) {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const watchIdRef = useRef<number | null>(null);
	const [hasLocationPermission, setHasLocationPermission] = useState<
		boolean | null
	>(() => {
		const prior = safeGet("localStorage", "locationPermission");
		if (prior === "granted") return true;
		if (prior === "denied") return false;
		return null;
	});
	const [showMapModal, setShowMapModal] = useState(false);
	const [userLocation, setUserLocation] = useState<{
		lat: number;
		lng: number;
	} | null>(null);
	const [locationAddress, setLocationAddress] = useState<string | null>(null);
	const [isManualLocation, setIsManualLocation] = useState(false);
	const [locationPinKind, setLocationPinKind] =
		useState<LocationPinKind>(null);
	const [errorKind, setErrorKind] = useState<GeoLocationErrorKind | null>(
		null,
	);
	const [isLocating, setIsLocating] = useState(false);

	const locationError = useMemo(
		() => (errorKind ? geoLocationHelpMessage(isRTL, errorKind) : null),
		[errorKind, isRTL],
	);

	const clearWatch = useCallback(() => {
		if (watchIdRef.current == null) return;
		if ("geolocation" in navigator) {
			navigator.geolocation.clearWatch(watchIdRef.current);
		}
		watchIdRef.current = null;
	}, []);

	const applyGps = useCallback((lat: number, lng: number) => {
		setUserLocation({ lat, lng });
		setLocationPinKind("gps");
		setHasLocationPermission(true);
		setIsManualLocation(false);
		setErrorKind(null);
		safeSet("localStorage", "locationPermission", "granted");
	}, []);

	const startWatch = useCallback(() => {
		if (!("geolocation" in navigator)) return;
		if (watchIdRef.current != null) return;
		watchIdRef.current = navigator.geolocation.watchPosition(
			(pos) => {
				applyGps(pos.coords.latitude, pos.coords.longitude);
			},
			(err) => {
				if (err.code === 1) {
					clearWatch();
					setHasLocationPermission(false);
					safeSet("localStorage", "locationPermission", "denied");
					setErrorKind("denied");
				}
			},
			WATCH_OPTIONS,
		);
	}, [applyGps, clearWatch]);

	const failLocate = useCallback((kind: GeoLocationErrorKind) => {
		setIsLocating(false);
		setHasLocationPermission(false);
		if (kind === "denied" || kind === "unsupported") {
			safeSet("localStorage", "locationPermission", "denied");
		}
		setErrorKind(kind);
		/* Do not invent Riyadh (or any) coordinates as “my place”. */
	}, []);

	const requestLocation = useCallback(() => {
		setErrorKind(null);
		setIsLocating(true);
		if (!("geolocation" in navigator)) {
			failLocate("unsupported");
			return;
		}
		/* Must run in the same turn as the tap — iOS Safari ignores delayed prompts. */
		navigator.geolocation.getCurrentPosition(
			(pos) => {
				applyGps(pos.coords.latitude, pos.coords.longitude);
				setIsLocating(false);
				startWatch();
			},
			(err) => {
				failLocate(geoErrorKindFromCode(err?.code));
			},
			GPS_OPTIONS,
		);
	}, [applyGps, failLocate, startWatch]);

	useEffect(() => () => clearWatch(), [clearWatch]);

	const setManualLocation = useCallback((lat: number, lng: number) => {
		setUserLocation({ lat, lng });
		setLocationPinKind("manual");
		setIsManualLocation(true);
		setHasLocationPermission(true);
		setErrorKind(null);
		safeSet("localStorage", "locationPermission", "granted");
	}, []);

	const value = useMemo<LocationContextType>(
		() => ({
			hasLocationPermission,
			showLocationModal: false,
			showMapModal,
			userLocation,
			locationAddress,
			isManualLocation,
			locationPinKind,
			locationError,
			isLocating,
			requestLocation,
			allowLocation: requestLocation,
			enableLocationOrOpenSettings: requestLocation,
			denyLocation: () => {
				setHasLocationPermission(false);
				safeSet("localStorage", "locationPermission", "denied");
			},
			closeModal: () => undefined,
			openMapModal: () => setShowMapModal(true),
			closeMapModal: () => setShowMapModal(false),
			hideMapModal: () => setShowMapModal(false),
			setManualLocation,
			dismissError: () => setErrorKind(null),
			promptLocationIfNeeded: requestLocation,
		}),
		[
			hasLocationPermission,
			showMapModal,
			userLocation,
			locationAddress,
			isManualLocation,
			locationPinKind,
			locationError,
			isLocating,
			requestLocation,
			setManualLocation,
		],
	);

	return (
		<LocationContext.Provider value={value}>
			{children}
			{showMapModal ? (
				<Suspense fallback={null}>
					<MapPickerModal
						isOpen
						onClose={() => setShowMapModal(false)}
						currentLocation={userLocation}
						onLocationSelect={(lat, lng) => {
							setManualLocation(lat, lng);
							setLocationAddress(null);
							setShowMapModal(false);
						}}
					/>
				</Suspense>
			) : null}
		</LocationContext.Provider>
	);
}

export function useLocation(): LocationContextType {
	const ctx = useContext(LocationContext);
	if (!ctx) throw new Error("useLocation must be used within LocationProvider");
	return ctx;
}
