/**
 * What the camera shows, in one honest line.
 *
 * Counts and maxima come from the opportunities inside the viewport; the
 * "which app is cheapest around you" verdict sums, per app, how often that
 * app was the cheapest across the compared items of those restaurants. A
 * verdict is only offered when the sample is large enough (approved minimum:
 * 8 comparisons) and it always carries its sample size, never a bare claim.
 */

export const MIN_APP_VERDICT_COMPARISONS = 8;

export type AppVerdict = {
	provider: string;
	wins: number;
	comparisons: number;
	/** second place, for copy like "مرسول 14 · جاهز 5" */
	runnerUp: { provider: string; wins: number } | null;
};

export type ViewportStats = {
	count: number;
	maxGap: number | null;
	comparisons: number;
	verdict: AppVerdict | null;
};

type StatFeature = {
	geometry?: { type?: string; coordinates?: unknown } | null;
	properties?: {
		gap?: unknown;
		has_difference?: unknown;
		wins?: Record<string, unknown> | null;
	} | null;
};

function coords(f: StatFeature): [number, number] | null {
	const c = f.geometry?.coordinates;
	if (!Array.isArray(c) || c.length < 2) return null;
	const lng = Number(c[0]);
	const lat = Number(c[1]);
	return Number.isFinite(lng) && Number.isFinite(lat) ? [lng, lat] : null;
}

export function viewportStats(
	features: StatFeature[],
	bbox: [number, number, number, number] | null,
	minComparisons = MIN_APP_VERDICT_COMPARISONS,
): ViewportStats {
	let count = 0;
	let maxGap: number | null = null;
	let comparisons = 0;
	const wins = new Map<string, number>();
	for (const f of features) {
		const c = coords(f);
		if (!c) continue;
		if (bbox && (c[0] < bbox[0] || c[0] > bbox[2] || c[1] < bbox[1] || c[1] > bbox[3])) continue;
		const p = f.properties || {};
		const gap = Number(p.gap);
		if (Number.isFinite(gap) && gap >= 1) {
			count += 1;
			if (maxGap == null || gap > maxGap) maxGap = gap;
		}
		if (p.wins && typeof p.wins === "object") {
			for (const [provider, n] of Object.entries(p.wins)) {
				const v = Number(n);
				if (!Number.isFinite(v) || v <= 0) continue;
				wins.set(provider, (wins.get(provider) || 0) + v);
				comparisons += v;
			}
		}
	}
	let verdict: AppVerdict | null = null;
	if (comparisons >= minComparisons && wins.size > 0) {
		const ranked = [...wins.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
		const [provider, top] = ranked[0];
		const second = ranked[1];
		verdict = {
			provider,
			wins: top,
			comparisons,
			runnerUp: second ? { provider: second[0], wins: second[1] } : null,
		};
	}
	return { count, maxGap: maxGap == null ? null : Math.round(maxGap), comparisons, verdict };
}
