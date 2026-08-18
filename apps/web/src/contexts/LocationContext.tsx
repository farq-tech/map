import {
	createContext,
	lazy,
	Suspense,
	type ReactNode,
	useCallback,
	useContext,
	useMemo,
	useState,
} from "react";
import { safeGet, safeSet } from "../lib/safeStorage";

const MapPickerModal = lazy(() => import("../components/MapPickerModal"));

export const RIYADH_FALLBACK = { lat: 24.7136, lng: 46.6753 };
export const RIYADH_COVERAGE_DEFAULT = RIYADH_FALLBACK;

type LocationPinKind = "gps" | "manual" | "fallback" | null;

interface LocationContextType {
	hasLocationPermission: boolean | null;
	showLocationModal: boolean;
	showMapModal: boolean;
	userLocation: { lat: number; lng: number } | null;
	locationAddress: string | null;
	isManualLocation: boolean;
	locationPinKind: LocationPinKind;
	locationError: string | null;
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
}

const LocationContext = createContext<LocationContextType | undefined>(
	undefined,
);

function applyCoords(
	setUserLocation: (v: { lat: number; lng: number }) => void,
	setLocationPinKind: (v: LocationPinKind) => void,
	kind: LocationPinKind,
	lat: number,
	lng: number,
) {
	setUserLocation({ lat, lng });
	setLocationPinKind(kind);
}

export function LocationProvider({ children }: { children: ReactNode }) {
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
	} | null>(RIYADH_FALLBACK);
	const [locationAddress, setLocationAddress] = useState<string | null>(null);
	const [isManualLocation, setIsManualLocation] = useState(false);
	const [locationPinKind, setLocationPinKind] =
		useState<LocationPinKind>("fallback");
	const [locationError, setLocationError] = useState<string | null>(null);

	const requestLocation = useCallback(() => {
		if (!("geolocation" in navigator)) {
			applyCoords(
				setUserLocation,
				setLocationPinKind,
				"fallback",
				RIYADH_FALLBACK.lat,
				RIYADH_FALLBACK.lng,
			);
			return;
		}
		navigator.geolocation.getCurrentPosition(
			(pos) => {
				applyCoords(
					setUserLocation,
					setLocationPinKind,
					"gps",
					pos.coords.latitude,
					pos.coords.longitude,
				);
				setHasLocationPermission(true);
				setIsManualLocation(false);
				safeSet("localStorage", "locationPermission", "granted");
			},
			() => {
				setHasLocationPermission(false);
				safeSet("localStorage", "locationPermission", "denied");
				applyCoords(
					setUserLocation,
					setLocationPinKind,
					"fallback",
					RIYADH_FALLBACK.lat,
					RIYADH_FALLBACK.lng,
				);
			},
			{ enableHighAccuracy: true, timeout: 12_000, maximumAge: 60_000 },
		);
	}, []);

	const setManualLocation = useCallback((lat: number, lng: number) => {
		applyCoords(setUserLocation, setLocationPinKind, "manual", lat, lng);
		setIsManualLocation(true);
		setHasLocationPermission(true);
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
			dismissError: () => setLocationError(null),
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
