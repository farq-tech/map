import { describe, expect, it } from "vitest";
import { MIN_APP_VERDICT_COMPARISONS, viewportStats } from "./farqViewportStats";

const feat = (lng: number, lat: number, gap: number | null, wins?: Record<string, number>) => ({
	geometry: { type: "Point", coordinates: [lng, lat] },
	properties: { gap, has_difference: gap != null, wins: wins ?? null },
});

describe("viewportStats", () => {
	it("counts only opportunities inside the bbox and reports the biggest", () => {
		const s = viewportStats(
			[feat(46.7, 24.7, 12), feat(46.71, 24.71, 40), feat(46.9, 24.9, 99)],
			[46.6, 24.6, 46.8, 24.8],
		);
		expect(s.count).toBe(2);
		expect(s.maxGap).toBe(40);
	});

	it("offers an app verdict only with enough comparisons, and always with its sample", () => {
		const few = viewportStats([feat(46.7, 24.7, 10, { jahez: 3, mrsool: 1 })], null);
		expect(few.comparisons).toBe(4);
		expect(few.verdict).toBeNull();

		const enough = viewportStats(
			[feat(46.7, 24.7, 10, { jahez: 3, mrsool: 1 }), feat(46.71, 24.7, 5, { mrsool: 6 })],
			null,
		);
		expect(enough.comparisons).toBe(10);
		expect(enough.comparisons).toBeGreaterThanOrEqual(MIN_APP_VERDICT_COMPARISONS);
		expect(enough.verdict).toEqual({
			provider: "mrsool",
			wins: 7,
			comparisons: 10,
			runnerUp: { provider: "jahez", wins: 3 },
		});
	});

	it("returns an empty, honest result for no data", () => {
		const s = viewportStats([], [0, 0, 1, 1]);
		expect(s).toEqual({ count: 0, maxGap: null, comparisons: 0, verdict: null });
	});

	it("ignores features without usable coordinates or gaps", () => {
		const s = viewportStats(
			[
				{ geometry: null, properties: { gap: 50 } },
				feat(46.7, 24.7, null, { jahez: 9 }),
			],
			null,
		);
		expect(s.count).toBe(0);
		expect(s.maxGap).toBeNull();
		expect(s.verdict?.provider).toBe("jahez");
	});
});
