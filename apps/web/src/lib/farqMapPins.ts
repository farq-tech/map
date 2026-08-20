/**
 * Farq map pin builders — Mapbox HTML markers overlaid on the existing map.
 * App logo is the pin hero. The price chip is always smaller.
 * Observed gaps keep a small Price Aura chip (size ∝ difference_amount).
 * Missing gap → restaurant mark only (never +0). Official Farq stem stays tiny.
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

export const BUBBLE_CLEAR_CHANGE = 1;
export const BUBBLE_ENTER_STAGGER_MAX = 16;
export const BUBBLE_ENTER_MS = 360;
export const BUBBLE_ENTER_SCALE_FROM = 0.82;

/** Price badge — 20–24px so digits stay sharp; still clearly below the 40px logo. */
export const BUBBLE_SIZE_MIN = 20;
export const BUBBLE_SIZE_MAX = 24;
export const BUBBLE_SIZE_HARD_MAX = 26;
export const BUBBLE_SIZE_BASE = 19;
export const BUBBLE_SIZE_SCALE = 0.7;
export const BUBBLE_CURRENCY_MIN_PX = 48;
export const BUBBLE_HERO_GAP_PX = 16;

/** Restaurant disc leftover — must stay smaller than the provider hero. */
export const MARK_SIZE_MIN = 16;
export const MARK_SIZE_MAX = 22;
export const MARK_SIZE_RATIO = 0.52;
export const PIN_THUMB_CSS_PX = 28;

/** App logo is the pin hero. Price chip is always smaller. */
export const PROVIDER_HERO_PX = 40;
export const PLACE_HERO_PX = PROVIDER_HERO_PX;

/** GeoJSON fields that may already carry a real restaurant/branch photo. */
export const RESTAURANT_IMAGE_FIELDS = [
	"image_url",
	"branch_image_url",
	"restaurant_logo_url",
	"restaurant_image_url",
	"restaurant_image",
] as const;

const CLOUDINARY_FETCH_BLOCKED = ["cdngrubtech.com"] as const;

/**
 * Three utility zooms (GPU + HTML must match):
 * - FAR  (zoom < 14): 🔥 + gap number only. No names, logos, ratings.
 * - NEAR (zoom ≥ 14): opportunity + «N ر.س فرق», then place + cheapest provider.
 * - TAP: comparison sheet — not a pin.
 * Display cap is TOP_OPPORTUNITIES (list + map). MAP_PIN_CAP is fetch only.
 */
export const CLUSTER_BREAK_ZOOM = 14;
export const MAP_PIN_CAP = 400;
/** GPU symbols own unselected pins — HTML budget is the selected pin only. */
export const MAP_PIN_HTML_CAP = 1;
/** Leftover HTML farm caps if GPU symbols are unavailable. */
export const MAP_PIN_DOM_FAR = 32;
export const MAP_PIN_DOM_MID = 36;
export const MAP_PIN_DOM_NEAR = 40;
/** After pan/zoom STOP — restack z-index + pulse the max gap (no extra API fetch). */
export const AURA_VIEWPORT_IDLE_MS = 180;
export const AURA_PROMOTE_MIN = 8;
export const AURA_PROMOTE_MAX = 12;
/** Mobile mid-zoom: tighter top-N so the map stays readable at 375–390. */
export const AURA_PROMOTE_MAX_MOBILE = 8;
/**
 * Restaurant discs show on every individual pin. Server clusters hide the pile
 * until CLUSTER_BREAK_ZOOM — we no longer wait until 15.4 to show logos.
 */
export const PIN_IDENTITY_ZOOM = CLUSTER_BREAK_ZOOM;

export function auraPromoteCap(isMobile: boolean): number {
	return isMobile ? AURA_PROMOTE_MAX_MOBILE : AURA_PROMOTE_MAX;
}

/** FAR = gap beacon. NEAR = opportunity + cheapest provider. */
export function pinPresentationForZoom(
	zoom: number,
): "amount" | "identity" {
	return Number(zoom) >= CLUSTER_BREAK_ZOOM ? "identity" : "amount";
}

/** Soften the 13.99→14.01 identity cut — 0 = amount only, 1 = full restaurant hero. */
export const IDENTITY_REVEAL_START = 13.35;
export const IDENTITY_REVEAL_END = 14.65;

export function pinIdentityReveal(zoom: number): number {
	const z = Number(zoom);
	if (!Number.isFinite(z)) return 0;
	if (z <= IDENTITY_REVEAL_START) return 0;
	if (z >= IDENTITY_REVEAL_END) return 1;
	return (z - IDENTITY_REVEAL_START) / (IDENTITY_REVEAL_END - IDENTITY_REVEAL_START);
}

export type PinZoomBand = "far" | "mid" | "near";

export function pinZoomBand(zoom: number): PinZoomBand {
	const z = Number(zoom);
	if (!Number.isFinite(z) || z < 12) return "far";
	if (z < CLUSTER_BREAK_ZOOM) return "mid";
	return "near";
}

/** HTML marker budget — GPU symbols own the rest. Selected pin only. */
export function pinDomCapForZoom(_zoom?: number): number {
	return MAP_PIN_HTML_CAP;
}

/** GPU source can take the API ceiling — no HTML farm. */
export function pinFetchCapForZoom(_zoom?: number): number {
	return MAP_PIN_CAP;
}

/** Restaurant photos only on the selected HTML pin / sheet — never unselected. */
export function shouldAttachPinPhoto(selected: boolean): boolean {
	return Boolean(selected);
}

function featureLngLat(
	feature: GeoJSON.Feature,
): [number, number] | null {
	const geom = feature.geometry;
	if (!geom || geom.type !== "Point" || !Array.isArray(geom.coordinates)) {
		return null;
	}
	const [lng, lat] = geom.coordinates;
	if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
	return [lng, lat];
}

function featureGapAmount(feature: GeoJSON.Feature): number {
	const props = (feature.properties || {}) as {
		feature_type?: string;
		difference?: unknown;
		max_difference_amount?: unknown;
		top_difference_amount?: unknown;
	};
	if (props.feature_type === "cluster") {
		return observedClusterTopGap(props) ?? 0;
	}
	return observedDifferenceAmount(props.difference) ?? 0;
}

/** Stride sample across lat/lng — coverage of the view, not top-gaps-only. */
export function spatialSampleFeatures<T extends GeoJSON.Feature>(
	features: T[],
	n: number,
): T[] {
	const want = Math.max(0, Math.floor(n));
	if (features.length <= want) return features;
	const sorted = features.slice().sort((a, b) => {
		const pa = featureLngLat(a);
		const pb = featureLngLat(b);
		if (!pa || !pb) return 0;
		return pa[1] - pb[1] || pa[0] - pb[0];
	});
	const out: T[] = [];
	const seen = new Set<T>();
	const step = sorted.length / want;
	for (let i = 0; i < want; i += 1) {
		const item = sorted[Math.min(sorted.length - 1, Math.floor(i * step))];
		if (seen.has(item)) continue;
		seen.add(item);
		out.push(item);
	}
	return out;
}

/**
 * Client HTML-marker budget. Keeps the selected pin and already-drawn keys
 * (so a pan does not remint the set), then spatial-samples the rest.
 */
export function sampleViewportPins<T extends GeoJSON.Feature>(
	features: T[],
	opts: {
		cap: number;
		selectedPlaceId?: string;
		keepKeys?: Iterable<string>;
	},
): T[] {
	const cap = Math.max(0, Math.floor(opts.cap));
	if (cap <= 0) return [];
	if (features.length <= cap) return features;

	const keepKeys = new Set(opts.keepKeys || []);
	const selected = String(opts.selectedPlaceId || "").trim();
	const locked: T[] = [];
	const rest: T[] = [];
	for (const feature of features) {
		const key = featureMarkerKey(feature);
		const placeId = String(
			(feature.properties as { place_id?: string } | null)?.place_id || "",
		).trim();
		if ((selected && placeId === selected) || (key && keepKeys.has(key))) {
			locked.push(feature);
		} else {
			rest.push(feature);
		}
	}

	if (locked.length >= cap) {
		const selectedRows = selected
			? locked.filter(
					(f) =>
						String(
							(f.properties as { place_id?: string } | null)?.place_id || "",
						).trim() === selected,
				)
			: [];
		const others = locked.filter((f) => !selectedRows.includes(f));
		return [...selectedRows, ...others].slice(0, cap);
	}

	const budget = cap - locked.length;
	const clusters = rest.filter(
		(f) =>
			(f.properties as { feature_type?: string } | null)?.feature_type ===
			"cluster",
	);
	const pins = rest.filter(
		(f) =>
			(f.properties as { feature_type?: string } | null)?.feature_type !==
			"cluster",
	);
	const heroBudget = Math.min(8, Math.max(0, Math.floor(budget * 0.2)));
	const heroes = pins
		.filter((f) => featureGapAmount(f) > 0)
		.sort(
			(a, b) =>
				featureGapAmount(b) - featureGapAmount(a) ||
				String(
					(a.properties as { place_id?: string } | null)?.place_id || "",
				).localeCompare(
					String(
						(b.properties as { place_id?: string } | null)?.place_id || "",
					),
				),
		)
		.slice(0, heroBudget);
	const heroSet = new Set(heroes);
	const leftoverPins = pins.filter((f) => !heroSet.has(f));
	const leftover = [...clusters, ...leftoverPins];
	const sampled = spatialSampleFeatures(
		leftover,
		Math.max(0, budget - heroes.length),
	);
	return [...locked, ...heroes, ...sampled];
}

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
	cheapest_price?: number | null;
	expensive_price?: number | null;
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
		cheapest_price?: number | null;
		expensive_price?: number | null;
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

export type AuraRank = "promoted" | "demoted" | "visible";

/** Promote every visible aura up to MAX; beyond that keep the top MAX. */
export function promotedAuraLimit(
	visibleCount: number,
	max = AURA_PROMOTE_MAX,
): number {
	if (visibleCount <= 0) return 0;
	if (visibleCount <= max) return visibleCount;
	return max;
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

export function clusterRestaurantCount(count: number): number {
	const n = Number(count);
	return Number.isFinite(n) ? Math.max(0, Math.round(n)) : 0;
}

/** Observed opportunity count. Uses difference_count when the API sent it. */
export function clusterOpportunityCount(opts: {
	count: number;
	differenceCount?: number;
}): number {
	const gaps = Number(opts.differenceCount);
	if (Number.isFinite(gaps) && gaps >= 0) return Math.round(gaps);
	return clusterRestaurantCount(opts.count);
}

export function clusterOpportunityLabel(count: number, isRTL: boolean): string {
	const n = Math.max(0, Math.round(count));
	const digits = localizeDigitString(String(n), isRTL);
	return isRTL ? `${digits} مكان` : `${n} places`;
}

/** Hero copy: the riyal gap is the product, never “38 فرصة”. */
export function gapRiyalLabel(amount: number, isRTL: boolean): string {
	const digits = localizeDigitString(String(displayGapRiyals(amount)), isRTL);
	return isRTL ? `${digits} ر.س فرق` : `${displayGapRiyals(amount)} SAR gap`;
}

export function clusterGapHeroLabel(amount: number, isRTL: boolean): string {
	return `🔥 ${gapRiyalLabel(amount, isRTL)}`;
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
	};
	if (props.feature_type === "cluster") return null;
	const placeId = String(props.place_id || "").trim();
	if (!placeId) return null;
	return `place:${placeId}`;
}

/** Slim list pins carry gap + prices + product; full pins nest difference. */
export function differenceFromPinProps(props: {
	difference?: unknown;
	gap?: unknown;
	cheapest_provider_id?: unknown;
	expensive_provider_id?: unknown;
	product_name?: unknown;
	cheapest_price?: unknown;
	expensive_price?: unknown;
} | null | undefined): {
	difference_amount?: number | null;
	cheapest_provider_id?: string | null;
	expensive_provider_id?: string | null;
	cheapest_price?: number | null;
	expensive_price?: number | null;
	product_name?: string | null;
} | null {
	if (props == null) return null;
	if (props.difference != null) return parseDifference(props.difference);
	const gap = Number(props.gap);
	const provider = String(props.cheapest_provider_id || "").trim();
	const expensive = String(props.expensive_provider_id || "").trim();
	const product = String(props.product_name || "").trim();
	const cheap = Number(props.cheapest_price);
	const dear = Number(props.expensive_price);
	const amount = Number.isFinite(gap) && Math.round(gap) >= 1 ? gap : null;
	if (amount == null && !provider && !product) return null;
	return {
		difference_amount: amount,
		cheapest_provider_id: provider || null,
		expensive_provider_id: expensive || null,
		cheapest_price: Number.isFinite(cheap) && cheap > 0 ? cheap : null,
		expensive_price: Number.isFinite(dear) && dear > 0 ? dear : null,
		product_name: product || null,
	};
}

/** Update the mint chip digits in place — never remint on gap flicker. */
export function updatePlacePinChip(
	el: HTMLElement,
	amount: number | null,
	isRTL = false,
): void {
	const amountEl = el.querySelector(".farq-gap-bubble-amount");
	if (!(amountEl instanceof HTMLElement)) return;
	if (amount == null || amount <= 0) return;
	const riyal = displayGapRiyals(amount);
	amountEl.textContent = `+${localizeDigitString(String(riyal), isRTL)}`;
	el.dataset.amount = String(riyal);
	const size = Math.min(
		bubbleSizePx(amount),
		PROVIDER_HERO_PX - BUBBLE_HERO_GAP_PX,
		BUBBLE_SIZE_HARD_MAX,
		BUBBLE_SIZE_MAX,
	);
	el.dataset.size = String(Math.round(size));
	el.style.setProperty("--farq-bubble-size", `${size}px`);
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

function buildProviderHero(opts: {
	name: string;
	imageUrl?: string | null;
	difference?: unknown;
}): HTMLDivElement {
	const hero = document.createElement("div");
	hero.className = "farq-place-pin-hero farq-gap-bubble-mark";
	hero.setAttribute("aria-hidden", "true");
	hero.dataset.testid = "farq-map-provider-mark";
	const cheapest = resolveCheapestPinLogo(opts.difference);
	const initial = document.createElement("span");
	initial.className = "farq-place-pin-initial farq-gap-bubble-mark-initial farq-3d-pin-initial";
	initial.textContent = cheapest
		? providerPinInitial(cheapest.providerId)
		: restaurantPinInitial(opts.name);
	hero.appendChild(initial);
	const logoUrl = cheapest?.src || sanitizeObservedImageUrl(opts.imageUrl);
	if (logoUrl) {
		hero.dataset.kind = cheapest?.src ? "provider" : "photo";
		attachRestaurantPhoto(hero, { imageUrl: logoUrl, cssPx: PROVIDER_HERO_PX });
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
	includePhoto?: boolean;
	difference?: unknown;
	/** Unselected place pins stay small — sheet holds the comparison. */
	quiet?: boolean;
}): HTMLDivElement {
	const isRTL = Boolean(opts.isRTL);
	const riyal = displayGapRiyals(opts.amount);
	const size = Math.min(
		bubbleSizePx(opts.amount),
		PROVIDER_HERO_PX - BUBBLE_HERO_GAP_PX,
		BUBBLE_SIZE_HARD_MAX,
		BUBBLE_SIZE_MAX,
	);
	const cheapest = resolveCheapestPinLogo(opts.difference);
	const photoUrl =
		cheapest?.src ||
		(opts.includePhoto
			? sanitizeObservedImageUrl(opts.imageUrl)
			: null);
	const digits = localizeDigitString(String(riyal), isRTL);

	const el = document.createElement("div");
	el.className =
		"farq-place-pin farq-gap-bubble farq-gap-bubble--aura farq-gap-bubble--identified farq-gap-bubble--tiny farq-map-hit";
	if (opts.selected) el.classList.add("is-selected");
	if (opts.quiet && !opts.selected) el.classList.add("farq-gap-bubble--quiet");
	if (photoUrl) el.classList.add("farq-gap-bubble--logo");
	if (cheapest?.src) el.classList.add("farq-gap-bubble--provider");
	el.dataset.testid = "farq-map-gap-bubble";
	el.dataset.amount = String(riyal);
	el.dataset.size = String(Math.round(size));
	el.dataset.mark = cheapest?.src ? "provider" : photoUrl ? "logo" : "initials";
	el.style.setProperty("--farq-bubble-size", `${size}px`);
	el.style.setProperty("--farq-hero-size", `${PROVIDER_HERO_PX}px`);
	el.style.zIndex = String(bubbleZIndex(opts.amount, Boolean(opts.selected)));
	el.setAttribute("role", "button");
	el.setAttribute("aria-label", gapBubbleAriaLabel(opts.name, riyal, isRTL));
	el.title = gapBubbleAriaLabel(opts.name, riyal, isRTL);

	const hero = buildProviderHero({
		name: opts.name,
		imageUrl: photoUrl,
		difference: opts.difference,
	});

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
	includePhoto?: boolean;
	difference?: unknown;
}): HTMLDivElement {
	const isRTL = Boolean(opts.isRTL);
	const cheapest = resolveCheapestPinLogo(opts.difference);
	const photoUrl =
		cheapest?.src ||
		(opts.includePhoto
			? sanitizeObservedImageUrl(opts.imageUrl)
			: null);
	const el = document.createElement("div");
	el.className = "farq-place-pin farq-3d-pin--restaurant farq-map-hit";
	if (opts.selected) el.classList.add("is-selected");
	if (photoUrl) el.classList.add("farq-3d-pin--logo");
	if (cheapest?.src) el.classList.add("farq-gap-bubble--provider");
	el.dataset.size = "hero";
	el.dataset.testid = "farq-map-restaurant-pin";
	el.dataset.mark = cheapest?.src ? "provider" : photoUrl ? "logo" : "initials";
	el.style.setProperty("--farq-hero-size", `${PLACE_HERO_PX}px`);
	const title = opts.name || (isRTL ? "مكان" : "Place");
	el.title = title;
	el.setAttribute("role", "button");
	el.setAttribute("aria-label", title);
	el.appendChild(
		buildProviderHero({
			name: opts.name,
			imageUrl: photoUrl,
			difference: opts.difference,
		}),
	);
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
	includePhoto?: boolean;
	quiet?: boolean;
}): HTMLDivElement {
	const amount = observedDifferenceAmount(opts.difference);
	if (amount != null) {
		return buildGapBubbleElement({
			name: opts.name,
			amount,
			selected: opts.selected,
			isRTL: opts.isRTL,
			imageUrl: opts.imageUrl,
			includePhoto: opts.includePhoto,
			difference: opts.difference,
			quiet: opts.quiet,
		});
	}
	return buildRestaurantInitialsPin({
		name: opts.name,
		selected: opts.selected,
		isRTL: opts.isRTL,
		imageUrl: opts.imageUrl,
		includePhoto: opts.includePhoto,
		difference: opts.difference,
	});
}

/** Attach or strip a restaurant photo without reminting the marker. */
export function syncPinPhoto(
	el: HTMLElement,
	imageUrl: string | null | undefined,
): void {
	const hero = el.querySelector(
		".farq-place-pin-hero, .farq-gap-bubble-mark",
	) as HTMLElement | null;
	if (!hero) return;
	const url = sanitizeObservedImageUrl(imageUrl);
	const existing = hero.querySelector("img");
	if (!url) {
		if (existing) existing.remove();
		hero.dataset.kind = "initials";
		el.classList.remove("farq-gap-bubble--logo", "farq-3d-pin--logo");
		el.dataset.mark = "initials";
		return;
	}
	if (existing) return;
	attachRestaurantPhoto(hero, { imageUrl: url, cssPx: PLACE_HERO_PX });
	hero.dataset.kind = "photo";
	if (el.classList.contains("farq-gap-bubble")) {
		el.classList.add("farq-gap-bubble--logo");
	} else {
		el.classList.add("farq-3d-pin--logo");
	}
	el.dataset.mark = "logo";
}

export function buildClusterPinElement(opts: {
	count: number;
	differenceCount?: number;
	topGap?: number | null;
	isRTL?: boolean;
}): HTMLDivElement {
	const count = clusterRestaurantCount(opts.count);
	const isRTL = Boolean(opts.isRTL);
	const restaurants = clusterRestaurantCount(count);
	const opportunities = clusterOpportunityCount({
		count,
		differenceCount: opts.differenceCount,
	});
	const topGap = observedDifferenceAmount({
		difference_amount: opts.topGap,
	});
	const riyal = topGap != null ? displayGapRiyals(topGap) : null;
	const el = document.createElement("div");
	el.className = `farq-3d-cluster ${FARQ_CLUSTERS_CLASS} farq-map-hit`;
	if (opportunities > 0 || riyal != null) {
		el.classList.add("farq-3d-cluster--gaps");
		el.classList.add("farq-3d-cluster--opportunity");
	}
	el.dataset.testid = "farq-map-cluster";
	if (riyal != null) el.dataset.topGap = String(riyal);
	el.dataset.count = String(restaurants);
	el.dataset.opportunities = String(opportunities);
	const gapDigits = riyal != null ? localizeDigitString(String(riyal), isRTL) : "";
	const labeled =
		opportunities > 0 ? opportunities : restaurants;
	const countLabel =
		opportunities > 0
			? clusterOpportunityLabel(opportunities, isRTL)
			: isRTL
				? localizeDigitString(String(labeled), true)
				: String(labeled);
	el.setAttribute(
		"role",
		"button",
	);
	el.setAttribute(
		"aria-label",
		riyal != null
			? isRTL
				? `تجمّع ${countLabel}، أكبر فرق ${gapDigits}`
				: `Cluster of ${restaurants} restaurants, top gap ${riyal}`
			: isRTL
				? `تجمّع ${countLabel}`
				: `Cluster of ${restaurants} restaurants`,
	);

	const shadow = document.createElement("div");
	shadow.className = "farq-3d-cluster-shadow";
	shadow.setAttribute("aria-hidden", "true");

	const orb = document.createElement("div");
	orb.className = "farq-3d-cluster-orb";

	if (riyal != null) {
		const gapEl = document.createElement("span");
		gapEl.className = "farq-3d-cluster-gap";
		gapEl.textContent = clusterGapHeroLabel(riyal, isRTL);
		orb.appendChild(gapEl);
	}

	const label = document.createElement("span");
	label.className = "farq-3d-cluster-count";
	label.textContent = riyal != null ? countLabel : `🔥 ${countLabel}`;
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
