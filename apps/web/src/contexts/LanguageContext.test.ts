// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { applyDocumentLanguage } from "./LanguageContext";

describe("document language", () => {
	it("keeps html lang and dir on the same locale", () => {
		applyDocumentLanguage("en");
		expect(document.documentElement.lang).toBe("en");
		expect(document.documentElement.dir).toBe("ltr");
		applyDocumentLanguage("ar");
		expect(document.documentElement.lang).toBe("ar");
		expect(document.documentElement.dir).toBe("rtl");
	});
});
