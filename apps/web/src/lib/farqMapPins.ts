/**
 * Farq map pin builders — Mapbox HTML markers overlaid on the existing map.
 * Gap places become Price Difference Bubbles. No-gap places stay initials.
 * Clusters stay the existing count orbs. Logos are never invented.
 *
 * Size uses the observed difference_amount only (no Math.abs, no invented gaps).
 */
import { localizeDigitString } from "./formatPrice";
import {
	getProviderLabel,
	getProviderLogo,
	normalizePlatformKey,
} from "./platformLogos";

export const FARQ_CLUSTERS_CLASS = "farq-clusters";
export const PIN_OTHERS_MAX = 3;

/** Mobile-tuned: 3 SAR stays small, 18 SAR is near the ceiling. */
export const BUBBLE_SIZE_MIN = 26;
export const BUBBLE_SIZE_MAX = 52;
export const BUBBLE_SIZE_BASE = 18;
export const BUBBLE_SIZE_SCALE = 8;
export const BUBBLE_CURRENCY_MIN_PX = 38;
export const BUBBLE_CLEAR_CHANGE = 1;
export const BUBBLE_ENTER_STAGGER_MAX = 16;
export const BUBBLE_ENTER_MS = 320;

/** Winner pin scale leftover — restaurant initials still use a readable floor. */
export type PinSizeTier = "sm" | "md" | "lg";

export function pinSizeTier(amount: unknown): PinSizeTier {
	const n = Number(amount);
	if (!Number.isFinite(n) || n <= 0) return "md";
	if (n < 15) return "sm";
	if (n < 50) return "md";
	return "lg";
}

export function parseDifference(raw: unknown): {
	difference_amount?: number | null;
	cheapest_provider_id?: string | null;
	expensive_provider_id?: string | null;
	product_name?: string | null;
	provider_count?: number | null;
} | null {
	if (raw == null) return null;
	if (typeof raw === "string") {
		try {
			return parseDifference(JSON.parse(raw));
		} catch {
			return null;
		}
	}
	if (typeof raw !== "object") return null;
	return raw as {
		difference_amount?: number | null;
		cheapest_provider_id?: string | null;
		expensive_provider_id?: string | null;
		product_name?: string | null;
		provider_count?: number | null;
	};
}

/**
 * Observed numeric gap the map already carries. Missing, 0, or sub-riyal
 * rounds never become a bubble (never +0 / +?).
 */
export function observedDifferenceAmount(raw: unknown): number | null {
	const n = Number(parseDifference(raw)?.difference_amount);
	if (!Number.isFinite(n) || n <= 0) return null;
	if (Math.round(n) < 1) return null;
	return n;
}

/** size = clamp(MIN, BASE + sqrt(diff) * SCALE, MAX) */
export function bubbleSizePx(diff: number): number {
	const size = BUBBLE_SIZE_BASE + Math.sqrt(diff) * BUBBLE_SIZE_SCALE;
	return Math.max(BUBBLE_SIZE_MIN, Math.min(BUBBLE_SIZE_MAX, size));
}

export function bubbleZIndex(amount: number, selected = false): number {
	const ranked = 100 + Math.round(amount);
	return selected ? 10_000 + ranked : ranked;
}

export function displayGapRiyals(amount: number): number {
	return Math.max(1, Math.round(amount));
}

export function prefersMapMotionReduce(): boolean {
	return Boolean(
		typeof window !== "undefined" &&
			window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches,
	);
}

export function shouldReplayBubbleMotion(
	placeId: string,
	amount: number,
	prev: Map<string, number>,
): boolean {
	const old = prev.get(placeId);
	if (old == null) return true;
	return Math.abs(amount - old) >= BUBBLE_CLEAR_CHANGE;
}

export function playBubbleEnter(el: HTMLElement, delayMs = 0): void {
	if (prefersMapMotionReduce()) return;
	el.classList.add("farq-gap-bubble--enter");
	if (delayMs > 0) {
		el.style.setProperty("--farq-enter-delay", `${delayMs}ms`);
	}
	const done = () => {
		el.classList.remove("farq-gap-bubble--enter");
		el.style.removeProperty("--farq-enter-delay");
	};
	el.addEventListener("animationend", done, { once: true });
}

export function playMaxGapPulse(el: HTMLElement): void {
	if (prefersMapMotionReduce()) return;
	el.classList.remove("farq-gap-bubble--pulse");
	void el.offsetWidth;
	el.classList.add("farq-gap-bubble--pulse");
	el.addEventListener(
		"animationend",
		() => {
			el.classList.remove("farq-gap-bubble--pulse");
		},
		{ once: true },
	);
}

export type ResolvedPinLogo = {
	src: string;
	label: string;
	labelAr: string;
	providerId: string;
};

export type ResolvedPinMark = {
	src: string | null;
	label: string;
	labelAr: string;
	providerId: string;
	initial: string;
};

export type ResolvedPlacePins = {
	winner: ResolvedPinLogo | null;
	others: ResolvedPinMark[];
	extraCount: number;
};

function trimId(value: unknown): string {
	return String(value || "").trim();
}

function dedupeKey(providerId: string): string {
	return normalizePlatformKey(providerId) || providerId.toLowerCase();
}

/** First letter from getProviderLabel — never a invented CDN URL. */
export function providerPinInitial(
	providerId: string,
	isRTL = false,
): string {
	const label = getProviderLabel(providerId, { isRTL });
	const raw = String(label || providerId || "?").trim();
	return (raw.charAt(0) || "?").toUpperCase();
}

/** Restaurant-name initial for pins with no cheapest-app logo — never «ف». */
export function restaurantPinInitial(name: string): string {
	const raw = String(name || "").trim();
	if (!raw) return "•";
	return (raw.charAt(0) || "•").toUpperCase();
}

function resolvePinMark(providerId: string): ResolvedPinMark | null {
	const id = trimId(providerId);
	if (!id) return null;
	const logo = getProviderLogo(id);
	const label = logo?.label || getProviderLabel(id) || id;
	const labelAr = logo?.labelAr || getProviderLabel(id, { isRTL: true }) || id;
	return {
		src: logo?.src || null,
		label,
		labelAr,
		providerId: id,
		initial: providerPinInitial(id),
	};
}

/**
 * Honest cheapest-app mark for a Golden place pin.
 * Missing cheapest_provider_id or unknown code → null (Farq placeholder).
 */
export function resolveCheapestPinLogo(
	difference: unknown,
): ResolvedPinLogo | null {
	const diff = parseDifference(difference);
	const providerId = trimId(diff?.cheapest_provider_id);
	if (!providerId) return null;
	const logo = getProviderLogo(providerId);
	if (!logo?.src) return null;
	return {
		src: logo.src,
		label: logo.label,
		labelAr: logo.labelAr,
		providerId,
	};
}

/**
 * Winner (known cheapest logo) + other real ids (expensive) + honest +N.
 * Never pads with fake logos. +N only when provider_count exceeds shown ids.
 */
export function resolvePlacePinMarks(
	difference: unknown,
	providerCount?: number | null,
): ResolvedPlacePins {
	const diff = parseDifference(difference);
	const cheapestId = trimId(diff?.cheapest_provider_id);
	const expensiveId = trimId(diff?.expensive_provider_id);
	const winnerLogo = resolveCheapestPinLogo(diff);

	const seen = new Set<string>();
	if (cheapestId) seen.add(dedupeKey(cheapestId));

	const others: ResolvedPinMark[] = [];
	if (expensiveId) {
		const key = dedupeKey(expensiveId);
		if (!seen.has(key)) {
			const mark = resolvePinMark(expensiveId);
			if (mark) {
				others.push(mark);
				seen.add(key);
			}
		}
	}

	const shownOthers = others.slice(0, PIN_OTHERS_MAX);
	const overflow = Math.max(0, others.length - PIN_OTHERS_MAX);

	const countRaw = Number(
		providerCount ?? diff?.provider_count ?? Number.NaN,
	);
	const extrasFromCount =
		Number.isFinite(countRaw) && countRaw > seen.size
			? Math.round(countRaw) - seen.size
			: 0;

	const hasRealId = Boolean(winnerLogo || shownOthers.length);
	return {
		winner: winnerLogo,
		others: shownOthers,
		extraCount: hasRealId ? extrasFromCount + overflow : 0,
	};
}

export function featureMarkerKey(
	feature: GeoJSON.Feature,
): string | null {
	const geom = feature.geometry;
	if (!geom || geom.type !== "Point" || !Array.isArray(geom.coordinates)) {
		return null;
	}
	const [lng, lat] = geom.coordinates;
	if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
	const props = (feature.properties || {}) as {
		feature_type?: string;
		place_id?: string;
		count?: number;
		difference?: unknown;
	};
	if (props.feature_type === "cluster") {
		return `cluster:${Number(lng).toFixed(5)}:${Number(lat).toFixed(5)}:${props.count ?? 0}`;
	}
	const placeId = String(props.place_id || "").trim();
	if (!placeId) return null;
	const amount = observedDifferenceAmount(props.difference);
	if (amount != null) {
		return `place:${placeId}:bubble:${displayGapRiyals(amount)}`;
	}
	return `place:${placeId}:restaurant`;
}

function attachInitial(host: HTMLElement, text: string, className: string): void {
	host.classList.add("farq-3d-pin-badge--mark");
	if (host.querySelector(`.${className}`)) return;
	const initial = document.createElement("span");
	initial.className = className;
	initial.textContent = text;
	host.appendChild(initial);
}

function gapBubbleAriaLabel(
	name: string,
	riyal: number,
	isRTL: boolean,
): string {
	const digits = localizeDigitString(String(riyal), isRTL);
	const title = name || (isRTL ? "مكان" : "Place");
	return isRTL
		? `فرق السعر ${digits} ريال في ${title}`
		: `Price difference ${riyal} riyals at ${title}`;
}

export function buildGapBubbleElement(opts: {
	name: string;
	amount: number;
	selected?: boolean;
	isRTL?: boolean;
}): HTMLDivElement {
	const isRTL = Boolean(opts.isRTL);
	const riyal = displayGapRiyals(opts.amount);
	const size = bubbleSizePx(opts.amount);
	const showCurrency = size >= BUBBLE_CURRENCY_MIN_PX;
	const compact = showCurrency && size < 46;
	const digits = localizeDigitString(String(riyal), isRTL);
	const currency = isRTL ? "ر.س" : "SAR";

	const el = document.createElement("div");
	el.className = "farq-gap-bubble";
	if (opts.selected) el.classList.add("is-selected");
	if (!showCurrency) el.classList.add("farq-gap-bubble--tiny");
	else if (compact) el.classList.add("farq-gap-bubble--compact");
	else el.classList.add("farq-gap-bubble--stacked");
	el.dataset.testid = "farq-map-gap-bubble";
	el.dataset.amount = String(riyal);
	el.dataset.size = String(Math.round(size));
	el.style.setProperty("--farq-bubble-size", `${size}px`);
	el.style.zIndex = String(bubbleZIndex(opts.amount, Boolean(opts.selected)));
	el.setAttribute("role", "button");
	el.setAttribute("aria-label", gapBubbleAriaLabel(opts.name, riyal, isRTL));
	el.title = gapBubbleAriaLabel(opts.name, riyal, isRTL);

	const orb = document.createElement("div");
	orb.className = "farq-gap-bubble-orb";
	orb.setAttribute("aria-hidden", "true");

	const amountEl = document.createElement("span");
	amountEl.className = "farq-gap-bubble-amount";
	amountEl.textContent = `+${digits}`;
	orb.appendChild(amountEl);

	if (showCurrency) {
		const currencyEl = document.createElement("span");
		currencyEl.className = "farq-gap-bubble-currency";
		currencyEl.textContent = currency;
		orb.appendChild(currencyEl);
	}

	const stem = document.createElement("div");
	stem.className = "farq-gap-bubble-stem";
	stem.setAttribute("aria-hidden", "true");

	el.appendChild(orb);
	el.appendChild(stem);
	return el;
}

function buildRestaurantInitialsPin(opts: {
	name: string;
	selected?: boolean;
	isRTL?: boolean;
}): HTMLDivElement {
	const isRTL = Boolean(opts.isRTL);
	const el = document.createElement("div");
	el.className = "farq-3d-pin farq-3d-pin--sm farq-3d-pin--restaurant";
	if (opts.selected) el.classList.add("is-selected");
	el.dataset.size = "sm";
	el.dataset.testid = "farq-map-restaurant-pin";

	const title = opts.name || (isRTL ? "مكان" : "Place");
	el.title = title;
	el.setAttribute("role", "button");
	el.setAttribute("aria-label", title);

	const shadow = document.createElement("div");
	shadow.className = "farq-3d-pin-shadow";
	shadow.setAttribute("aria-hidden", "true");

	const scene = document.createElement("div");
	scene.className = "farq-3d-pin-scene";

	const badge = document.createElement("div");
	badge.className = "farq-3d-pin-badge farq-3d-pin-badge--winner";
	attachInitial(badge, restaurantPinInitial(opts.name), "farq-3d-pin-initial");

	const stem = document.createElement("div");
	stem.className = "farq-3d-pin-stem";
	stem.setAttribute("aria-hidden", "true");
	const sig = document.createElement("span");
	sig.className = "farq-3d-pin-stem-shine";
	stem.appendChild(sig);

	scene.appendChild(badge);
	scene.appendChild(stem);
	el.appendChild(shadow);
	el.appendChild(scene);
	return el;
}

export function buildPlacePinElement(opts: {
	name: string;
	difference: unknown;
	providerCount?: number | null;
	selected?: boolean;
	isRTL?: boolean;
}): HTMLDivElement {
	const amount = observedDifferenceAmount(opts.difference);
	if (amount != null) {
		return buildGapBubbleElement({
			name: opts.name,
			amount,
			selected: opts.selected,
			isRTL: opts.isRTL,
		});
	}
	return buildRestaurantInitialsPin({
		name: opts.name,
		selected: opts.selected,
		isRTL: opts.isRTL,
	});
}

export function buildClusterPinElement(opts: {
	count: number;
	differenceCount?: number;
	isRTL?: boolean;
}): HTMLDivElement {
	const count = Number.isFinite(opts.count) ? Math.max(0, Math.round(opts.count)) : 0;
	const el = document.createElement("div");
	el.className = `farq-3d-cluster ${FARQ_CLUSTERS_CLASS}`;
	if ((opts.differenceCount || 0) > 0) {
		el.classList.add("farq-3d-cluster--gaps");
	}
	el.dataset.testid = "farq-map-cluster";
	el.setAttribute("role", "button");
	el.setAttribute(
		"aria-label",
		opts.isRTL ? `تجمّع ${count} أماكن` : `Cluster of ${count} places`,
	);

	const shadow = document.createElement("div");
	shadow.className = "farq-3d-cluster-shadow";
	shadow.setAttribute("aria-hidden", "true");

	const orb = document.createElement("div");
	orb.className = "farq-3d-cluster-orb";
	const label = document.createElement("span");
	label.className = "farq-3d-cluster-count";
	label.textContent = String(count);
	orb.appendChild(label);

	el.appendChild(shadow);
	el.appendChild(orb);
	return el;
}

export function setPinSelected(el: HTMLElement, selected: boolean): void {
	el.classList.toggle("is-selected", selected);
	if (!el.classList.contains("farq-gap-bubble")) return;
	const amount = Number(el.dataset.amount);
	if (!Number.isFinite(amount) || amount <= 0) return;
	el.style.zIndex = String(bubbleZIndex(amount, selected));
}
