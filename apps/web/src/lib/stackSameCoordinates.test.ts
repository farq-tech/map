import { describe, expect, it } from "vitest";
import {
	coordKey,
	stackAtPlaceId,
	stackFromFeature,
	stackSameCoordinateFeatures,
} from "./stackSameCoordinates";

function pin(id: string, lng: number, lat: number, gap = 10, name = id) {
	return {
		type: "Feature" as const,
		geometry: { type: "Point", coordinates: [lng, lat] },
		properties: { feature_type: "place", place_id: id, name, gap },
	};
}

describe("stack same coordinates — never a proximity merge", () => {
	it("leaves distinct coordinates alone", () => {
		const out = stackSameCoordinateFeatures([
			pin("1", 46.6779465, 24.6852364, 12, "أ"),
			pin("2", 46.6780465, 24.6852364, 18, "ب"),
		]);
		expect(out).toHaveLength(2);
		expect(out.every((f) => !f.properties?.stack_count)).toBe(true);
	});

	it("draws one pin for an exact food-court pile and keeps every id", () => {
		const lat = 24.6852364;
		const lng = 46.6779465;
		const many = [
			pin("451", lng, lat, 8, "ذا هولسوم بينج"),
			pin("689", lng, lat, 22, "تيمبو باستا"),
			pin("1288", lng, lat, 5, "هوم دوج"),
		];
		const out = stackSameCoordinateFeatures(many);
		expect(out).toHaveLength(1);
		expect(out[0].properties?.place_id).toBe("689");
		expect(out[0].properties?.stack_count).toBe(3);
		expect(out[0].properties?.stack_place_ids).toEqual(["689", "451", "1288"]);
		expect(out[0].properties?.stack_gaps).toEqual([22, 8, 5]);
		expect(out[0].properties?.never_merged).toBe(true);
		expect(stackFromFeature(out[0])?.members.map((m) => m.placeId)).toEqual([
			"689",
			"451",
			"1288",
		]);
		expect(stackFromFeature(out[0])?.members.map((m) => m.gap)).toEqual([22, 8, 5]);
		expect(stackAtPlaceId(many, "1288")?.members).toHaveLength(3);
	});

	it("does not treat a 30 m neighbour as the same pin", () => {
		/* ~0.0003° latitude is about 33 m — that is proximity, not this job. */
		const out = stackSameCoordinateFeatures([
			pin("a", 46.6779, 24.6852, 10),
			pin("b", 46.6779, 24.6855, 10),
		]);
		expect(out).toHaveLength(2);
		expect(coordKey(46.6779, 24.6852)).not.toBe(coordKey(46.6779, 24.6855));
	});
});
