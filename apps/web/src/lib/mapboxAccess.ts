/**
 * Mapbox GL access for Farq maps. Token lives in Frontend/.env.local only.
 * Never invents coordinates; never commits the key.
 */

import mapboxgl from "mapbox-gl";
import type { StyleSpecification } from "mapbox-gl";
import { buildFarqBasemapStyle, type FarqMapLanguage } from "./farqBasemap";

/** Satellite keeps Mapbox imagery — Farq owns the drawn map, not the photo. */
export const MAPBOX_STYLE_SATELLITE =
	"mapbox://styles/mapbox/standard-satellite";

/** Arabic shaping/bidi for map labels — the official plugin, not a text hack. */
const RTL_TEXT_PLUGIN_URL =
	"https://api.mapbox.com/mapbox-gl-js/plugins/mapbox-gl-rtl-text/v0.3.0/mapbox-gl-rtl-text.js";

/** Default cinematic landing — Riyadh launch coverage, not a fake GPS pin. */
export const RIYADH_LNG_LAT: [number, number] = [46.6753, 24.7136];
export const RIYADH_BBOX = "46.45,24.45,47.05,25.05";

export type MapboxBasemap = "standard" | "satellite";

export function getMapboxAccessToken(): string {
	const raw = import.meta.env.VITE_MAPBOX_ACCESS_TOKEN;
	return typeof raw === "string" ? raw.trim() : "";
}

let rtlRequested = false;

/** Idempotent: the plugin may only be registered once per page. */
export function ensureRtlTextPlugin(): void {
	if (rtlRequested) return;
	rtlRequested = true;
	try {
		const status = mapboxgl.getRTLTextPluginStatus?.();
		if (status && status !== "unavailable") return;
		mapboxgl.setRTLTextPlugin(RTL_TEXT_PLUGIN_URL, null, true);
	} catch {
		/* labels still render — Arabic just falls back to unshaped glyphs */
	}
}

export function mapboxStyleUrl(
	kind: MapboxBasemap,
	language: FarqMapLanguage = "ar",
): string | StyleSpecification {
	return kind === "satellite"
		? MAPBOX_STYLE_SATELLITE
		: buildFarqBasemapStyle(language);
}
