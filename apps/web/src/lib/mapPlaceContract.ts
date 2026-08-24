/**
 * Normalize map pin payloads from both contracts this product has shipped:
 * - nested `difference` (this repo / Farq comparison-map)
 * - lean flat pin (`gap`, `cheapest_provider_id`, …) from the live Railway API
 *
 * Never invents a gap. Missing evidence stays missing.
 */

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
	const product =
		text(nested?.product_name) ?? text(props.product_name);
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
