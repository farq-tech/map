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
	PRICE_TILE_CLUSTERS,
	PRICE_TILE_ICONS,
	PRICE_TILE_NEIGHBOR_DIM,
	PRICE_TILE_POINTS,
	cheapestProviderId,
	hashPriceTileCollection,
	nextClusterZoom,
	pinGapAmount,
	gpuIconId,
	setPriceTileNeighborDim,
	toPriceTileCollection,
	placeCountForStack,
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

	it("hides a same-coordinate stack when any member is selected", () => {
		const stacked = {
			type: "Feature" as const,
			geometry: { type: "Point" as const, coordinates: [46.6779465, 24.6852364] },
			properties: {
				feature_type: "place",
				place_id: "689",
				name: "تيمبو باستا",
				gap: 22,
				stack_count: 3,
				stack_place_ids: ["689", "451", "1288"],
			},
		};
		const open = toPriceTileCollection({
			type: "FeatureCollection",
			features: [stacked],
		});
		expect(open.features[0]?.properties).toMatchObject({
			place_id: "689",
			stack_count: 3,
		});
		const hidden = toPriceTileCollection(
			{ type: "FeatureCollection", features: [stacked] },
			"1288",
		);
		expect(hidden.features).toHaveLength(0);
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

	it("steps a cluster tap in even when expansion equals the current zoom", () => {
		expect(nextClusterZoom(11, 11)).toBe(12.2);
		expect(nextClusterZoom(12, 16)).toBeLessThanOrEqual(15);
		expect(nextClusterZoom(13, null)).toBe(14.2);
	});

	it("counts a food-court stack as N restaurants inside a cluster", () => {
		expect(placeCountForStack(27)).toBe(27);
		expect(placeCountForStack(1)).toBe(1);
		expect(placeCountForStack(0)).toBe(1);
		expect(placeCountForStack(null)).toBe(1);
		const stacked = toPriceTileCollection({
			type: "FeatureCollection",
			features: [
				{
					type: "Feature",
					geometry: { type: "Point", coordinates: [46.6779465, 24.6852364] },
					properties: {
						feature_type: "place",
						place_id: "689",
						gap: 22,
						stack_count: 3,
					},
				},
			],
		});
		expect(placeCountForStack(stacked.features[0]?.properties?.stack_count)).toBe(
			3,
		);
	});

	it("dims GPU neighbor layers when a place is selected", () => {
		const paints = new Map<string, number>();
		const map = {
			getLayer: (id: string) => ({ id }),
			setPaintProperty: (id: string, prop: string, value: number) => {
				paints.set(`${id}:${prop}`, value);
			},
		};
		setPriceTileNeighborDim(map, true);
		expect(paints.get(`${PRICE_TILE_POINTS}:icon-opacity`)).toBe(
			PRICE_TILE_NEIGHBOR_DIM,
		);
		expect(paints.get(`${PRICE_TILE_CLUSTERS}:text-opacity`)).toBe(
			PRICE_TILE_NEIGHBOR_DIM,
		);
		expect(paints.get(`${PRICE_TILE_ICONS}:icon-opacity`)).toBe(
			PRICE_TILE_NEIGHBOR_DIM,
		);
		setPriceTileNeighborDim(map, false);
		expect(paints.get(`${PRICE_TILE_POINTS}:icon-opacity`)).toBe(1);
		expect(paints.get(`${PRICE_TILE_ICONS}:text-opacity`)).toBe(1);
	});
});
