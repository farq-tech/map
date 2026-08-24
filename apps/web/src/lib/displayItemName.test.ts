import { describe, expect, it } from "vitest";
import { displayItemName } from "./displayItemName";

describe("displayItemName — 6254 honesty", () => {
	it("drops the calorie tail so 81 SAR is not read as 250", () => {
		expect(displayItemName("بون بون تشوكليت القهوة  سعره 250 ")).toBe(
			"بون بون تشوكليت القهوة",
		);
		expect(displayItemName("Bonbon Coffee Chocolate cal 250")).toBe(
			"Bonbon Coffee Chocolate",
		);
		expect(displayItemName("شاورما عربي")).toBe("شاورما عربي");
		expect(displayItemName("03003641")).toBe("03003641");
	});
});
