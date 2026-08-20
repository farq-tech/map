import { describe, expect, it } from "vitest";
import {
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
