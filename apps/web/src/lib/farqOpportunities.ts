/**
 * One ranked opportunity set for List and Map.
 * Unit = observed gap, never a restaurant POI. Never invents price or distance.
 */
import { localizeDigitString } from "./formatPrice";

export const TOP_OPPORTUNITIES = 10;

export type OpportunitySort = "gap" | "near" | "cheap";

export type OpportunityRow = {
	placeId: string;
	name: string;
	amount: number;
	lat: number;
	lng: number;
	cheapestPrice?: number | null;
	expensivePrice?: number | null;
	productName?: string | null;
	cheapestProvider?: string | null;
	expensiveProvider?: string | null;
	distanceMeters?: number | null;
	/** Chain identity, so a list can show a brand once. */
	brandKey?: string | null;
	/** How many branches of this brand the dedupe folded into this row (1 = only this one). */
	branchCount?: number;
	/** How many item comparisons this restaurant's number rests on — 1 is not 221. */
	comparisons?: number;
	/**
	 * Why this restaurant matched the active category, when its headline item is
	 * something else: the category's own biggest observed gap here. Shown beside
	 * the card's number, never instead of it — the two belong to different dishes.
	 */
	categoryGap?: number | null;
	categoryLabel?: string | null;
	/** Why this item is not what one person orders — 'share', 'retail', or absent. */
	demoteReason?: "share" | "retail" | null;
};

export function haversineMeters(
	lat1: number,
	lng1: number,
	lat2: number,
	lng2: number,
): number {
	const toRad = (d: number) => (d * Math.PI) / 180;
	const r = 6371000;
	const dLat = toRad(lat2 - lat1);
	const dLng = toRad(lng2 - lng1);
	const a =
		Math.sin(dLat / 2) * Math.sin(dLat / 2) +
		Math.cos(toRad(lat1)) *
			Math.cos(toRad(lat2)) *
			Math.sin(dLng / 2) *
			Math.sin(dLng / 2);
	return 2 * r * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** Real GPS → observed pin only. Missing either side → null, never a guess. */
export function observedDistanceMeters(
	userLat: number | null | undefined,
	userLng: number | null | undefined,
	placeLat: number,
	placeLng: number,
): number | null {
	if (
		!Number.isFinite(userLat) ||
		!Number.isFinite(userLng) ||
		!Number.isFinite(placeLat) ||
		!Number.isFinite(placeLng)
	) {
		return null;
	}
	return haversineMeters(
		Number(userLat),
		Number(userLng),
		placeLat,
		placeLng,
	);
}

export function formatObservedDistance(
	meters: number | null | undefined,
	isRTL: boolean,
): string | null {
	if (meters == null || !Number.isFinite(meters) || meters < 0) return null;
	if (meters < 1000) {
		const n = Math.max(1, Math.round(meters));
		return isRTL
			? `${localizeDigitString(String(n), true)} م`
			: `${n} m`;
	}
	const km = Math.round(meters / 100) / 10;
	const digits = localizeDigitString(String(km), isRTL);
	return isRTL ? `${digits} كم` : `${km} km`;
}

export function withObservedDistances(
	rows: OpportunityRow[],
	userLat?: number | null,
	userLng?: number | null,
): OpportunityRow[] {
	return rows.map((row) => ({
		...row,
		distanceMeters: observedDistanceMeters(
			userLat,
			userLng,
			row.lat,
			row.lng,
		),
	}));
}

/**
 * One row per chain. Six branches of the same brand carry the same item at the
 * same price, so a ranked list becomes one brand repeated — 5,222 of Riyadh's
 * 8,745 cards are extra branches. The map keeps every branch, because every
 * branch is a real place you can order from; the list keeps the best one and
 * says how many others there are.
 */
export function dedupeByBrand(rows: OpportunityRow[]): OpportunityRow[] {
	const seen = new Map<string, OpportunityRow>();
	const out: OpportunityRow[] = [];
	for (const row of rows) {
		const key = String(row.brandKey || "").trim();
		/* No brand key means we cannot claim two rows are the same chain. */
		if (!key) {
			out.push(row);
			continue;
		}
		const kept = seen.get(key);
		if (!kept) {
			seen.set(key, row);
			out.push(row);
			continue;
		}
		kept.branchCount = (kept.branchCount || 1) + 1;
	}
	return out;
}

/** A dinner order outranks a party box of the same size; the number stays observed. */
function personalFirst(a: OpportunityRow, b: OpportunityRow): number {
	return Number(Boolean(a.demoteReason)) - Number(Boolean(b.demoteReason));
}

export function rankOpportunities(
	rows: OpportunityRow[],
	sort: OpportunitySort,
): OpportunityRow[] {
	const list = rows.slice();
	if (sort === "cheap" && list.some((row) => row.cheapestPrice != null)) {
		list.sort((a, b) => {
			const ac = a.cheapestPrice;
			const bc = b.cheapestPrice;
			if (ac != null && bc != null && ac !== bc) return ac - bc;
			if (ac != null && bc == null) return -1;
			if (ac == null && bc != null) return 1;
			return b.amount - a.amount || a.placeId.localeCompare(b.placeId);
		});
		return list;
	}
	if (sort === "near" && list.some((row) => row.distanceMeters != null)) {
		list.sort((a, b) => {
			const ad = a.distanceMeters;
			const bd = b.distanceMeters;
			if (ad != null && bd != null && ad !== bd) return ad - bd;
			if (ad != null && bd == null) return -1;
			if (ad == null && bd != null) return 1;
			return b.amount - a.amount || a.placeId.localeCompare(b.placeId);
		});
		return list;
	}
	/* "أكبر فرق" ranks by the observed gap, but a share box never opens the list. */
	list.sort(
		(a, b) => personalFirst(a, b) || b.amount - a.amount || a.placeId.localeCompare(b.placeId),
	);
	return list;
}

export function topOpportunities(
	rows: OpportunityRow[],
	sort: OpportunitySort,
	cap = TOP_OPPORTUNITIES,
	opts: { dedupeBrands?: boolean } = {},
): OpportunityRow[] {
	const ranked = rankOpportunities(rows, sort);
	const list = opts.dedupeBrands === false ? ranked : dedupeByBrand(ranked);
	return list.slice(0, Math.max(0, cap));
}
