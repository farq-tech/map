import { useCallback, useEffect, useRef, useState } from "react";

/**
 * A live GPS fix for the map's "locate me" button.
 *
 * Separate from LocationContext on purpose: that one answers "where should we
 * search from" and holds a Riyadh fallback, which is exactly what a live blue
 * dot must never do. This watch reports only real fixes, or nothing.
 */
export type LiveLocationStatus = "off" | "locating" | "live" | "denied" | "unsupported";
export type LivePosition = { lat: number; lng: number; accuracy: number | null };

export function useLiveLocation() {
	const [status, setStatus] = useState<LiveLocationStatus>("off");
	const [position, setPosition] = useState<LivePosition | null>(null);
	const watchRef = useRef<number | null>(null);

	const clearWatch = useCallback(() => {
		if (watchRef.current == null) return;
		try {
			navigator.geolocation.clearWatch(watchRef.current);
		} catch {
			/* the watch is gone either way */
		}
		watchRef.current = null;
	}, []);

	const stop = useCallback(() => {
		clearWatch();
		setStatus("off");
	}, [clearWatch]);

	const start = useCallback(() => {
		if (typeof navigator === "undefined" || !("geolocation" in navigator)) {
			setStatus("unsupported");
			return;
		}
		if (watchRef.current != null) return;
		setStatus("locating");
		watchRef.current = navigator.geolocation.watchPosition(
			(pos) => {
				const lat = Number(pos.coords.latitude);
				const lng = Number(pos.coords.longitude);
				if (!Number.isFinite(lat) || !Number.isFinite(lng)) return;
				setPosition({ lat, lng, accuracy: Number.isFinite(pos.coords.accuracy) ? pos.coords.accuracy : null });
				setStatus("live");
			},
			(err) => {
				/* A timeout is the watch still trying; only a refusal ends it. */
				if (err?.code === err?.PERMISSION_DENIED) {
					clearWatch();
					setStatus("denied");
				}
			},
			{ enableHighAccuracy: true, maximumAge: 5_000, timeout: 20_000 },
		);
	}, [clearWatch]);

	useEffect(() => clearWatch, [clearWatch]);

	return { status, position, start, stop };
}
