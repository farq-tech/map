import { describe, expect, it } from "vitest";
import {
	formatItemPrice,
	itemPriceCells,
} from "./SelectedPlaceSheet";

describe("compared items — the proof table's pure shaping", () => {
	it("orders the observed apps cheapest first and flags both ends", () => {
		const cells = itemPriceCells({ jahez: 195, ninja: 105, toyou: 180 });
		expect(cells.map((c) => c.providerId)).toEqual(["ninja", "toyou", "jahez"]);
		expect(cells[0]).toMatchObject({ price: 105, isCheapest: true, isDearest: false });
		expect(cells[2]).toMatchObject({ price: 195, isCheapest: false, isDearest: true });
	});

	it("an app with no observed price for the item is not a cell — never a null or a zero", () => {
		const cells = itemPriceCells({ ninja: 105, jahez: 195 });
		expect(cells.map((c) => c.providerId)).toEqual(["ninja", "jahez"]);
		expect(cells.some((c) => c.providerId === "mrsool")).toBe(false);
		expect(itemPriceCells({ ninja: 0, toyou: 12 }).map((c) => c.providerId)).toEqual([
			"toyou",
		]);
		expect(itemPriceCells(null)).toEqual([]);
	});

	it("same price on every app is evidence too, and crowns nobody", () => {
		const cells = itemPriceCells({ ninja: 13, toyou: 13 });
		expect(cells.every((c) => c.isCheapest)).toBe(true);
		expect(cells.some((c) => c.isDearest)).toBe(false);
	});

	it("prices keep observed halalas and stay in Western digits", () => {
		expect(formatItemPrice(105)).toBe("105");
		expect(formatItemPrice(10.5)).toBe("10.50");
		expect(formatItemPrice(7.5)).toBe("7.50");
	});
});
