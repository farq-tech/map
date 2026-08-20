import { describe, expect, it } from "vitest";
import {
	DISTRICT_FILL_MAX_ZOOM,
	DISTRICT_FILL_STEPS,
	DISTRICT_LINE_MAX_ZOOM,
	APP_LENS_MAX_ZOOM,
	districtBounds,
	toDistrictCollection,
	toDistrictLabelCollection,
} from "./farqDistrictTiles";
import { AREA_MAX_ZOOM } from "./farqAreaTiles";
import { CLUSTER_BREAK_ZOOM } from "./farqMapPins";
import type { CityDistricts } from "../services/intelligenceService";

const hood = (id: string, opportunities: number, max_gap: number | null): CityDistricts["features"][number] => ({
	type: "Feature",
	id,
	geometry: { type: "Polygon", coordinates: [[[46, 24], [46.1, 24], [46.1, 24.1], [46, 24.1], [46, 24]]] },
	properties: {
		district_id: id,
		name_ar: `حي ${id}`,
		name_en: `District ${id}`,
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

const collection = (features: CityDistricts["features"]): CityDistricts => ({
	type: "FeatureCollection",
	city: "riyadh",
	source: "test",
	min_comparisons_for_app_verdict: 8,
	generated_at: null,
	count: features.length,
	features,
});

describe("district field", () => {
	it("draws every حي, including the empty ones, and never invents one", () => {
		const fc = toDistrictCollection(
			collection([...Array.from({ length: 12 }, (_, i) => hood(`d${i}`, 30 - i, 50 - i)), hood("empty", 0, null)]),
		);
		expect(fc.features).toHaveLength(13);
		expect(fc.features.find((f) => f.properties?.district_id === "empty")?.properties?.opportunities).toBe(0);
	});

	it("offers every حي that has a gap as a label, biggest first, so collision picks per screen", () => {
		const noPoint = hood("np", 99, 70);
		noPoint.properties.label_point = null;
		const labels = toDistrictLabelCollection(
			collection([hood("a", 40, 20), hood("b", 9, 65), hood("empty", 0, null), noPoint]),
		);
		/* Ranked by the number the label actually prints — the biggest gap — so the
		 * city's headline figure is findable on the map. A حي with no interior
		 * point cannot be labelled honestly and is left out. */
		expect(labels.features.map((f) => f.properties?.district_id)).toEqual(["b", "a"]);
		expect(labels.features[0].geometry).toEqual({ type: "Point", coordinates: [46.05, 24.05] });
		expect(labels.features[0].properties).toMatchObject({ name_ar: "حي b", name_en: "District b", max_gap: 65 });
	});

	it("keeps both names and the biggest gap on every feature, keyed by district_id", () => {
		const fc = toDistrictCollection(collection([hood("x", 4, 22)]));
		expect(fc.features[0].id).toBe("x");
		expect(fc.features[0].properties).toMatchObject({ district_id: "x", name_ar: "حي x", name_en: "District x", max_gap: 22 });
	});

	it("returns an empty collection for no data", () => {
		expect(toDistrictCollection(null).features).toEqual([]);
		expect(toDistrictLabelCollection(null).features).toEqual([]);
	});

	it("frames a حي by its own rings and refuses a degenerate one", () => {
		expect(districtBounds(hood("a", 1, 1))).toEqual([46, 24, 46.1, 24.1]);
		expect(
			districtBounds({ geometry: { type: "MultiPolygon", coordinates: [[[[46, 24], [46.2, 24], [46.2, 24.3], [46, 24]]], [[[47, 25], [47.1, 25], [47.1, 25.1], [47, 25]]]] } }),
		).toEqual([46, 24, 47.1, 25.1]);
		expect(districtBounds({ geometry: { type: "Polygon", coordinates: [[[46, 24], [46, 24], [46, 24]]] } })).toBeNull();
		expect(districtBounds(null)).toBeNull();
	});

	it("tints by count in ascending steps that start at one observed opportunity — the legend draws the same steps", () => {
		expect(DISTRICT_FILL_STEPS[0].min).toBe(1);
		for (let i = 1; i < DISTRICT_FILL_STEPS.length; i += 1) {
			expect(DISTRICT_FILL_STEPS[i].min).toBeGreaterThan(DISTRICT_FILL_STEPS[i - 1].min);
			expect(DISTRICT_FILL_STEPS[i].opacity).toBeGreaterThan(DISTRICT_FILL_STEPS[i - 1].opacity);
		}
		expect(DISTRICT_FILL_STEPS[DISTRICT_FILL_STEPS.length - 1].opacity).toBeLessThanOrEqual(0.5);
	});

	it("hands the picture over in the same order as the H3 field: fill → clusters, lines gone before the pins", () => {
		expect(DISTRICT_FILL_MAX_ZOOM).toBe(AREA_MAX_ZOOM);
		expect(DISTRICT_FILL_MAX_ZOOM).toBeLessThan(CLUSTER_BREAK_ZOOM);
		expect(DISTRICT_LINE_MAX_ZOOM).toBeGreaterThan(DISTRICT_FILL_MAX_ZOOM);
		expect(DISTRICT_LINE_MAX_ZOOM).toBeLessThanOrEqual(CLUSTER_BREAK_ZOOM + 0.5);
	});

	it("the app lens survives past the zoom the map actually lands on", () => {
		const LANDING_ZOOM = 12.15;
		expect(DISTRICT_FILL_MAX_ZOOM).toBeLessThan(LANDING_ZOOM);
		expect(APP_LENS_MAX_ZOOM).toBeGreaterThan(LANDING_ZOOM);
		expect(APP_LENS_MAX_ZOOM).toBeLessThanOrEqual(CLUSTER_BREAK_ZOOM);
	});
});
