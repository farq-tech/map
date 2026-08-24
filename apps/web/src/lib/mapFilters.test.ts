import { describe, expect, it } from "vitest";
import {
	BIGGEST_SAVINGS_MIN_GAP,
	BIGGEST_SAVINGS_MIN_PRICE,
	encodeMapFilters,
	isBiggestSavingsPin,
	isGroceryIdentity,
	isMultiProviderPin,
	parseMapFilter,
	parseMapFilters,
	railFromMapSearch,
	toggleMapFilter,
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
		expect(parseMapFilters("biggest,multi")).toEqual({ biggest: true, multi: true });
		expect(toggleMapFilter("biggest", "multi")).toBe("biggest,multi");
		expect(encodeMapFilters({ biggest: false, multi: false })).toBeUndefined();
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

	it("keeps the filter rail on a bookmarked URL after refresh", () => {
		expect(railFromMapSearch({ filter: "biggest,multi" })).toBe("gaps");
		expect(railFromMapSearch({ filter: "multi" })).toBe("multi");
		expect(railFromMapSearch({ sort: "cheap", filter: "biggest" })).toBe("cheapest");
		expect(railFromMapSearch({})).toBe("restaurants");
	});
});
