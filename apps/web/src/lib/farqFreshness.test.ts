import { describe, expect, it } from "vitest";
import { readLayerFreshness, STALE_AFTER_DAYS } from "./farqFreshness";

const NOW = Date.parse("2026-08-20T12:00:00Z");
const daysAgo = (d: number) => new Date(NOW - d * 86_400_000).toISOString();

describe("read-layer freshness", () => {
	it("says the age in the Arabic a person would use", () => {
		expect(readLayerFreshness(daysAgo(0), true, NOW)?.label).toBe("محدّث اليوم");
		expect(readLayerFreshness(daysAgo(1), true, NOW)?.label).toBe("محدّث أمس");
		expect(readLayerFreshness(daysAgo(2), true, NOW)?.label).toBe("محدّث قبل يومين");
		expect(readLayerFreshness(daysAgo(4), true, NOW)?.label).toBe("محدّث قبل ٤ أيام");
		expect(readLayerFreshness(daysAgo(15), true, NOW)?.label).toBe("محدّث قبل ١٥ يومًا");
	});

	it("says it in English too, with Western digits", () => {
		expect(readLayerFreshness(daysAgo(0), false, NOW)?.label).toBe("Updated today");
		expect(readLayerFreshness(daysAgo(1), false, NOW)?.label).toBe("Updated yesterday");
		expect(readLayerFreshness(daysAgo(4), false, NOW)?.label).toBe("Updated 4 days ago");
	});

	it("flags staleness only past the agreed threshold", () => {
		expect(readLayerFreshness(daysAgo(STALE_AFTER_DAYS - 1), true, NOW)?.stale).toBe(false);
		expect(readLayerFreshness(daysAgo(STALE_AFTER_DAYS), true, NOW)?.stale).toBe(true);
	});

	it("says nothing rather than guessing", () => {
		expect(readLayerFreshness(null, true, NOW)).toBeNull();
		expect(readLayerFreshness("", true, NOW)).toBeNull();
		expect(readLayerFreshness("not-a-date", true, NOW)).toBeNull();
	});

	it("treats a future timestamp as a clock problem, not as negative age", () => {
		expect(readLayerFreshness(daysAgo(-3), true, NOW)?.days).toBe(0);
	});
});
