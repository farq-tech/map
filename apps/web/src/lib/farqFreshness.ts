/**
 * How old the comparison is, said plainly.
 *
 * Freshness is a property of the whole read layer, not of a place: the source
 * carries no per-restaurant observation time, so there is exactly one honest
 * timestamp — `generated_at` — and it belongs on screen rather than buried in
 * a tooltip. A person deciding where to order deserves to know whether these
 * prices are hours or weeks old before they trust them.
 *
 * Nothing here rounds in our favour: an unknown timestamp says nothing at all.
 */
import { localizeDigitString } from "./formatPrice";

export type Freshness = {
	days: number;
	label: string;
	/** True once the read layer is old enough that a price may well have moved. */
	stale: boolean;
};

/** Beyond this the wording stops implying the number is current. */
export const STALE_AFTER_DAYS = 7;

function arabicAgo(days: number): string {
	const n = (v: number) => localizeDigitString(String(v), true);
	if (days <= 0) return "محدّث اليوم";
	if (days === 1) return "محدّث أمس";
	if (days === 2) return "محدّث قبل يومين";
	if (days <= 10) return `محدّث قبل ${n(days)} أيام`;
	return `محدّث قبل ${n(days)} يومًا`;
}

function englishAgo(days: number): string {
	if (days <= 0) return "Updated today";
	if (days === 1) return "Updated yesterday";
	return `Updated ${days} days ago`;
}

/**
 * @param generatedAt ISO timestamp from the read layer, or null when unknown.
 * @param now injected so the wording can be tested without freezing the clock.
 */
export function readLayerFreshness(
	generatedAt: string | null | undefined,
	isRTL: boolean,
	now: number = Date.now(),
): Freshness | null {
	if (!generatedAt) return null;
	const at = Date.parse(generatedAt);
	if (!Number.isFinite(at)) return null;
	/* A timestamp from the future is a clock problem, not freshness — treat as today. */
	const days = Math.max(0, Math.floor((now - at) / 86_400_000));
	return {
		days,
		label: isRTL ? arabicAgo(days) : englishAgo(days),
		stale: days >= STALE_AFTER_DAYS,
	};
}
