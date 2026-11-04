import mapboxgl from "mapbox-gl";
import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useRef } from "react";
import { MAPBOX_STYLE_STANDARD, ensureRtlTextPlugin, getMapboxAccessToken } from "../../lib/mapboxAccess";
import { ago } from "../../lib/outings/watch";

type Point = { name: string; lat: number; lng: number; at: string };

/**
 * The last-known positions on a small map — shown ONLY once the return timer
 * is overdue, and only the snapshot the server took at that moment. Each pin
 * carries its own age («قبل ٢٠ دقيقة»); nothing here is drawn as live.
 */
export default function WatchMap({ points }: { points: Point[] }) {
	const host = useRef<HTMLDivElement | null>(null);
	const token = getMapboxAccessToken();

	useEffect(() => {
		if (!host.current || !token || !points.length) return;
		ensureRtlTextPlugin();
		mapboxgl.accessToken = token;
		const map = new mapboxgl.Map({
			container: host.current,
			style: MAPBOX_STYLE_STANDARD,
			center: [points[0].lng, points[0].lat],
			zoom: 11,
			attributionControl: { compact: true } as unknown as boolean,
			cooperativeGestures: true,
		});
		const markers: mapboxgl.Marker[] = [];
		for (const p of points) {
			const el = document.createElement("div");
			el.className = "sary-watch-pin";
			const name = document.createElement("strong");
			name.textContent = p.name;
			const when = document.createElement("span");
			when.textContent = ago(p.at);
			el.append(name, when);
			markers.push(new mapboxgl.Marker({ element: el, anchor: "bottom" }).setLngLat([p.lng, p.lat]).addTo(map));
		}
		if (points.length > 1) {
			const b = new mapboxgl.LngLatBounds();
			for (const p of points) b.extend([p.lng, p.lat]);
			map.fitBounds(b, { padding: 60, maxZoom: 13, duration: 0 });
		}
		return () => {
			for (const m of markers) m.remove();
			map.remove();
		};
	}, [token, points]);

	if (!token) return null;
	return <div ref={host} className="sary-watch-map" data-testid="watch-map" aria-label="آخر موقع معروف على الخريطة" />;
}
