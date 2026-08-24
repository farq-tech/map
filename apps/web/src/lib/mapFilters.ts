/**
 * Client-side map filter floors — keep in step with apps/api/lib/map-filters.js.
 * Never invents grocery storefronts. Never merges on proximity.
 */

export const BIGGEST_SAVINGS_MIN_GAP = 10;
export const BIGGEST_SAVINGS_MIN_PRICE = 15;

const GROCERY_TERMS = /grocery|بقالة|سوبرماركت|supermarket|تموين/i;

export type MapValueFilter = "all" | "biggest" | "multi";

export function parseMapFilter(raw: unknown): MapValueFilter | undefined {
	const flags = parseMapFilters(raw);
	if (flags.biggest && flags.multi) return undefined;
	if (flags.biggest) return "biggest";
	if (flags.multi) return "multi";
	const v = String(raw || "")
		.trim()
		.toLowerCase();
	if (v === "all") return "all";
	return undefined;
}

export type MapFilterFlags = {
	biggest: boolean;
	multi: boolean;
};

export function parseMapFilters(raw: unknown): MapFilterFlags {
	const parts = String(raw || "")
		.trim()
		.toLowerCase()
		.split(/[+,\s]+/)
		.map((part) => part.trim())
		.filter(Boolean);
	return {
		biggest: parts.some(
			(part) => part === "biggest" || part === "biggest_savings" || part === "savings",
		),
		multi: parts.some(
			(part) => part === "multi" || part === "multi_provider" || part === "providers",
		),
	};
}

/** Drawer rail that matches a bookmarked filter/sort so refresh does not look like "all restaurants". */
export type MapRailHint = "gaps" | "restaurants" | "grocery" | "cheapest" | "multi";

export function railFromMapSearch(search: {
	filter?: string;
	sort?: string;
	category?: string;
	sector?: string;
}): MapRailHint {
	if (
		search.sector === "grocery" ||
		search.category === "grocery" ||
		search.category === "shopping"
	) {
		return "grocery";
	}
	if (search.sort === "cheap") return "cheapest";
	const flags = parseMapFilters(search.filter);
	if (flags.biggest) return "gaps";
	if (flags.multi) return "multi";
	return "restaurants";
}

export function encodeMapFilters(flags: MapFilterFlags): string | undefined {
	const parts: string[] = [];
	if (flags.biggest) parts.push("biggest");
	if (flags.multi) parts.push("multi");
	return parts.length ? parts.join(",") : undefined;
}

export function toggleMapFilter(
	raw: unknown,
	key: "biggest" | "multi",
): string | undefined {
	const flags = parseMapFilters(raw);
	flags[key] = !flags[key];
	return encodeMapFilters(flags);
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

/** Filters the selected pin failed — it stays on the map because it was opened. */
export type SelectedPlaceFilterMiss = "biggest" | "multi";

export function selectedPlaceFilterMisses(
	props: {
		gap?: unknown;
		difference_amount?: unknown;
		cheapest_price?: unknown;
		cheapest_provider_id?: unknown;
		has_difference?: unknown;
		provider_count?: unknown;
	} | null | undefined,
	flags: MapFilterFlags,
): SelectedPlaceFilterMiss[] {
	const missed: SelectedPlaceFilterMiss[] = [];
	if (flags.biggest && !isBiggestSavingsPin(props)) missed.push("biggest");
	if (flags.multi && !isMultiProviderPin(props)) missed.push("multi");
	return missed;
}

export function selectedPlaceFilterMissCopy(
	misses: SelectedPlaceFilterMiss[] | undefined,
	isRTL: boolean,
): string | null {
	if (!misses?.length) return null;
	const biggest = misses.includes("biggest");
	const multi = misses.includes("multi");
	if (biggest && multi) {
		return isRTL
			? "ظاهر لأنك فتحته — خارج فلتر الفرق و٣ تطبيقات"
			: "Shown because you opened it — outside these filters";
	}
	if (biggest) {
		return isRTL
			? "ظاهر لأنك فتحته — الفرق أقل من ١٠ ر.س"
			: "Shown because you opened it — gap under 10 SAR";
	}
	return isRTL
		? "ظاهر لأنك فتحته — أقل من ٣ تطبيقات"
		: "Shown because you opened it — fewer than 3 apps";
}
