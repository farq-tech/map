/**
 * Farq map pin builders — Mapbox HTML markers overlaid on the existing map.
 * Restaurant circular photo is the hero. comparison-map maps
 * discovery_cards.branch_image_url → feature image_url (also reads
 * branch_image_url and sibling restaurant_* fields if present).
 * Never invent CDN/Unsplash URLs. Missing image → restaurant initials.
 * Observed gaps keep a small Price Aura chip (size ∝ difference_amount).
 * Missing gap → restaurant mark only (never +0). Official Farq stem stays tiny.
 * Provider app logos stay in SelectedPlaceSheet, never on the pin.
 */
import { buildFarqCircleMarkElement } from "./farqBrandAssets";
import { localizeDigitString } from "./formatPrice";
import {
	getProviderLabel,
	getProviderLogo,
	normalizePlatformKey,
} from "./platformLogos";

export const FARQ_CLUSTERS_CLASS = "farq-clusters";
export const PIN_OTHERS_MAX = 3;

/** Mobile-tuned: +3 / +7 / +12 / +18 stay distinct without covering the map. */
export const BUBBLE_SIZE_MIN = 26;
export const BUBBLE_SIZE_MAX = 52;
export const BUBBLE_SIZE_BASE = 18;
export const BUBBLE_SIZE_SCALE = 8;
export const BUBBLE_CURRENCY_MIN_PX = 38;
export const BUBBLE_CLEAR_CHANGE = 1;
export const BUBBLE_ENTER_STAGGER_MAX = 16;
export const BUBBLE_ENTER_MS = 360;
export const BUBBLE_ENTER_SCALE_FROM = 0.82;

/** Restaurant disc — always smaller than the difference chip. */
export const MARK_SIZE_MIN = 16;
export const MARK_SIZE_MAX = 28;
export const MARK_SIZE_RATIO = 0.52;
export const PIN_THUMB_CSS_PX = 28;

/** Circular restaurant hero — identity stays larger than the aura chip. */
export const PLACE_HERO_PX = 56;

/** GeoJSON fields that may already carry a real restaurant/branch photo. */
export const RESTAURANT_IMAGE_FIELDS = [
	"image_url",
	"branch_image_url",
	"restaurant_logo_url",
	"restaurant_image_url",
	"restaurant_image",
] as const;

const CLOUDINARY_FETCH_BLOCKED = ["cdngrubtech.com"] as const;

/** After pan/zoom STOP — rank loaded markers only (no extra API fetch). */
export const AURA_VIEWPORT_IDLE_MS = 180;
export const AURA_PROMOTE_MIN = 8;
export const AURA_PROMOTE_MAX = 12;

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

export function bubbleZIndex(
	amount: number,
	selected = false,
	promoted = false,
): number {
	const ranked = 100 + Math.round(amount);
	if (selected) return 10_000 + ranked;
	if (promoted) return 500 + ranked;
	return ranked;
}

export type AuraRank = "promoted" | "demoted";

/** Promote every visible aura up to MAX; beyond that keep the top MAX. */
export function promotedAuraLimit(visibleCount: number): number {
	if (visibleCount <= 0) return 0;
	if (visibleCount <= AURA_PROMOTE_MAX) return visibleCount;
	return AURA_PROMOTE_MAX;
}

export function rankAuraPlaceIds(
	items: { placeId: string; amount: number }[],
	limit = promotedAuraLimit(items.length),
): Set<string> {
	const ranked = items
		.filter((item) => Number.isFinite(item.amount) && item.amount > 0)
		.sort((a, b) => b.amount - a.amount || a.placeId.localeCompare(b.placeId));
	return new Set(ranked.slice(0, Math.max(0, limit)).map((item) => item.placeId));
}

export function applyAuraRankClasses(el: HTMLElement, rank: AuraRank): void {
	el.classList.toggle("farq-gap-bubble--promoted", rank === "promoted");
	el.classList.toggle("farq-gap-bubble--demoted", rank === "demoted");
	el.dataset.rank = rank;
	if (!el.classList.contains("farq-gap-bubble")) return;
	const amount = Number(el.dataset.amount);
	if (!Number.isFinite(amount) || amount <= 0) return;
	el.style.zIndex = String(
		bubbleZIndex(amount, el.classList.contains("is-selected"), rank === "promoted"),
	);
}

/**
 * Observed max gap already on a server cluster. Never invents a number from count.
 */
export function observedClusterTopGap(raw: {
	difference?: unknown;
	max_difference_amount?: unknown;
	top_difference_amount?: unknown;
} | null | undefined): number | null {
	if (raw == null) return null;
	const fromDifference = observedDifferenceAmount(raw.difference);
	if (fromDifference != null) return fromDifference;
	for (const value of [raw.max_difference_amount, raw.top_difference_amount]) {
		const n = Number(value);
		if (!Number.isFinite(n) || n <= 0) continue;
		if (Math.round(n) < 1) continue;
		return n;
	}
	return null;
}

export function clusterOpportunityCount(opts: {
	count: number;
	differenceCount?: number;
}): number {
	const diffs = Number(opts.differenceCount);
	if (Number.isFinite(diffs) && diffs > 0) return Math.round(diffs);
	const count = Number(opts.count);
	return Number.isFinite(count) ? Math.max(0, Math.round(count)) : 0;
}

export function clusterOpportunityLabel(count: number, isRTL: boolean): string {
	const n = Math.max(0, Math.round(count));
	const digits = localizeDigitString(String(n), isRTL);
	return isRTL ? `${digits} فرصة` : `${n} opps`;
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

/** Accept only real http(s) or same-origin paths. Never invent a CDN URL. */
export function sanitizeObservedImageUrl(raw: unknown): string | null {
	const url = String(raw || "").trim();
	if (!url) return null;
	if (/^(javascript|data|blob):/i.test(url)) return null;
	if (url.startsWith("//") && url.length > 3) return `https:${url}`;
	if (/^https?:\/\//i.test(url) || url.startsWith("/")) return url;
	return null;
}

export function observedRestaurantImageUrl(
	props: Record<string, unknown> | null | undefined,
): string | null {
	if (props == null || typeof props !== "object") return null;
	for (const key of RESTAURANT_IMAGE_FIELDS) {
		const url = sanitizeObservedImageUrl(props[key]);
		if (url) return url;
	}
	return null;
}

export function restaurantMarkSizePx(bubbleSize: number): number {
	const sized = Number(bubbleSize) * MARK_SIZE_RATIO;
	const capped = Math.min(MARK_SIZE_MAX, sized, Math.max(0, Number(bubbleSize) - 8));
	return Math.max(MARK_SIZE_MIN, capped);
}

export function restaurantImageCoverage(
	features: Array<{ properties?: Record<string, unknown> | null }>,
): { total: number; withImage: number; withoutImage: number } {
	let withImage = 0;
	let withoutImage = 0;
	for (const feature of features) {
		const props = feature.properties;
		if (!props || props.feature_type === "cluster") continue;
		if (observedRestaurantImageUrl(props)) withImage += 1;
		else withoutImage += 1;
	}
	return { total: withImage + withoutImage, withImage, withoutImage };
}

function viteCloudName(): string {
	try {
		const env = (
			import.meta as { env?: { VITE_CLOUDINARY_CLOUD_NAME?: string } }
		).env;
		return String(env?.VITE_CLOUDINARY_CLOUD_NAME || "").trim();
	} catch {
		return "";
	}
}

function cloudinaryHostBlocked(url: string): boolean {
	try {
		const host = new URL(url).hostname.toLowerCase();
		return CLOUDINARY_FETCH_BLOCKED.some(
			(blocked) => host === blocked || host.endsWith(`.${blocked}`),
		);
	} catch {
		return false;
	}
}

/** Small thumb of an already-observed URL. Never invents a source. */
export function pinThumbSrc(url: string, cssPx = PIN_THUMB_CSS_PX): string {
	const cloud = viteCloudName();
	if (!cloud || url.includes("res.cloudinary.com")) return url;
	if (!/^https?:\/\//i.test(url)) return url;
	if (cloudinaryHostBlocked(url)) return url;
	const w = Math.max(16, Math.round(cssPx * 2));
	const t = `w_${w},h_${w},c_fill,f_auto,q_auto`;
	return `https://res.cloudinary.com/${cloud}/image/fetch/${t}/${encodeURIComponent(url)}`;
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
	const props = (feature.properties || {}) as Record<string, unknown> & {
		feature_type?: string;
		place_id?: string;
		count?: number;
		difference_count?: number;
		difference?: unknown;
		max_difference_amount?: unknown;
		top_difference_amount?: unknown;
	};
	if (props.feature_type === "cluster") {
		const top = observedClusterTopGap(props);
		return `cluster:${Number(lng).toFixed(5)}:${Number(lat).toFixed(5)}:${props.count ?? 0}:${props.difference_count ?? 0}:${top != null ? displayGapRiyals(top) : 0}`;
	}
	const placeId = String(props.place_id || "").trim();
	if (!placeId) return null;
	const imgKey = observedRestaurantImageUrl(props) ? "logo" : "mark";
	const amount = observedDifferenceAmount(props.difference);
	if (amount != null) {
		return `place:${placeId}:bubble:${displayGapRiyals(amount)}:${imgKey}`;
	}
	return `place:${placeId}:restaurant:${imgKey}`;
}

function hideBrokenPinImage(img: HTMLImageElement): void {
	img.onerror = null;
	img.removeAttribute("src");
	img.style.display = "none";
	img.remove();
}

function attachRestaurantPhoto(
	host: HTMLElement,
	opts: { imageUrl: string; cssPx: number },
): void {
	const img = document.createElement("img");
	img.className = "farq-pin-photo";
	img.alt = "";
	img.draggable = false;
	img.decoding = "async";
	img.loading = "lazy";
	img.width = Math.round(opts.cssPx);
	img.height = Math.round(opts.cssPx);
	img.referrerPolicy = "no-referrer";
	img.addEventListener("error", () => hideBrokenPinImage(img), { once: true });
	img.src = opts.imageUrl;
	host.appendChild(img);
}

function buildRestaurantHero(opts: {
	name: string;
	imageUrl?: string | null;
}): HTMLDivElement {
	const hero = document.createElement("div");
	hero.className = "farq-place-pin-hero farq-gap-bubble-mark";
	hero.setAttribute("aria-hidden", "true");
	hero.dataset.testid = "farq-map-restaurant-mark";
	const initial = document.createElement("span");
	initial.className = "farq-place-pin-initial farq-gap-bubble-mark-initial farq-3d-pin-initial";
	initial.textContent = restaurantPinInitial(opts.name);
	hero.appendChild(initial);
	const url = sanitizeObservedImageUrl(opts.imageUrl);
	if (url) {
		hero.dataset.kind = "photo";
		attachRestaurantPhoto(hero, { imageUrl: url, cssPx: PLACE_HERO_PX });
	} else {
		hero.dataset.kind = "initials";
	}
	return hero;
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
	imageUrl?: string | null;
}): HTMLDivElement {
	const isRTL = Boolean(opts.isRTL);
	const riyal = displayGapRiyals(opts.amount);
	const size = bubbleSizePx(opts.amount);
	const photoUrl = sanitizeObservedImageUrl(opts.imageUrl);
	const showCurrency = size >= BUBBLE_CURRENCY_MIN_PX;
	const compact = showCurrency && size < 46;
	const digits = localizeDigitString(String(riyal), isRTL);
	const currency = isRTL ? "ر.س" : "SAR";

	const el = document.createElement("div");
	el.className =
		"farq-place-pin farq-gap-bubble farq-gap-bubble--aura farq-gap-bubble--identified";
	if (opts.selected) el.classList.add("is-selected");
	if (photoUrl) el.classList.add("farq-gap-bubble--logo");
	if (!showCurrency) el.classList.add("farq-gap-bubble--tiny");
	else if (compact) el.classList.add("farq-gap-bubble--compact");
	else el.classList.add("farq-gap-bubble--stacked");
	el.dataset.testid = "farq-map-gap-bubble";
	el.dataset.amount = String(riyal);
	el.dataset.size = String(Math.round(size));
	el.dataset.mark = photoUrl ? "logo" : "initials";
	el.style.setProperty("--farq-bubble-size", `${size}px`);
	el.style.setProperty("--farq-hero-size", `${PLACE_HERO_PX}px`);
	el.style.zIndex = String(bubbleZIndex(opts.amount, Boolean(opts.selected)));
	el.setAttribute("role", "button");
	el.setAttribute("aria-label", gapBubbleAriaLabel(opts.name, riyal, isRTL));
	el.title = gapBubbleAriaLabel(opts.name, riyal, isRTL);

	const hero = buildRestaurantHero({ name: opts.name, imageUrl: photoUrl });

	const chip = document.createElement("div");
	chip.className = "farq-gap-bubble-chip";
	chip.setAttribute("aria-hidden", "true");
	const field = document.createElement("div");
	field.className = "farq-gap-bubble-field";
	const orb = document.createElement("div");
	orb.className = "farq-gap-bubble-orb";
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
	chip.appendChild(field);
	chip.appendChild(orb);

	const stem = document.createElement("div");
	stem.className = "farq-gap-bubble-stem";
	stem.setAttribute("aria-hidden", "true");
	stem.appendChild(buildFarqCircleMarkElement(10));

	el.appendChild(hero);
	el.appendChild(chip);
	el.appendChild(stem);
	return el;
}

function buildRestaurantInitialsPin(opts: {
	name: string;
	selected?: boolean;
	isRTL?: boolean;
	imageUrl?: string | null;
}): HTMLDivElement {
	const isRTL = Boolean(opts.isRTL);
	const photoUrl = sanitizeObservedImageUrl(opts.imageUrl);
	const el = document.createElement("div");
	el.className = "farq-place-pin farq-3d-pin--restaurant";
	if (opts.selected) el.classList.add("is-selected");
	if (photoUrl) el.classList.add("farq-3d-pin--logo");
	el.dataset.size = "hero";
	el.dataset.testid = "farq-map-restaurant-pin";
	el.dataset.mark = photoUrl ? "logo" : "initials";
	el.style.setProperty("--farq-hero-size", `${PLACE_HERO_PX}px`);
	const title = opts.name || (isRTL ? "مكان" : "Place");
	el.title = title;
	el.setAttribute("role", "button");
	el.setAttribute("aria-label", title);
	el.appendChild(buildRestaurantHero({ name: opts.name, imageUrl: photoUrl }));
	const stem = document.createElement("div");
	stem.className = "farq-place-pin-stem";
	stem.setAttribute("aria-hidden", "true");
	el.appendChild(stem);
	return el;
}

export function buildPlacePinElement(opts: {
	name: string;
	difference: unknown;
	providerCount?: number | null;
	selected?: boolean;
	isRTL?: boolean;
	imageUrl?: string | null;
}): HTMLDivElement {
	const amount = observedDifferenceAmount(opts.difference);
	if (amount != null) {
		return buildGapBubbleElement({
			name: opts.name,
			amount,
			selected: opts.selected,
			isRTL: opts.isRTL,
			imageUrl: opts.imageUrl,
		});
	}
	return buildRestaurantInitialsPin({
		name: opts.name,
		selected: opts.selected,
		isRTL: opts.isRTL,
		imageUrl: opts.imageUrl,
	});
}

export function buildClusterPinElement(opts: {
	count: number;
	differenceCount?: number;
	topGap?: number | null;
	isRTL?: boolean;
}): HTMLDivElement {
	const count = Number.isFinite(opts.count) ? Math.max(0, Math.round(opts.count)) : 0;
	const isRTL = Boolean(opts.isRTL);
	const opportunities = clusterOpportunityCount({
		count,
		differenceCount: opts.differenceCount,
	});
	const topGap = observedDifferenceAmount({
		difference_amount: opts.topGap,
	});
	const riyal = topGap != null ? displayGapRiyals(topGap) : null;
	const el = document.createElement("div");
	el.className = `farq-3d-cluster ${FARQ_CLUSTERS_CLASS}`;
	if ((opts.differenceCount || 0) > 0 || riyal != null) {
		el.classList.add("farq-3d-cluster--gaps");
		el.classList.add("farq-3d-cluster--opportunity");
	}
	el.dataset.testid = "farq-map-cluster";
	if (riyal != null) el.dataset.topGap = String(riyal);
	el.dataset.opportunities = String(opportunities);
	const gapDigits = riyal != null ? localizeDigitString(String(riyal), isRTL) : "";
	el.setAttribute(
		"role",
		"button",
	);
	el.setAttribute(
		"aria-label",
		riyal != null
			? isRTL
				? `تجمّع ${opportunities} فرصة، أكبر فرق ${gapDigits}`
				: `Cluster of ${opportunities} opportunities, top gap ${riyal}`
			: isRTL
				? `تجمّع ${count} أماكن`
				: `Cluster of ${count} places`,
	);

	const shadow = document.createElement("div");
	shadow.className = "farq-3d-cluster-shadow";
	shadow.setAttribute("aria-hidden", "true");

	const orb = document.createElement("div");
	orb.className = "farq-3d-cluster-orb";

	if (riyal != null) {
		const gapEl = document.createElement("span");
		gapEl.className = "farq-3d-cluster-gap";
		gapEl.textContent = `+${gapDigits}`;
		orb.appendChild(gapEl);
	}

	const label = document.createElement("span");
	label.className = "farq-3d-cluster-count";
	label.textContent =
		(opts.differenceCount || 0) > 0 || riyal != null
			? clusterOpportunityLabel(opportunities, isRTL)
			: String(count);
	orb.appendChild(label);

	el.appendChild(shadow);
	el.appendChild(orb);
	return el;
}

export function setPinSelected(el: HTMLElement, selected: boolean): void {
	el.classList.toggle("is-selected", selected);
	if (!el.classList.contains("farq-gap-bubble")) return;
	if (selected) applyAuraRankClasses(el, "promoted");
	const amount = Number(el.dataset.amount);
	if (!Number.isFinite(amount) || amount <= 0) return;
	el.style.zIndex = String(
		bubbleZIndex(amount, selected, el.classList.contains("farq-gap-bubble--promoted")),
	);
}
