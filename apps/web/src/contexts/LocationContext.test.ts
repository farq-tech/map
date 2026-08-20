import { describe, expect, it } from "vitest";
import {
	geoErrorKindFromCode,
	geoLocationHelpMessage,
} from "./LocationContext";

describe("geo location copy", () => {
	it("maps geolocation codes without inventing a fallback place", () => {
		expect(geoErrorKindFromCode(1)).toBe("denied");
		expect(geoErrorKindFromCode(2)).toBe("unavailable");
		expect(geoErrorKindFromCode(3)).toBe("timeout");
	});

	it("tells iPhone Safari users how to enable location in Arabic", () => {
		const ar = geoLocationHelpMessage(true, "denied");
		expect(ar).toContain("سفاري");
		expect(ar).toContain("إعدادات الآيفون");
		expect(ar).toContain("خدمة الموقع");
		expect(ar).not.toMatch(/الرياض|24\.7136/);
	});
});
