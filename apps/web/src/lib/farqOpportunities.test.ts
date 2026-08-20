import { describe, expect, it } from "vitest";
import {
	TOP_OPPORTUNITIES,
	dedupeByBrand,
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

describe("one row per chain, a dinner order first", () => {
	const row = (
		placeId: string,
		amount: number,
		extra: Partial<OpportunityRow> = {},
	): OpportunityRow => ({ placeId, name: `مطعم ${placeId}`, amount, lat: 24.7, lng: 46.7, ...extra });

	it("keeps a brand once and counts the branches it folded", () => {
		const rows = [
			row("1", 30, { brandKey: "pizzahut" }),
			row("2", 30, { brandKey: "pizzahut" }),
			row("3", 30, { brandKey: "pizzahut" }),
			row("4", 12, { brandKey: "twina" }),
		];
		const out = dedupeByBrand(rows);
		expect(out.map((r) => r.placeId)).toEqual(["1", "4"]);
		expect(out[0].branchCount).toBe(3);
		expect(out[1].branchCount).toBeUndefined();
	});

	it("never merges rows it cannot prove are the same chain", () => {
		const rows = [row("1", 10), row("2", 9), row("3", 8, { brandKey: "" })];
		expect(dedupeByBrand(rows)).toHaveLength(3);
	});

	it("ranks a real order above a share box of the same size, and the map keeps every branch", () => {
		const rows = [
			row("box", 60, { demoteReason: "share" }),
			row("dish", 40),
			row("tub", 55, { demoteReason: "retail" }),
		];
		expect(rankOpportunities(rows, "gap").map((r) => r.placeId)).toEqual(["dish", "box", "tub"]);
		/* Opting out of the dedupe is how the map keeps every branch pin. */
		expect(topOpportunities([row("a", 5, { brandKey: "x" }), row("b", 4, { brandKey: "x" })], "gap", 10, { dedupeBrands: false })).toHaveLength(2);
	});
});
