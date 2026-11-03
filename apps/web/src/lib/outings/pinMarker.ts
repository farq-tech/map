/**
 * Fixed pins on the outing map: the owner's rally point and the last real fix
 * of anyone who raised an SOS. DOM markers, like participants, so they can
 * carry a label and stay readable over satellite imagery.
 */

import mapboxgl from "mapbox-gl";
import type { Map as MapboxMap } from "mapbox-gl";

export type MapPin = {
	id: string;
	kind: "rally" | "sos";
	lat: number;
	lng: number;
	label: string;
};

export class PinMarkers {
	private recs = new Map<string, { marker: mapboxgl.Marker; el: HTMLElement; sig: string; pin: MapPin }>();

	constructor(
		private map: MapboxMap,
		private onTap: (pin: MapPin) => void,
	) {}

	sync(pins: MapPin[]): void {
		const keep = new Set(pins.map((p) => p.id));
		for (const [id, r] of this.recs) {
			if (keep.has(id)) continue;
			r.marker.remove();
			this.recs.delete(id);
		}
		for (const p of pins) {
			const sig = `${p.kind}|${p.label}`;
			let r = this.recs.get(p.id);
			if (!r) {
				const el = document.createElement("button");
				el.type = "button";
				el.className = "sary-pin";
				el.dataset.testid = p.kind === "rally" ? "outing-rally-pin" : "outing-sos-pin";
				el.innerHTML = `<span class="sary-pin__label" dir="auto"></span><span class="sary-pin__head" aria-hidden="true"></span>`;
				el.addEventListener("click", (e) => {
					e.stopPropagation();
					const r = this.recs.get(p.id);
					if (r) this.onTap(r.pin);
				});
				const marker = new mapboxgl.Marker({ element: el, anchor: "bottom" }).setLngLat([p.lng, p.lat]).addTo(this.map);
				r = { marker, el, sig: "", pin: p };
				this.recs.set(p.id, r);
			}
			r.pin = p;
			r.marker.setLngLat([p.lng, p.lat]);
			if (r.sig !== sig) {
				r.sig = sig;
				r.el.dataset.kind = p.kind;
				r.el.setAttribute("aria-label", p.label);
				r.el.querySelector(".sary-pin__label")!.textContent = p.label;
				r.el.querySelector(".sary-pin__head")!.textContent = p.kind === "rally" ? "⚑" : "SOS";
			}
		}
	}

	destroy(): void {
		for (const r of this.recs.values()) r.marker.remove();
		this.recs.clear();
	}
}
