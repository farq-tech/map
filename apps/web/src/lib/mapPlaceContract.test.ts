import { describe, expect, it } from "vitest";
import {
	livePlaceDetail,
	normalizeDifference,
	normalizePlaceDetail,
	normalizePlaceFeature,
	observedGapAmount,
} from "./mapPlaceContract";

describe("map place contract — nested + lean Railway pins", () => {
	it("reads a nested difference without inventing prices", () => {
		const diff = normalizeDifference({
			difference: {
				difference_amount: 18,
				cheapest_provider_id: "jahez",
				expensive_provider_id: "hungerstation",
			},
		});
		expect(diff?.difference_amount).toBe(18);
		expect(diff?.cheapest_provider_id).toBe("jahez");
		expect(diff?.cheapest_price).toBeNull();
	});

	it("reads the live lean pin (gap / flat providers)", () => {
		const diff = normalizeDifference({
			gap: 13,
			cheapest_provider_id: "jahez",
			expensive_provider_id: "hungerstation",
			cheapest_price: 39,
			expensive_price: 52,
			product_name: "طبق الدجاج المشوي",
			has_difference: true,
		});
		expect(diff).toEqual({
			difference_amount: 13,
			cheapest_provider_id: "jahez",
			expensive_provider_id: "hungerstation",
			cheapest_price: 39,
			expensive_price: 52,
			product_name: "طبق الدجاج المشوي",
		});
		expect(observedGapAmount({ gap: 13 })).toBe(13);
	});

	it("does not mint a gap from a provider id alone", () => {
		expect(normalizeDifference({ cheapest_provider_id: "" })).toBeNull();
		expect(normalizeDifference({})).toBeNull();
		expect(observedGapAmount({ has_difference: false })).toBeNull();
	});

	it("fills restaurant_id from place_id for lean pins", () => {
		const feature = normalizePlaceFeature({
			type: "Feature",
			geometry: { type: "Point", coordinates: [46.67, 24.71] },
			properties: { feature_type: "place", place_id: "1381", gap: 1, cheapest_provider_id: "jahez" },
		});
		expect(feature.properties.restaurant_id).toBe("1381");
		expect(feature.properties.difference).toMatchObject({ difference_amount: 1, cheapest_provider_id: "jahez" });
	});

	it("does not keep the previous restaurant's prices on a new selection", () => {
		const previous = { place_id: "1381", name: "بابا عنتر" };
		expect(livePlaceDetail(previous, "6411")).toBeNull();
		expect(livePlaceDetail(previous, "1381")).toBe(previous);
		expect(livePlaceDetail(previous, "")).toBeNull();
	});

	it("fills lean gap on getPlace from the observed nested difference", () => {
		const coated = normalizePlaceDetail({
			place_id: "6254",
			name: "كوتد",
			difference: { difference_amount: 81, cheapest_provider_id: "hungerstation" },
		});
		expect(coated?.gap).toBe(81);
		expect(
			normalizePlaceDetail({
				place_id: "6254",
				gap: 81,
				difference: { difference_amount: 81, cheapest_provider_id: "hungerstation" },
			})?.gap,
		).toBe(81);
		expect(normalizePlaceDetail({ place_id: "99999999" })?.gap).toBeUndefined();
	});
});
