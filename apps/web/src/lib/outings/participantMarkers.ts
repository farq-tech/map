/**
 * One DOM marker per participant, moved by requestAnimationFrame.
 *
 * DOM markers rather than a symbol layer: an outing is capped at 50 people,
 * and a marker needs a face, a name, a heading arrow and a freshness state —
 * all cheap in CSS and awkward as sprites. The animation only interpolates
 * between real fixes (see motion.ts); it never runs ahead of one.
 */

import mapboxgl from "mapbox-gl";
import type { Map as MapboxMap } from "mapbox-gl";
import { haversineMeters } from "../sary/domain";
import { lerp, tweenMs, type LngLat } from "./motion";
import { initials, type Freshness } from "./policy";

export type ParticipantView = {
	userId: string;
	name: string;
	avatar: string | null;
	lng: number;
	lat: number;
	/** Server receive time of this fix (ms, server clock). */
	at: number;
	heading: number | null;
	accuracyM: number | null;
	freshness: Freshness;
	/** Accuracy worse than 60 m: drawn as an approximate position, never animated. */
	approximate: boolean;
	weak: boolean;
	selected: boolean;
};

type Rec = {
	marker: mapboxgl.Marker;
	el: HTMLElement;
	shown: LngLat;
	from: LngLat;
	to: LngLat;
	start: number;
	duration: number;
	lastAt: number;
	sig: string;
};

function build(view: ParticipantView, onTap: (id: string) => void): HTMLElement {
	const el = document.createElement("button");
	el.type = "button";
	el.className = "sary-peer";
	el.dataset.testid = "sary-peer";
	el.dataset.user = view.userId;
	el.innerHTML = `<span class="sary-peer__arrow" aria-hidden="true"></span><span class="sary-peer__face"></span><span class="sary-peer__name" dir="auto"></span>`;
	el.addEventListener("click", (e) => {
		e.stopPropagation();
		onTap(view.userId);
	});
	return el;
}

function paint(el: HTMLElement, v: ParticipantView, isRTL: boolean): string {
	const sig = [v.name, v.avatar ? v.avatar.length : 0, v.heading ?? "-", v.freshness, v.weak, v.approximate, v.selected].join("|");
	if (el.dataset.sig === sig) return sig;
	el.dataset.sig = sig;
	el.dataset.freshness = v.freshness;
	el.classList.toggle("is-weak", v.weak);
	el.classList.toggle("is-approx", v.approximate);
	el.classList.toggle("is-selected", v.selected);
	el.setAttribute("aria-label", v.name);
	const face = el.querySelector<HTMLElement>(".sary-peer__face")!;
	if (v.avatar) {
		face.textContent = "";
		face.style.backgroundImage = `url("${v.avatar}")`;
	} else {
		face.style.backgroundImage = "";
		face.textContent = initials(v.name);
	}
	/* Said in words, not only colour: the map sits inside an LTR root, so the label is set here. */
	const tag =
		v.freshness === "recent" ? (isRTL ? " · آخر موقع" : " · last known") : v.freshness === "lost" ? (isRTL ? " · انقطع" : " · lost") : v.approximate ? (isRTL ? " · تقريبي" : " · approx.") : "";
	const label = el.querySelector<HTMLElement>(".sary-peer__name")!;
	label.textContent = v.name + tag;
	label.dir = isRTL ? "rtl" : "ltr";
	const arrow = el.querySelector<HTMLElement>(".sary-peer__arrow")!;
	if (v.heading == null || v.freshness !== "live" || v.approximate) {
		arrow.hidden = true;
	} else {
		arrow.hidden = false;
		arrow.style.transform = `rotate(${v.heading}deg)`;
	}
	return sig;
}

export class ParticipantMarkers {
	private recs = new Map<string, Rec>();
	private raf = 0;

	constructor(
		private map: MapboxMap,
		private onTap: (id: string) => void,
		private reducedMotion = () => false,
		private isRTL = true,
	) {}

	sync(views: ParticipantView[]): void {
		const seen = new Set<string>();
		const now = performance.now();
		for (const v of views) {
			seen.add(v.userId);
			const target = { lng: v.lng, lat: v.lat };
			let rec = this.recs.get(v.userId);
			if (!rec) {
				const el = build(v, this.onTap);
				const marker = new mapboxgl.Marker({ element: el, anchor: "center" }).setLngLat(target).addTo(this.map);
				rec = { marker, el, shown: target, from: target, to: target, start: now, duration: 0, lastAt: v.at, sig: "" };
				this.recs.set(v.userId, rec);
			} else if (target.lng !== rec.to.lng || target.lat !== rec.to.lat) {
				const gap = v.at - rec.lastAt;
				rec.from = { ...rec.shown };
				rec.to = target;
				rec.start = now;
				/* Only a confident, live fix glides; anything else is placed exactly where it was measured. */
				rec.duration = v.approximate || v.freshness !== "live" ? 0 : tweenMs(gap, haversineMeters(rec.shown, target), this.reducedMotion());
				rec.lastAt = v.at;
				if (!rec.duration) {
					rec.shown = target;
					rec.marker.setLngLat(target);
				}
			}
			rec.sig = paint(rec.el, v, this.isRTL);
		}
		for (const [id, rec] of this.recs) {
			if (seen.has(id)) continue;
			rec.marker.remove();
			this.recs.delete(id);
		}
		this.kick();
	}

	/** Where a marker is drawn right now (for fit-bounds and tests). */
	shownPosition(userId: string): LngLat | null {
		return this.recs.get(userId)?.shown ?? null;
	}

	destroy(): void {
		cancelAnimationFrame(this.raf);
		for (const rec of this.recs.values()) rec.marker.remove();
		this.recs.clear();
	}

	private kick() {
		if (this.raf) return;
		const step = () => {
			this.raf = 0;
			const now = performance.now();
			let moving = false;
			for (const rec of this.recs.values()) {
				if (!rec.duration) continue;
				const t = (now - rec.start) / rec.duration;
				if (t >= 1) {
					rec.shown = rec.to;
					rec.duration = 0;
				} else {
					rec.shown = lerp(rec.from, rec.to, t);
					moving = true;
				}
				rec.marker.setLngLat(rec.shown);
			}
			if (moving) this.raf = requestAnimationFrame(step);
		};
		this.raf = requestAnimationFrame(step);
	}
}
