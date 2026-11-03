/**
 * One DOM marker per participant, moved by requestAnimationFrame.
 *
 * Where the map can draw models, each participant is a 3D car in their own
 * colour with their name above it; the DOM marker is then only that name.
 * Otherwise it is a face in a ring of their colour.
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
import { snapRadius, snapToRoad } from "../sary/roadSnap";
import { bearingBetween, distanceMeters, ensureVehicleLayer, removeVehicle, setVehicle, setVehicleOpacity, vehicleIds } from "../sary/vehicleLayer";

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
	/** This participant's car colour (same on every device). */
	color: string;
	/** The short line they put over their car, if any. */
	note: string | null;
	/** «رسالة صوتية من سعد» while their push-to-talk clip is news; "playing" while it plays. */
	voice?: { label: string; playing: boolean } | null;
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
	car: boolean;
	heading: number | null;
	onCarClick: (() => void) | null;
	anchor: LngLat;
};

/* Layer-id safe key for a participant's car. */
const carKey = (userId: string) => `peer-${userId.replace(/[^0-9a-z]/gi, "")}`;

function build(view: ParticipantView, onTap: (id: string) => void, onVoiceTap?: (id: string) => void): HTMLElement {
	const el = document.createElement("button");
	el.type = "button";
	el.className = "sary-peer";
	el.dataset.testid = "sary-peer";
	el.dataset.user = view.userId;
	el.innerHTML = `<span class="sary-peer__arrow" aria-hidden="true"></span><span class="sary-peer__face"></span><span class="sary-peer__note" hidden></span><span class="sary-peer__voice" data-testid="sary-peer-voice" hidden></span><span class="sary-peer__name" dir="auto"><i class="sary-peer__dot" aria-hidden="true"></i><b></b></span>`;
	el.addEventListener("click", (e) => {
		e.stopPropagation();
		/* The voice chip plays the clip; the rest of the marker opens the person. */
		if (onVoiceTap && (e.target as HTMLElement | null)?.closest?.(".sary-peer__voice")) return onVoiceTap(view.userId);
		onTap(view.userId);
	});
	return el;
}

function paint(el: HTMLElement, v: ParticipantView, isRTL: boolean): string {
	const sig = [v.name, v.avatar ? v.avatar.length : 0, v.heading ?? "-", v.freshness, v.weak, v.approximate, v.selected, v.color, v.note ?? "", v.voice?.label ?? "", v.voice?.playing ? 1 : 0].join("|");
	if (el.dataset.sig === sig) return sig;
	el.dataset.sig = sig;
	el.dataset.freshness = v.freshness;
	el.classList.toggle("is-weak", v.weak);
	el.classList.toggle("is-approx", v.approximate);
	el.classList.toggle("is-selected", v.selected);
	el.setAttribute("aria-label", v.name);
	el.style.setProperty("--peer-color", v.color);
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
	label.querySelector("b")!.textContent = v.name + tag;
	const note = el.querySelector<HTMLElement>(".sary-peer__note")!;
	note.hidden = !v.note;
	note.textContent = v.note || "";
	note.dir = isRTL ? "rtl" : "ltr";
	const voice = el.querySelector<HTMLElement>(".sary-peer__voice")!;
	voice.hidden = !v.voice;
	voice.textContent = v.voice ? `${v.voice.playing ? "🔊" : "▶"} ${v.voice.label}` : "";
	voice.classList.toggle("is-playing", Boolean(v.voice?.playing));
	voice.dir = isRTL ? "rtl" : "ltr";
	el.setAttribute("aria-label", [v.name, v.note, v.voice?.label].filter(Boolean).join(": "));
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
		private onVoiceTap?: (id: string) => void,
	) {}

	sync(views: ParticipantView[]): void {
		const seen = new Set<string>();
		const now = performance.now();
		for (const v of views) {
			seen.add(v.userId);
			const raw = { lng: v.lng, lat: v.lat };
			/* A confident fix in town is drawn on the street; an approximate one stays a ring where measured. */
			const target = v.approximate ? raw : snapToRoad(this.map, raw, snapRadius(v.accuracyM));
			let rec = this.recs.get(v.userId);
			if (!rec) {
				const el = build(v, this.onTap, this.onVoiceTap);
				/* Anchored at the bottom so a note bubble grows upward, never over the car. */
				const marker = new mapboxgl.Marker({ element: el, anchor: "bottom", offset: [0, 22] }).setLngLat(target).addTo(this.map);
				rec = { marker, el, shown: target, from: target, to: target, start: now, duration: 0, lastAt: v.at, sig: "", car: false, heading: v.heading, anchor: raw, onCarClick: null };
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
			/* Direction: the reported course, else real movement ≥ 12 m; kept while parked. */
			if (v.heading != null) {
				rec.heading = v.heading;
				rec.anchor = raw;
			} else if (distanceMeters(rec.anchor, raw) >= 12) {
				rec.heading = bearingBetween(rec.anchor, raw);
				rec.anchor = raw;
			}
			{
				/* Style reloads drop layers; ensuring again is cheap and idempotent. */
				const car = this.drawCar(v);
				if (car !== rec.car) {
					if (!car) removeVehicle(this.map, carKey(v.userId));
					rec.car = car;
					rec.el.classList.toggle("is-car", car);
					/* Over a car the name floats above it; otherwise the face sits on the point. */
					rec.marker.setOffset(car ? [0, -22] : [0, 22]);
					if (car && !rec.onCarClick) {
						/* Tapping the car itself does what tapping the name does. */
						const id = v.userId;
						rec.onCarClick = () => this.onTap(id);
						this.map.on("click", vehicleIds(carKey(id)).layer, rec.onCarClick);
					}
				}
				if (car) {
					setVehicle(this.map, rec.shown, rec.heading, carKey(v.userId));
					setVehicleOpacity(this.map, carKey(v.userId), v.freshness === "live" ? 1 : v.freshness === "recent" ? 0.7 : 0.4);
				}
			}
			rec.sig = paint(rec.el, v, this.isRTL);
		}
		for (const [id, rec] of this.recs) {
			if (seen.has(id)) continue;
			rec.marker.remove();
			this.dropCar(id, rec);
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
		for (const [id, rec] of this.recs) {
			rec.marker.remove();
			this.dropCar(id, rec);
		}
		this.recs.clear();
	}

	private dropCar(id: string, rec: Rec) {
		if (rec.onCarClick) this.map.off("click", vehicleIds(carKey(id)).layer, rec.onCarClick);
		rec.onCarClick = null;
		if (rec.car) removeVehicle(this.map, carKey(id));
	}

	private drawCar(v: ParticipantView): boolean {
		/* An approximate fix stays a ring: a car there would claim a precision we do not have. */
		if (v.approximate) return false;
		return ensureVehicleLayer(this.map, v.color, carKey(v.userId), v.color);
	}

	private kick() {
		if (this.raf) return;
		const step = () => {
			this.raf = 0;
			const now = performance.now();
			let moving = false;
			for (const [id, rec] of this.recs) {
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
				if (rec.car) {
					try {
						setVehicle(this.map, rec.shown, rec.heading, carKey(id));
					} catch {
						/* style swapped underneath us */
					}
				}
			}
			if (moving) this.raf = requestAnimationFrame(step);
		};
		this.raf = requestAnimationFrame(step);
	}
}
