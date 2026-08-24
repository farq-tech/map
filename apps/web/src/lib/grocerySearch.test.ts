import { describe, expect, it } from "vitest";
import { groceryCompareSearch } from "./grocerySearch";

describe("grocery compare search", () => {
	it("never carries a restaurant name as a product query", () => {
		expect(groceryCompareSearch()).toEqual({ q: undefined });
		expect("q" in groceryCompareSearch()).toBe(true);
	});
});
