/**
 * 3D HTML pin builders for the Farq Mapbox map.
 * Logos come only from getProviderLogo(real provider ids) — never invented URLs.
 *
 * Golden map features expose cheapest_provider_id + expensive_provider_id +
 * provider_count. There is no linked-apps list; do not invent extra apps.
 */
import { localizeDigitString } from "./formatPrice";
import {
	getProviderLabel,
	getProviderLogo,
	normalizePlatformKey,
} from "./platformLogos";

export const FARQ_CLUSTERS_CLASS = "farq-clusters";
export const PIN_OTHERS_MAX = 3;

/** Winner pin scale from an observed gap. Floor stays readable (not Figma’s 32px). */
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
		provider_count?: number | null;
	};
	if (props.feature_type === "cluster") {
		return `cluster:${Number(lng).toFixed(5)}:${Number(lat).toFixed(5)}:${props.count ?? 0}`;
	}
	const placeId = String(props.place_id || "").trim();
	if (!placeId) return null;
	const marks = resolvePlacePinMarks(props.difference, props.provider_count);
	const cheapest = marks.winner?.providerId || "restaurant";
	const others =
		marks.others.map((m) => m.providerId).join("+") || "none";
	const amount = parseDifference(props.difference)?.difference_amount;
	return `place:${placeId}:${cheapest}:${others}:${marks.extraCount}:${pinSizeTier(amount)}`;
}

function attachInitial(host: HTMLElement, text: string, className: string): void {
	host.classList.add("farq-3d-pin-badge--mark");
	if (host.querySelector(`.${className}`)) return;
	const initial = document.createElement("span");
	initial.className = className;
	initial.textContent = text;
	host.appendChild(initial);
}

function attachLogoOrInitial(
	badge: HTMLElement,
	mark: { src: string | null; label: string; labelAr: string; initial: string } | null,
	isRTL: boolean,
	emptyInitial: string | null,
): void {
	if (!mark) {
		if (emptyInitial) attachInitial(badge, emptyInitial, "farq-3d-pin-initial");
		return;
	}
	if (!mark.src) {
		attachInitial(badge, mark.initial, "farq-3d-pin-initial");
		return;
	}
	const img = document.createElement("img");
	img.src = mark.src;
	img.alt = isRTL ? mark.labelAr : mark.label;
	img.draggable = false;
	img.decoding = "async";
	img.addEventListener("error", () => {
		img.remove();
		attachInitial(badge, mark.initial, "farq-3d-pin-initial");
	});
	badge.appendChild(img);
}

export function buildPlacePinElement(opts: {
	name: string;
	difference: unknown;
	providerCount?: number | null;
	selected?: boolean;
	isRTL?: boolean;
}): HTMLDivElement {
	const isRTL = Boolean(opts.isRTL);
	const marks = resolvePlacePinMarks(opts.difference, opts.providerCount);
	const { winner, others, extraCount } = marks;
	const hasStack = others.length > 0 || extraCount > 0;
	const amount = Number(parseDifference(opts.difference)?.difference_amount);
	const size = winner ? pinSizeTier(amount) : "sm";

	const el = document.createElement("div");
	el.className = `farq-3d-pin farq-3d-pin--${size} ${winner ? "farq-3d-pin--provider" : "farq-3d-pin--restaurant"}`;
	if (hasStack) el.classList.add("farq-3d-pin--stack");
	if (opts.selected) el.classList.add("is-selected");
	el.dataset.size = size;
	el.dataset.testid = winner ? "farq-map-logo-pin" : "farq-map-restaurant-pin";
	if (winner) el.dataset.provider = winner.providerId;
	if (others.length) {
		el.dataset.others = others.map((m) => m.providerId).join(",");
	}
	if (extraCount > 0) el.dataset.extra = String(extraCount);

	const title = opts.name || (isRTL ? "مكان" : "Place");
	el.title = title;
	el.setAttribute("role", "button");
	const otherNames = others
		.map((m) => (isRTL ? m.labelAr : m.label))
		.join(isRTL ? "، " : ", ");
	const extraBit =
		extraCount > 0
			? isRTL
				? ` +${extraCount}`
				: ` +${extraCount}`
			: "";
	el.setAttribute(
		"aria-label",
		winner
			? `${title} · ${isRTL ? winner.labelAr : winner.label}${
					otherNames ? (isRTL ? ` · ${otherNames}` : ` · ${otherNames}`) : ""
				}${extraBit}`
			: otherNames
				? `${title} · ${otherNames}${extraBit}`
				: title,
	);

	const shadow = document.createElement("div");
	shadow.className = "farq-3d-pin-shadow";
	shadow.setAttribute("aria-hidden", "true");

	const scene = document.createElement("div");
	scene.className = "farq-3d-pin-scene";

	const badge = document.createElement("div");
	badge.className = "farq-3d-pin-badge farq-3d-pin-badge--winner";
	attachLogoOrInitial(
		badge,
		winner
			? {
					src: winner.src,
					label: winner.label,
					labelAr: winner.labelAr,
					initial: providerPinInitial(winner.providerId, isRTL),
				}
			: null,
		isRTL,
		winner ? null : restaurantPinInitial(opts.name),
	);

	scene.appendChild(badge);

	if (winner) {
		const squircle = document.createElement("div");
		squircle.className = "farq-3d-pin-squircle";
		squircle.dataset.testid = "farq-map-pin-squircle";
		const nameEl = document.createElement("span");
		nameEl.className = "farq-3d-pin-squircle-name";
		nameEl.textContent = isRTL ? winner.labelAr : winner.label;
		squircle.appendChild(nameEl);
		if (Number.isFinite(amount) && amount > 0) {
			const saveEl = document.createElement("span");
			saveEl.className = "farq-3d-pin-squircle-save";
			const digits = localizeDigitString(String(Math.round(amount)), isRTL);
			saveEl.textContent = isRTL ? `وفر ${digits} ر.س` : `Save ${digits} SAR`;
			squircle.appendChild(saveEl);
		}
		scene.appendChild(squircle);
	}

	if (hasStack) {
		const row = document.createElement("div");
		row.className = "farq-3d-pin-others";
		row.setAttribute("aria-hidden", "true");
		for (const mark of others) {
			const chip = document.createElement("div");
			chip.className = "farq-3d-pin-chip";
			chip.dataset.testid = "farq-map-pin-chip";
			chip.dataset.provider = mark.providerId;
			const chipLabel = document.createElement("span");
			chipLabel.className = "farq-3d-pin-chip-label";
			chipLabel.textContent = isRTL ? mark.labelAr : mark.label;
			chip.appendChild(chipLabel);
			row.appendChild(chip);
		}
		if (extraCount > 0) {
			const more = document.createElement("div");
			more.className = "farq-3d-pin-more";
			more.dataset.testid = "farq-map-pin-more";
			more.textContent = `+${extraCount}`;
			row.appendChild(more);
		}
		scene.appendChild(row);
	}

	const stem = document.createElement("div");
	stem.className = "farq-3d-pin-stem";
	stem.setAttribute("aria-hidden", "true");
	const shine = document.createElement("span");
	shine.className = "farq-3d-pin-stem-shine";
	stem.appendChild(shine);

	scene.appendChild(stem);
	el.appendChild(shadow);
	el.appendChild(scene);
	return el;
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
}
