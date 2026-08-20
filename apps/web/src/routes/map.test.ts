import { describe, expect, it } from "vitest";
import {
	encodeCameraBbox,
	parseCameraBbox,
	parseCameraZoom,
	parseMapSearch,
	resolveMapSort,
	resolveMapView,
} from "./map";

describe("map search — shared list/map world", () => {
	it("parses view and sort without dropping place/q", () => {
		const search = parseMapSearch({
			city: "Riyadh",
			q: "برجر",
			place: "123",
			view: "list",
			sort: "cheap",
		});
		expect(search).toEqual({
			neighborhood: undefined,
			category: undefined,
			city: "Riyadh",
			q: "برجر",
			place: "123",
			view: "list",
			sort: "cheap",
		});
	});

	it("defaults /map to map and / to list; sort defaults to gap", () => {
		expect(resolveMapView({}, "/map")).toBe("map");
		expect(resolveMapView({}, "/")).toBe("list");
		expect(resolveMapView({ view: "list" }, "/map")).toBe("list");
		expect(resolveMapSort({})).toBe("gap");
		expect(resolveMapSort({ sort: "near" })).toBe("near");
	});
});


describe("camera in the URL", () => {
	it("parses a sane bbox and rejects nonsense", () => {
		expect(parseCameraBbox("46.66,24.70,46.69,24.73")).toEqual([46.66, 24.7, 46.69, 24.73]);
		expect(parseCameraBbox("46.69,24.70,46.66,24.73")).toBeUndefined();
		expect(parseCameraBbox("a,b,c,d")).toBeUndefined();
		expect(parseCameraBbox("1,2,3")).toBeUndefined();
		expect(parseCameraBbox("-200,0,1,1")).toBeUndefined();
	});

	it("clamps zoom to the map's range and rounds it", () => {
		expect(parseCameraZoom("15.237")).toBe(15.24);
		expect(parseCameraZoom(1)).toBeUndefined();
		expect(parseCameraZoom("x")).toBeUndefined();
	});

	it("encodes with four decimals so replaceState stays stable", () => {
		expect(encodeCameraBbox([46.660001, 24.7, 46.69, 24.730049])).toBe("46.6600,24.7000,46.6900,24.7300");
	});

	it("parseMapSearch carries b and z through", () => {
		const s = parseMapSearch({ b: "46.66,24.70,46.69,24.73", z: "15.2" });
		expect(s.b).toBe("46.6600,24.7000,46.6900,24.7300");
		expect(s.z).toBe(15.2);
	});
});
