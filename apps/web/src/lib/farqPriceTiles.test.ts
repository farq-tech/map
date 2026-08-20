// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { FARQ_BRAND_900, FARQ_MINT } from "./farqBrandAssets";
import {
	FAR_BEACON_PX,
	FAR_BEACON_RADIUS,
	FAR_BEACON_TEXT_SIZE,
	GPU_CHIP_PX,
	GPU_CHIP_RADIUS,
	GPU_CHIP_TEXT_SIZE,
	GPU_CLUSTER_TEXT_SIZE,
	GPU_ICON_FALLBACK,
	GPU_ICON_PX,
	PRICE_CIRCLE_FILL,
	PRICE_CIRCLE_TEXT,
	cheapestProviderId,
	hashPriceTileCollection,
	pinGapAmount,
	gpuIconId,
	toPriceTileCollection,
} from "./farqPriceTiles";

const point = (
	placeId: string,
	opts?: {
		gap?: number;
		provider?: string;
		selected?: boolean;
		name?: string;
	},
): GeoJSON.Feature => ({
	type: "Feature",
	geometry: { type: "Point", coordinates: [46.67, 24.71] },
	properties: {
		feature_type: "place",
		place_id: placeId,
		name: opts?.name || "كودو",
		gap: opts?.gap,
		cheapest_provider_id: opts?.provider,
	},
});

describe("GPU price tiles — slim fields + hash skip", () => {
	it("reads slim gap / cheapest_provider_id and skips selected", () => {
		expect(pinGapAmount({ gap: 18.4 })).toBe(18.4);
		expect(pinGapAmount({ difference: { difference_amount: 12 } })).toBe(12);
		expect(cheapestProviderId({ cheapest_provider_id: "hs" })).toBe(
			"hungerstation",
		);
		expect(gpuIconId("jahez")).toBe("farq-icon-jahez");
		expect(gpuIconId("unknown")).toBe(GPU_ICON_FALLBACK);
		expect(GPU_CHIP_PX).toBeLessThan(GPU_ICON_PX);
		expect(GPU_CHIP_PX).toBeGreaterThanOrEqual(20);
		expect(GPU_CHIP_PX).toBeLessThanOrEqual(26);
		expect(GPU_CHIP_RADIUS).toBe(GPU_CHIP_PX / 2);
		expect(GPU_CHIP_TEXT_SIZE).toBeGreaterThanOrEqual(12);
		expect(GPU_CHIP_TEXT_SIZE).toBeLessThanOrEqual(14);
		expect(GPU_CLUSTER_TEXT_SIZE).toBeGreaterThanOrEqual(12);
		expect(GPU_ICON_PX).toBeGreaterThanOrEqual(36);
		expect(GPU_ICON_PX).toBeLessThanOrEqual(40);
		expect(FAR_BEACON_PX).toBeGreaterThan(GPU_CHIP_PX);
		expect(FAR_BEACON_RADIUS).toBe(FAR_BEACON_PX / 2);
		expect(FAR_BEACON_TEXT_SIZE).toBeGreaterThanOrEqual(14);
		expect(FARQ_MINT).toBe("#83F1B1");
		expect(PRICE_CIRCLE_FILL).toBe("#83F1B1");
		expect(PRICE_CIRCLE_TEXT).toBe(FARQ_BRAND_900);
		expect(PRICE_CIRCLE_TEXT).toBe("#043434");

		const tiles = toPriceTileCollection(
			{
				type: "FeatureCollection",
				features: [
					point("1", { gap: 18, provider: "ninja" }),
					point("2", { gap: 9, provider: "jahez" }),
					{
						type: "Feature",
						geometry: { type: "Point", coordinates: [46.6, 24.7] },
						properties: { feature_type: "cluster", count: 8 },
					},
				],
			},
			"1",
		);
		expect(tiles.features).toHaveLength(1);
		expect(tiles.features[0]?.properties).toMatchObject({
			place_id: "2",
			gap: 9,
			icon: "farq-icon-jahez",
			product_name: "",
		});
	});

	it("hashes a collection so unchanged data skips setData", () => {
		const a = toPriceTileCollection({
			type: "FeatureCollection",
			features: [point("8", { gap: 12, provider: "keeta" })],
		});
		const b = toPriceTileCollection({
			type: "FeatureCollection",
			features: [point("8", { gap: 12, provider: "keeta" })],
		});
		const c = toPriceTileCollection({
			type: "FeatureCollection",
			features: [point("8", { gap: 22, provider: "keeta" })],
		});
		expect(hashPriceTileCollection(a)).toBe(hashPriceTileCollection(b));
		expect(hashPriceTileCollection(a)).not.toBe(hashPriceTileCollection(c));
	});
});
