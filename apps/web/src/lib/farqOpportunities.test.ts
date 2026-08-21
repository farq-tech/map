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

describe("الأعلى نسبة", () => {
	it("puts a real amount of money above a bigger percentage of nothing", () => {
		/* The exact shape measured on the live read layer: cans and side orders
		 * tie at the source's ratio ceiling, and a 40-riyal meal gap loses to
		 * them unless the sort insists on riyals first. */
		const rows = [
			row("mirinda", 9, { pct: 47.4 }),
			row("fries", 9, { pct: 47.4 }),
			row("meal", 40, { pct: 31 }),
		];
		expect(rankOpportunities(rows, "value").map((r) => r.placeId)[0]).toBe("meal");
	});

	it("ranks by share among rows that clear the floor, and still demotes a share box", () => {
		const rows = [
			row("small-share", 30, { pct: 20 }),
			row("big-share", 30, { pct: 45 }),
			row("party-box", 30, { pct: 60, demoteReason: "share" }),
		];
		expect(rankOpportunities(rows, "value").map((r) => r.placeId)).toEqual([
			"big-share",
			"small-share",
			"party-box",
		]);
	});

	it("falls back to the observed gap when the server sent no percentage", () => {
		const rows = [row("a", 12), row("b", 30)];
		expect(rankOpportunities(rows, "value").map((r) => r.placeId)).toEqual(["b", "a"]);
	});
});
