import { describe, expect, it } from "vitest";
import {
	CONSUMER_PRICE_CAP_SAR,
	isConsumerPrice,
	TIER_HERO_MIN_SAR,
	TIER_REGULAR_MIN_SAR,
	TIER_STRONG_MIN_SAR,
	tierForGap,
} from "./farqOpportunityTiers";

describe("tierForGap — approved thresholds", () => {
	it("uses the approved boundaries 36 / 15 / 5", () => {
		expect(TIER_HERO_MIN_SAR).toBe(36);
		expect(TIER_STRONG_MIN_SAR).toBe(15);
		expect(TIER_REGULAR_MIN_SAR).toBe(5);
	});

	it("classifies boundary values inclusively", () => {
		expect(tierForGap(36)).toBe("hero");
		expect(tierForGap(35.9)).toBe("strong");
		expect(tierForGap(15)).toBe("strong");
		expect(tierForGap(14.99)).toBe("regular");
		expect(tierForGap(5)).toBe("regular");
		expect(tierForGap(4.99)).toBe("faint");
		expect(tierForGap(1)).toBe("faint");
	});

	it("never invents a tier for missing or non-positive gaps", () => {
		expect(tierForGap(0)).toBeNull();
		expect(tierForGap(-3)).toBeNull();
		expect(tierForGap(null)).toBeNull();
		expect(tierForGap(undefined)).toBeNull();
		expect(tierForGap("abc")).toBeNull();
	});

	it("accepts numeric strings as the API may send them", () => {
		expect(tierForGap("40")).toBe("hero");
	});
});

describe("isConsumerPrice — 200 SAR cap", () => {
	it("matches the API cap", () => {
		expect(CONSUMER_PRICE_CAP_SAR).toBe(200);
	});

	it("keeps dinners and drops banquets", () => {
		expect(isConsumerPrice(42)).toBe(true);
		expect(isConsumerPrice(200)).toBe(true);
		expect(isConsumerPrice(200.01)).toBe(false);
		expect(isConsumerPrice(6510)).toBe(false);
		expect(isConsumerPrice(0)).toBe(false);
		expect(isConsumerPrice(null)).toBe(false);
	});
});
