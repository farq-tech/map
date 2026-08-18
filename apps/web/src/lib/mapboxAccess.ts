/**
 * Mapbox GL access for Farq maps. Token lives in Frontend/.env.local only.
 * Never invents coordinates; never commits the key.
 */

export const MAPBOX_STYLE_STANDARD = "mapbox://styles/mapbox/standard";
export const MAPBOX_STYLE_SATELLITE =
	"mapbox://styles/mapbox/standard-satellite";

/** Default cinematic landing — Riyadh launch coverage, not a fake GPS pin. */
export const RIYADH_LNG_LAT: [number, number] = [46.6753, 24.7136];
export const RIYADH_BBOX = "46.45,24.45,47.05,25.05";

export type MapboxBasemap = "standard" | "satellite";

export function getMapboxAccessToken(): string {
	const raw = import.meta.env.VITE_MAPBOX_ACCESS_TOKEN;
	return typeof raw === "string" ? raw.trim() : "";
}

export function mapboxStyleUrl(kind: MapboxBasemap): string {
	return kind === "satellite" ? MAPBOX_STYLE_SATELLITE : MAPBOX_STYLE_STANDARD;
}
