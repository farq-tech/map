// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import {
	encodeCameraBbox,
	mapReturnSearch,
	parseCameraBbox,
	parseCameraZoom,
	parseMapSearch,
	resolveMapSort,
	resolveMapView,
	resumeMapSessionCamera,
	writeMapReturn,
} from "./map";
import { resetSafeStorageProbeForTests } from "../lib/safeStorage";

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
			sector: undefined,
			filter: undefined,
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

	it("keeps worthwhile and 3+ apps on together", () => {
		expect(parseMapSearch({ filter: "biggest,multi" }).filter).toBe("biggest,multi");
		expect(parseMapSearch({ filter: "biggest+multi" }).filter).toBe("biggest,multi");
	});

	it("parseMapSearch carries b and z through", () => {
		const s = parseMapSearch({ b: "46.66,24.70,46.69,24.73", z: "15.2" });
		expect(s.b).toBe("46.6600,24.7000,46.6900,24.7300");
		expect(s.z).toBe(15.2);
	});

	it("restores camera and filters when returning from merchant", () => {
		sessionStorage.clear();
		writeMapReturn({
			place: "1381",
			b: "46.6600,24.7000,46.6900,24.7300",
			z: 15.2,
			filter: "biggest,multi",
			category: "burgers",
		});
		expect(mapReturnSearch("1381")).toMatchObject({
			place: "1381",
			b: "46.6600,24.7000,46.6900,24.7300",
			z: 15.2,
			filter: "biggest,multi",
			category: "burgers",
		});
	});

	it("drops another restaurant's camera instead of opening the wrong scene", () => {
		sessionStorage.clear();
		writeMapReturn({
			place: "1381",
			b: "46.6600,24.7000,46.6900,24.7300",
			z: 15.2,
			filter: "biggest,multi",
			category: "burgers",
		});
		expect(mapReturnSearch("689")).toEqual({
			neighborhood: undefined,
			category: undefined,
			city: undefined,
			q: undefined,
			place: "689",
			sector: undefined,
			filter: undefined,
			view: undefined,
			sort: undefined,
			b: undefined,
			z: undefined,
		});
	});

	it("returns only the merchant place when sessionStorage throws", () => {
		const descriptor = Object.getOwnPropertyDescriptor(window, "sessionStorage");
		Object.defineProperty(window, "sessionStorage", {
			configurable: true,
			get() {
				throw new Error("storage blocked");
			},
		});
		try {
			expect(() => writeMapReturn({ place: "1381", z: 15 })).not.toThrow();
			expect(mapReturnSearch("1381")).toMatchObject({ place: "1381" });
			expect(mapReturnSearch("1381").b).toBeUndefined();
		} finally {
			if (descriptor) Object.defineProperty(window, "sessionStorage", descriptor);
			resetSafeStorageProbeForTests();
		}
	});

	it("resumes a session camera only when the URL already frames the scene", () => {
		expect(resumeMapSessionCamera({})).toBe(true);
		expect(resumeMapSessionCamera({ place: "1381" })).toBe(false);
		expect(
			resumeMapSessionCamera({
				place: "1381",
				b: "46.6600,24.7000,46.6900,24.7300",
				z: 15.2,
			}),
		).toBe(true);
	});
});
