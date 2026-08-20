/**
 * Opportunity tiers — how loudly a gap may speak on the map and in the list.
 *
 * Thresholds come from the observed distribution of per-restaurant gaps in the
 * comparison source (p50 ≈ 9 SAR, p90 ≈ 36 SAR, p99 ≈ 92 SAR on 2026-08-20)
 * and were approved as product thresholds on 2026-08-20. They are not tuned
 * for looks: a Hero is a top-decile gap, a Faint is below the typical one.
 *
 * The consumer cap mirrors the API: a restaurant's representative opportunity
 * ignores items priced above CONSUMER_PRICE_CAP_SAR (catering trays, group
 * meals), so "biggest gap around you" describes a dinner, not a banquet.
 */

export type OpportunityTier = "hero" | "strong" | "regular" | "faint";

export const TIER_HERO_MIN_SAR = 36;
export const TIER_STRONG_MIN_SAR = 15;
export const TIER_REGULAR_MIN_SAR = 5;

/** Same value as the API's CONSUMER_PRICE_CAP_SAR — keep them in step. */
export const CONSUMER_PRICE_CAP_SAR = 200;

/** Null for anything that is not an observed, positive gap. */
export function tierForGap(gap: unknown): OpportunityTier | null {
	const n = Number(gap);
	if (!Number.isFinite(n) || n <= 0) return null;
	if (n >= TIER_HERO_MIN_SAR) return "hero";
	if (n >= TIER_STRONG_MIN_SAR) return "strong";
	if (n >= TIER_REGULAR_MIN_SAR) return "regular";
	return "faint";
}

/** True when an item's highest observed price is one a person orders for themselves. */
export function isConsumerPrice(dearestPrice: unknown): boolean {
	const n = Number(dearestPrice);
	return Number.isFinite(n) && n > 0 && n <= CONSUMER_PRICE_CAP_SAR;
}
