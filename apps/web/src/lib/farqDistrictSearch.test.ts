import { describe, expect, it } from "vitest";
import {
	districtDisambiguation,
	filterDistricts,
	normalizeDistrictText,
	rankDistricts,
} from "./farqDistrictSearch";
import type { CityDistricts } from "../services/intelligenceService";

const hood = (id: string, name_ar: string, name_en: string, opportunities: number, max_gap: number | null): CityDistricts["features"][number] => ({
	type: "Feature",
	id,
	geometry: { type: "Polygon", coordinates: [[[46, 24], [46.1, 24], [46.1, 24.1], [46, 24.1], [46, 24]]] },
	properties: {
		district_id: id,
		name_ar,
		name_en,
		bbox: [46, 24, 46.1, 24.1],
		label_point: [46.05, 24.05],
		places: opportunities + 1,
		opportunities,
		max_gap,
		top_place_id: null,
		comparisons: 0,
		wins: {},
		enough_for_app_verdict: false,
		cheapest_app: null,
		cheapest_app_wins: null,
	},
});

const CITY = [
	hood("riyadh-al-narjas", "النرجس", "Al Narjas", 114, 65),
	hood("riyadh-al-olaya", "العليا", "Al Olaya", 252, 61),
	hood("riyadh-al-nuzha", "النزهة", "Al Nuzha", 122, 60),
	hood("riyadh-al-nakheel", "النخيل", "Al Nakheel", 40, 30),
	hood("riyadh-al-rabie", "الربيع", "Al Rabie", 0, null),
];

describe("district search", () => {
	it("normalises the way people type: حي, ال, hamza, taa marbuta, digits, case", () => {
		expect(normalizeDistrictText("حي النرجس")).toBe("النرجس");
		expect(normalizeDistrictText("أحد ٢")).toBe("احد 2");
		expect(normalizeDistrictText("السليمانيّة")).toBe("السليمانيه");
		expect(normalizeDistrictText("  Al-Olaya ")).toBe("al olaya");
	});

	it("ranks by observed opportunities, then biggest gap", () => {
		expect(rankDistricts(CITY).map((f) => f.properties.district_id)).toEqual([
			"riyadh-al-olaya",
			"riyadh-al-nuzha",
			"riyadh-al-narjas",
			"riyadh-al-nakheel",
			"riyadh-al-rabie",
		]);
	});

	it("finds one حي from every spelling and keeps the busiest first among equals", () => {
		for (const q of ["النرجس", "حي النرجس", "نرجس", "Al Narjas", "narjas", "NARJAS"]) {
			expect(filterDistricts(CITY, q)[0].properties.district_id, q).toBe("riyadh-al-narjas");
		}
		/* "الن" is a prefix of النرجس, النزهة, النخيل — busiest first */
		expect(filterDistricts(CITY, "الن").map((f) => f.properties.district_id)).toEqual([
			"riyadh-al-nuzha",
			"riyadh-al-narjas",
			"riyadh-al-nakheel",
		]);
		/* an exact name outranks a longer prefix match */
		expect(filterDistricts([...CITY, hood("x", "النرجس الشرقي", "Al Narjas East", 999, 90)], "النرجس")[0].properties.district_id).toBe("riyadh-al-narjas");
	});

	it("returns everything ranked for an empty query and nothing for an unknown name", () => {
		expect(filterDistricts(CITY, "")).toHaveLength(CITY.length);
		expect(filterDistricts(CITY, "أتلانتس")).toEqual([]);
		expect(filterDistricts(null, "x")).toEqual([]);
	});
});


/**
 * Parity with apps/api/lib/arabic-text.js. These vectors appear verbatim in
 * apps/api/lib/arabic-text.test.js — change one side and the other fails, which
 * is the only thing keeping a hand-kept copy honest.
 */
const PARITY_VECTORS: Array<[string, string]> = [
	["حي النرجس", "النرجس"],
	["ﺣﻲ ﺍﻟﻨﺮﺟﺲ", "النرجس"],
	["حي ۵ نجوم", "5 نجوم"],
	["حي ٥ نجوم", "5 نجوم"],
	["Al Narjās", "al narjas"],
	["الشهداء", "الشهدا"],
	["مؤسسة", "موسسه"],
	["سائق", "سايق"],
	["كووول", "كول"],
	["کافيه", "كافيه"],
	["الرِّيَاض", "الرياض"],
	["الــرياض", "الرياض"],
	["بنك-الراجحي", "بنك الراجحي"]
];

describe("normalization parity with the API", () => {
	it("normalizes every shared vector to the agreed value", () => {
		for (const [input, expected] of PARITY_VECTORS) {
			expect(normalizeDistrictText(input)).toBe(expected);
		}
	});
});

describe("disambiguating two أحياء with one name", () => {
	const feature = (props: Record<string, unknown>) =>
		({ properties: { name_ar: "الشهداء", name_en: "Al Shohda", ...props } }) as never;

	it("qualifies a name only when the server said it collides", () => {
		expect(districtDisambiguation(feature({ name_hint_ar: "غرناطة", name_hint_en: "Granada" }), true))
			.toBe("قرب غرناطة");
		expect(districtDisambiguation(feature({ name_hint_ar: "غرناطة", name_hint_en: "Granada" }), false))
			.toBe("near Granada");
	});

	it("leaves a unique name alone", () => {
		expect(districtDisambiguation(feature({ name_hint_ar: null, name_hint_en: null }), true)).toBeNull();
		expect(districtDisambiguation(null, true)).toBeNull();
	});
});
