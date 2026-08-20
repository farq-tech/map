import { describe, expect, it } from "vitest";
import {
	TOP_OPPORTUNITIES,
	formatObservedDistance,
	observedDistanceMeters,
	rankOpportunities,
	topOpportunities,
	type OpportunityRow,
} from "./farqOpportunities";

const row = (
	id: string,
	amount: number,
	opts?: Partial<OpportunityRow>,
): OpportunityRow => ({
	placeId: id,
	name: id,
	amount,
	lat: 24.71,
	lng: 46.67,
	...opts,
});

describe("top opportunities — one world for list and map", () => {
	it("caps display at 10 after ranking", () => {
		expect(TOP_OPPORTUNITIES).toBe(10);
		const rows = Array.from({ length: 20 }, (_, i) => row(`p${i}`, i + 1));
		const top = topOpportunities(rows, "gap");
		expect(top).toHaveLength(10);
		expect(top.map((r) => r.placeId)).toEqual([
			"p19",
			"p18",
			"p17",
			"p16",
			"p15",
			"p14",
			"p13",
			"p12",
			"p11",
			"p10",
		]);
	});

	it("sorts cheap by observed cheapest_price only", () => {
		const ranked = rankOpportunities(
			[
				row("a", 40, { cheapestPrice: 79 }),
				row("b", 12, { cheapestPrice: 22 }),
				row("c", 30),
			],
			"cheap",
		);
		expect(ranked.map((r) => r.placeId)).toEqual(["b", "a", "c"]);
	});

	it("sorts near by real metres — never invents a distance", () => {
		expect(observedDistanceMeters(null, null, 24.71, 46.67)).toBeNull();
		expect(formatObservedDistance(null, true)).toBeNull();
		expect(formatObservedDistance(450, true)).toBe("٤٥٠ م");
		const ranked = rankOpportunities(
			[
				row("far", 50, { distanceMeters: 4000 }),
				row("near", 12, { distanceMeters: 300 }),
			],
			"near",
		);
		expect(ranked[0]?.placeId).toBe("near");
		const fallback = rankOpportunities(
			[row("big", 40), row("small", 8)],
			"near",
		);
		expect(fallback[0]?.placeId).toBe("big");
	});
});
