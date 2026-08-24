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

	it("never offers Riyadh as a stand-in for a denied GPS fix", () => {
		for (const kind of ["denied", "unavailable", "timeout", "unsupported"] as const) {
			const en = geoLocationHelpMessage(false, kind);
			expect(en.toLowerCase()).not.toContain("riyadh");
			expect(en).not.toMatch(/24\.7136|46\.6753/);
		}
	});
});
