import { describe, expect, it } from "vitest";
import { sheetHeightPx } from "./FarqBottomSheet";

describe("sheetHeightPx", () => {
	it("keeps peek at 148px when the home indicator is 0", () => {
		expect(sheetHeightPx("peek", 800)).toBe(188);
		expect(sheetHeightPx("half", 800)).toBe(416);
		expect(sheetHeightPx("full", 800)).toBe(720);
	});

	it("adds the iOS safe-area so the camera clears the home indicator", () => {
		expect(sheetHeightPx("peek", 800, 34)).toBe(222);
		expect(sheetHeightPx("half", 800, 34)).toBe(450);
	});
});
