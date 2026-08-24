import { describe, expect, it } from "vitest";
import { displayItemName } from "./displayItemName";

describe("displayItemName — scraper residue", () => {
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

	it("drops (Cal: N), 5-digit SKUs, Arabic-Indic codes, and bidi marks", () => {
		expect(displayItemName("سمبوسة البطاطس (Cal: 236)")).toBe("سمبوسة البطاطس");
		expect(displayItemName("البطاطس المقلية (Cal: 390)")).toBe("البطاطس المقلية");
		expect(displayItemName("معمول كحيله كبير 00608")).toBe("معمول كحيله كبير");
		expect(displayItemName("معمول الاصيله صغير00751")).toBe("معمول الاصيله صغير");
		expect(displayItemName("ترافل هنوفريان - ١٢٣٤٥٧")).toBe("ترافل هنوفريان");
		expect(displayItemName("بديع بقلاوة بيكان كبير ١٠٧٠٠٢٤٣")).toBe(
			"بديع بقلاوة بيكان كبير",
		);
		expect(displayItemName("\u200fوجبة برجر كريسبي")).toBe("وجبة برجر كريسبي");
		expect(displayItemName("امبيريال كبير ٢٢حبة_١٠٧٠٠٢٢")).toBe(
			"امبيريال كبير ٢٢حبة",
		);
	});

	it("keeps real deal names and grams", () => {
		expect(displayItemName("عرض باسكوالي 79 ريال")).toBe("عرض باسكوالي 79 ريال");
		expect(displayItemName("٢ بيتزا كبيرة بـ ٣٩ ريال")).toBe(
			"٢ بيتزا كبيرة بـ ٣٩ ريال",
		);
		expect(displayItemName("كوب حراري")).toBe("كوب حراري");
	});
});
