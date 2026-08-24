/**
 * Client-side map filter floors — keep in step with apps/api/lib/map-filters.js.
 * Never invents grocery storefronts. Never merges on proximity.
 */

export const BIGGEST_SAVINGS_MIN_GAP = 10;
export const BIGGEST_SAVINGS_MIN_PRICE = 15;

const GROCERY_TERMS = /grocery|بقالة|سوبرماركت|supermarket|تموين/i;

export type MapValueFilter = "all" | "biggest" | "multi";

export function parseMapFilter(raw: unknown): MapValueFilter | undefined {
	const v = String(raw || "")
		.trim()
		.toLowerCase();
	if (v === "biggest" || v === "biggest_savings" || v === "savings") return "biggest";
	if (v === "multi" || v === "multi_provider" || v === "providers") return "multi";
	if (v === "all") return "all";
	return undefined;
}

export function isGroceryIdentity(props: {
	name?: unknown;
	name_en?: unknown;
	product_name?: unknown;
	category?: unknown;
	sector?: unknown;
	category_gaps?: Record<string, number> | null;
} | null | undefined): boolean {
	if (!props) return false;
	if (String(props.sector || "") === "grocery") return true;
	if (String(props.category || "") === "grocery") return true;
	if (props.category_gaps && props.category_gaps.grocery != null) return true;
	const hay = [props.name, props.name_en, props.product_name].join(" ");
	return GROCERY_TERMS.test(hay);
}

export function isBiggestSavingsPin(props: {
	gap?: unknown;
	difference_amount?: unknown;
	cheapest_price?: unknown;
	cheapest_provider_id?: unknown;
	has_difference?: unknown;
} | null | undefined): boolean {
	if (!props) return false;
	const gap = Number(props.gap ?? props.difference_amount);
	const cheap = Number(props.cheapest_price);
	if (!Number.isFinite(gap) || gap < BIGGEST_SAVINGS_MIN_GAP) return false;
	if (Number.isFinite(cheap) && cheap > 0 && cheap < BIGGEST_SAVINGS_MIN_PRICE) {
		return false;
	}
	return Boolean(props.cheapest_provider_id || props.has_difference);
}

export function isMultiProviderPin(props: {
	provider_count?: unknown;
} | null | undefined): boolean {
	return Number(props?.provider_count) >= 3;
}
