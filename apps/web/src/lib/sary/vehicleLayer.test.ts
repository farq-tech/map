import { describe, expect, it, vi } from "vitest";
import { canDrawModels, ensureVehicleLayer, modelIdFor, vehicleFeature, vehicleRotation, VEHICLE_LAYER } from "./vehicleLayer";

vi.mock("./suvModel", () => ({ suvModelUrl: (hex: string) => `blob:test/${hex}` }));

describe("3D vehicle layer", () => {
	it("turns a compass heading into a model rotation, keeping parked cars as they were", () => {
		expect(vehicleRotation(0)).toEqual([0, 0, 180]);
		expect(vehicleRotation(90)).toEqual([0, 0, 270]);
		expect(vehicleRotation(270)).toEqual([0, 0, 90]);
		expect(vehicleRotation(null)).toEqual([0, 0, 180]);
	});

	it("draws nothing without a real position", () => {
		expect(vehicleFeature(null).features).toHaveLength(0);
		expect(vehicleFeature({ lng: 46.6, lat: 24.7 }).features[0].geometry).toEqual({ type: "Point", coordinates: [46.6, 24.7] });
	});

	it("one model per body colour", () => {
		expect(modelIdFor("#B3202B")).toBe("sary-suv-b3202b");
	});

	it("falls back when the map cannot draw models", () => {
		const map = { getSource: () => undefined, getLayer: () => undefined } as never;
		expect(canDrawModels(map)).toBe(false);
		expect(ensureVehicleLayer(map, "#ffffff")).toBe(false);
	});

	it("adds the model, source and layer once", () => {
		const added: string[] = [];
		const layers = new Set<string>();
		const sources = new Set<string>();
		const models = new Set<string>();
		const map = {
			addModel: (id: string) => { models.add(id); added.push(`model:${id}`); },
			hasModel: (id: string) => models.has(id),
			getSource: (id: string) => (sources.has(id) ? {} : undefined),
			addSource: (id: string) => { sources.add(id); added.push(`source:${id}`); },
			getLayer: (id: string) => (layers.has(id) ? {} : undefined),
			addLayer: (l: { id: string; type: string }) => { layers.add(l.id); added.push(`layer:${l.type}`); },
			setLayoutProperty: vi.fn(),
		} as never;
		expect(ensureVehicleLayer(map, "#e8eef0")).toBe(true);
		expect(ensureVehicleLayer(map, "#e8eef0")).toBe(true);
		expect(added).toEqual(["model:sary-suv-e8eef0", "source:sary-vehicle", "layer:model"]);
		expect(layers.has(VEHICLE_LAYER)).toBe(true);
	});
});
