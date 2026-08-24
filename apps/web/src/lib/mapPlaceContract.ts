/**
 * Normalize map pin payloads from both contracts this product has shipped:
 * - nested `difference` (this repo / Farq comparison-map)
 * - lean flat pin (`gap`, `cheapest_provider_id`, …) from the live Railway API
 *
 * Never invents a gap. Missing evidence stays missing.
 */

import { displayItemName } from "./displayItemName";

export type ObservedDifference = {
	difference_amount: number | null;
	cheapest_provider_id: string | null;
	expensive_provider_id: string | null;
	cheapest_price: number | null;
	expensive_price: number | null;
	product_name: string | null;
};

function finite(value: unknown): number | null {
	const n = Number(value);
	return Number.isFinite(n) ? n : null;
}

function text(value: unknown): string | null {
	const s = String(value ?? "").trim();
	return s || null;
}

export function observedGapAmount(props: Record<string, unknown> | null | undefined): number | null {
	if (!props) return null;
	const nested = props.difference;
	if (nested && typeof nested === "object") {
		const n = finite((nested as { difference_amount?: unknown }).difference_amount);
		if (n != null && n > 0) return n;
	}
	const flat = finite(props.gap ?? props.difference_amount);
	if (flat != null && flat > 0) return flat;
	return null;
}

export function normalizeDifference(
	props: Record<string, unknown> | null | undefined,
): ObservedDifference | null {
	if (!props) return null;
	const nested =
		props.difference && typeof props.difference === "object"
			? (props.difference as Record<string, unknown>)
			: null;
	const amount =
		finite(nested?.difference_amount) ??
		finite(props.gap) ??
		finite(props.difference_amount);
	const cheapest =
		text(nested?.cheapest_provider_id) ??
		text(props.cheapest_provider_id) ??
		text(props.cheapest_provider);
	const expensive =
		text(nested?.expensive_provider_id) ??
		text(props.expensive_provider_id) ??
		text(props.dearest_provider);
	const cheapPrice = finite(nested?.cheapest_price) ?? finite(props.cheapest_price);
	const expensivePrice =
		finite(nested?.expensive_price) ??
		finite(props.expensive_price) ??
		finite(props.dearest_price);
	const product = displayItemName(
		text(nested?.product_name) ?? text(props.product_name) ?? "",
	) || null;
	const hasEvidence = Boolean(cheapest) || (amount != null && amount > 0);
	if (!hasEvidence) return null;
	return {
		difference_amount: amount,
		cheapest_provider_id: cheapest,
		expensive_provider_id: expensive,
		cheapest_price: cheapPrice,
		expensive_price: expensivePrice,
		product_name: product,
	};
}

export function normalizePlaceProperties<T extends Record<string, unknown>>(
	props: T | null | undefined,
): T & {
	difference: ObservedDifference | null;
	restaurant_id?: string;
	sector?: string;
} {
	const raw = (props || {}) as T;
	const difference = normalizeDifference(raw);
	const placeId = text(raw.place_id);
	const restaurantId = text(raw.restaurant_id) || placeId || undefined;
	const sector = text(raw.sector) || (text(raw.category) === "grocery" ? "grocery" : "restaurant");
	return {
		...raw,
		restaurant_id: restaurantId,
		sector,
		has_difference: Boolean(difference),
		difference,
	};
}

export type MapPlaceFeature = {
	type: "Feature";
	id?: string;
	geometry: { type: string; coordinates: unknown };
	properties: Record<string, unknown>;
};

export function normalizePlaceFeature(feature: MapPlaceFeature): MapPlaceFeature {
	if (!feature || feature.properties?.feature_type === "cluster") return feature;
	return {
		...feature,
		properties: normalizePlaceProperties(feature.properties || {}),
	};
}

export function normalizePlacesBody<T extends { features?: MapPlaceFeature[] }>(
	body: T | null | undefined,
): T {
	if (!body || !Array.isArray(body.features)) return body as T;
	return {
		...body,
		features: body.features.map((feature) => normalizePlaceFeature(feature)),
	};
}

/**
 * The pin already committed to a dish. The sheet must not swap it for getPlace's
 * other same-gap item (1479 fries 16→18 vs sambosa 36→38).
 */
export function pinSheetObservedItem(
	feature: Record<string, unknown> | null | undefined,
	placeDifference: Record<string, unknown> | null | undefined,
): ObservedDifference | null {
	const fromPin = normalizeDifference(feature);
	if (
		fromPin?.product_name &&
		fromPin.cheapest_price != null &&
		fromPin.expensive_price != null
	) {
		return fromPin;
	}
	if (!placeDifference) return fromPin;
	return (
		normalizeDifference({
			difference: placeDifference,
			...placeDifference,
		}) || fromPin
	);
}

/**
 * Pin, city, getPlace, and the first compared row must name the same dish.
 * The API matches name / name_ar / name_en; the sheet used to match `name` only.
 */
export function itemNameMatchesPin(
	item:
		| { name?: string | null; name_ar?: string | null; name_en?: string | null }
		| null
		| undefined,
	representativeName: string | null | undefined,
): boolean {
	const pin = displayItemName(representativeName);
	if (!pin) return false;
	return [item?.name, item?.name_ar, item?.name_en].some(
		(n) => displayItemName(n) === pin,
	);
}

/** Drop a previous restaurant's payload the instant the selection changes. */
export function livePlaceDetail<T extends { place_id?: string | null }>(
	detail: T | null | undefined,
	placeId: string | null | undefined,
): T | null {
	if (!detail || !placeId) return null;
	return String(detail.place_id || "") === String(placeId) ? detail : null;
}

/** City pins already carry lean `gap`; getPlace used to ship only nested difference. */
export function normalizePlaceDetail<T extends Record<string, unknown>>(
	detail: T | null | undefined,
): T | null {
	if (!detail) return null;
	const gap = observedGapAmount(detail);
	if (gap == null) return detail;
	const existing = finite(detail.gap);
	if (existing != null && existing > 0) return detail;
	return { ...detail, gap };
}
