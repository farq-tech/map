import { describe, expect, it } from "vitest";
import {
	BIGGEST_SAVINGS_MIN_GAP,
	BIGGEST_SAVINGS_MIN_PRICE,
	isBiggestSavingsPin,
	isGroceryIdentity,
	isMultiProviderPin,
	parseMapFilter,
} from "./mapFilters";

describe("map filters — client floors match the API", () => {
	it("keeps the comparison-read floors", () => {
		expect(BIGGEST_SAVINGS_MIN_GAP).toBe(10);
		expect(BIGGEST_SAVINGS_MIN_PRICE).toBe(15);
	});

	it("parses biggest / multi without inventing a third filter", () => {
		expect(parseMapFilter("biggest")).toBe("biggest");
		expect(parseMapFilter("multi")).toBe("multi");
		expect(parseMapFilter("near")).toBeUndefined();
	});

	it("does not treat restaurant names as grocery storefronts", () => {
		expect(isGroceryIdentity({ name: "شاورما البيت" })).toBe(false);
		expect(isGroceryIdentity({ name: "تموينات الندى" })).toBe(true);
		expect(isGroceryIdentity({ category_gaps: { grocery: 4 } })).toBe(true);
	});

	it("applies biggest-savings and 3+ apps on observed fields only", () => {
		expect(
			isBiggestSavingsPin({
				gap: 12,
				cheapest_price: 9,
				cheapest_provider_id: "jahez",
			}),
		).toBe(false);
		expect(
			isBiggestSavingsPin({
				gap: 18,
				cheapest_price: 39,
				cheapest_provider_id: "jahez",
			}),
		).toBe(true);
		expect(isMultiProviderPin({ provider_count: 2 })).toBe(false);
		expect(isMultiProviderPin({ provider_count: 3 })).toBe(true);
	});
});
