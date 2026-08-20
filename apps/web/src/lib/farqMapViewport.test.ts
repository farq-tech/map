import { describe, expect, it } from "vitest";
import {
	lngLatInBbox,
	parseMapBbox,
	shouldOfferSearchHere,
	viewMovedEnough,
} from "./farqMapViewport";

const fetched = {
	bbox: "46.60,24.60,46.80,24.80",
	zoom: 13,
};

describe("farqMapViewport — search-here gating", () => {
	it("parses west,south,east,north and rejects junk", () => {
		expect(parseMapBbox(fetched.bbox)).toEqual({
			west: 46.6,
			south: 24.6,
			east: 46.8,
			north: 24.8,
		});
		expect(parseMapBbox("1,2,3")).toBeNull();
		expect(parseMapBbox("46.8,24.6,46.6,24.8")).toBeNull();
	});

	it("keeps a pin inside the fetched bbox only", () => {
		const box = parseMapBbox(fetched.bbox);
		expect(box).not.toBeNull();
		if (!box) return;
		expect(lngLatInBbox(46.7, 24.7, box)).toBe(true);
		expect(lngLatInBbox(46.9, 24.7, box)).toBe(false);
	});

	it("does not treat the first view as a move", () => {
		expect(viewMovedEnough(null, fetched)).toBe(false);
	});

	it("offers Search-here after a user pan, never after programmatic idle", () => {
		const panned = {
			bbox: "46.72,24.70,46.92,24.90",
			zoom: 13,
		};
		expect(
			shouldOfferSearchHere({
				userGesture: true,
				hasFetched: true,
				fetched,
				current: panned,
			}),
		).toBe(true);
		expect(
			shouldOfferSearchHere({
				userGesture: false,
				hasFetched: true,
				fetched,
				current: panned,
			}),
		).toBe(false);
		expect(
			shouldOfferSearchHere({
				userGesture: true,
				hasFetched: false,
				fetched: null,
				current: fetched,
			}),
		).toBe(false);
		expect(
			shouldOfferSearchHere({
				userGesture: true,
				hasFetched: true,
				fetched,
				current: fetched,
			}),
		).toBe(false);
	});

	it("offers Search-here when zoom changes enough", () => {
		expect(
			shouldOfferSearchHere({
				userGesture: true,
				hasFetched: true,
				fetched,
				current: { bbox: fetched.bbox, zoom: 14.2 },
			}),
		).toBe(true);
	});
});
