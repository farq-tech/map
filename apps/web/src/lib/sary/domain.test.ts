import { describe, expect, it } from "vitest";
import {
	evidenceLabel,
	isValidLngLat,
	isWeakGps,
	kindFromName,
	kindLabel,
} from "./domain";

describe("sary domain", () => {
	it("classifies Saudi outdoor names without inventing a kind", () => {
		expect(kindFromName("روضة الخفس")).toBe("rawdah");
		expect(kindFromName("شعيب")).toBe("shaib");
		expect(kindFromName("مطعم")).toBeNull();
	});

	it("rejects coordinates outside Saudi bounds", () => {
		expect(isValidLngLat(46.67, 24.71)).toBe(true);
		expect(isValidLngLat(0, 0)).toBe(false);
		expect(isValidLngLat(Number.NaN, 24)).toBe(false);
	});

	it("treats accuracy worse than 50 m as weak GPS", () => {
		expect(isWeakGps(12)).toBe(false);
		expect(isWeakGps(80)).toBe(true);
		expect(isWeakGps(null)).toBe(false);
	});

	it("labels evidence honestly", () => {
		expect(evidenceLabel("unconfirmed", true)).toBe("غير مؤكد");
		expect(kindLabel("osm_track", true)).toBe("مسار OSM");
	});
});
