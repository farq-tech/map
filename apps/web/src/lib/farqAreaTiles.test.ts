import { describe, expect, it } from "vitest";
import { AREA_LABEL_BUDGET, AREA_MAX_ZOOM, toAreaCollection } from "./farqAreaTiles";
import type { CityAreas } from "../services/intelligenceService";

const cell = (h3: string, opportunities: number, max_gap: number | null): CityAreas["features"][number] => ({
	type: "Feature",
	id: h3,
	geometry: { type: "Polygon", coordinates: [[[46, 24], [46.01, 24], [46.01, 24.01], [46, 24]]] },
	properties: { h3, places: opportunities + 1, opportunities, max_gap, top_place_id: null, comparisons: 0, wins: {}, enough_for_app_verdict: false, cheapest_app: null, cheapest_app_wins: null },
});

describe("area field", () => {
	it("labels only the busiest cells within the budget and drops empty cells", () => {
		const areas = { type: "FeatureCollection", city: "riyadh", resolution: 8, min_comparisons_for_app_verdict: 8, generated_at: null, count: 12, features: [
			...Array.from({ length: 11 }, (_, i) => cell(`c${i}`, 11 - i, 50 - i)),
			cell("empty", 0, null),
		] } as CityAreas;
		const fc = toAreaCollection(areas);
		expect(fc.features).toHaveLength(11);
		expect(fc.features.filter((f) => f.properties?.labelled)).toHaveLength(AREA_LABEL_BUDGET);
		expect(fc.features[0].properties?.h3).toBe("c0");
	});

	it("hands over to clusters before the cluster break zoom", () => {
		expect(AREA_MAX_ZOOM).toBeLessThan(14);
	});

	it("returns an empty collection for no data", () => {
		expect(toAreaCollection(null).features).toEqual([]);
	});
});
