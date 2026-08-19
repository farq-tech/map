// @vitest-environment node
import { describe, expect, it } from "vitest";
import spec from "mapbox-gl/dist/style-spec/index.cjs";
import { buildFarqBasemapStyle, farqLabelField, FARQ_BASEMAP_COLORS } from "./farqBasemap";

const style = buildFarqBasemapStyle("ar");
const byId = new Map(style.layers.map((layer) => [layer.id, layer as Record<string, any>]));
const layer = (id: string) => {
	const found = byId.get(id);
	if (!found) throw new Error(`missing layer ${id}`);
	return found;
};

function paintAt(id: string, prop: string, zoom: number): number {
	const target = layer(id);
	const expression = spec.expression.createPropertyExpression(target.paint[prop], spec.latest[`paint_${target.type}`][prop]);
	return expression.value.evaluate({ zoom }, { properties: {}, type: "LineString" });
}

function textSizeAt(id: string, zoom: number): number {
	const expression = spec.expression.createPropertyExpression(layer(id).layout["text-size"], spec.latest.layout_symbol["text-size"]);
	return expression.value.evaluate({ zoom }, { properties: {}, type: "Point" });
}

const visibleAt = (zoom: number) => style.layers.filter((l) => (l.minzoom ?? 0) <= zoom && (l.maxzoom ?? 24) > zoom).map((l) => l.id);

describe("Farq basemap style", () => {
	it("is a valid Mapbox style in both locales", () => {
		expect(spec.validate(buildFarqBasemapStyle("ar"))).toEqual([]);
		expect(spec.validate(buildFarqBasemapStyle("en"))).toEqual([]);
	});

	it("gives every layer its own id", () => {
		expect(new Set(style.layers.map((l) => l.id)).size).toBe(style.layers.length);
	});

	// Road hierarchy is the branding — a tie anywhere flattens the city.
	it.each([10, 12, 14, 16, 18])("keeps the road hierarchy strict at z%s", (zoom) => {
		const ladder = ["farq-road-motorway", "farq-road-trunk", "farq-road-primary", "farq-road-secondary", "farq-road-street", "farq-road-service", "farq-road-path"]
			.filter((id) => (layer(id).minzoom ?? 0) <= zoom)
			.map((id) => paintAt(id, "line-width", zoom));
		expect(ladder).toEqual([...ladder].sort((a, b) => b - a));
		expect(new Set(ladder).size).toBe(ladder.length);
	});

	it("frames highways with a casing that is wider and underneath", () => {
		for (const zoom of [12, 14, 16, 18]) expect(paintAt("farq-road-trunk-casing", "line-width", zoom)).toBeGreaterThan(paintAt("farq-road-motorway", "line-width", zoom));
		expect(style.layers.findIndex((l) => l.id === "farq-road-trunk-casing")).toBeLessThan(style.layers.findIndex((l) => l.id === "farq-road-motorway"));
	});

	// Mint is a signal, not map paint.
	it("keeps Farq mint on the focus layers only", () => {
		const minted = style.layers.filter((l) => JSON.stringify(l.paint ?? {}).toLowerCase().includes(FARQ_BASEMAP_COLORS.accent.toLowerCase())).map((l) => l.id);
		expect(minted.sort()).toEqual(["farq-building-3d", "farq-focus-glow", "farq-focus-road-accent"]);
		expect(JSON.stringify(layer("farq-building-3d").paint["fill-extrusion-color"])).toContain("feature-state");
	});

	it("weights labels by importance", () => {
		expect(textSizeAt("farq-label-neighborhood", 13)).toBeGreaterThan(textSizeAt("farq-label-road-major", 13));
		expect(textSizeAt("farq-label-road-major", 16)).toBeGreaterThan(textSizeAt("farq-label-road-minor", 16));
		expect(layer("farq-label-settlement-major").layout["text-font"][0]).toContain("Bold");
		expect(layer("farq-label-neighborhood").layout["text-font"][0]).toContain("Medium");
	});

	// Richer with zoom, not busier.
	it("stages detail across the zoom bands", () => {
		const city = visibleAt(10.5);
		const mid = visibleAt(13);
		const close = visibleAt(16.5);
		expect(city.some((id) => id.startsWith("farq-building"))).toBe(false);
		expect(city).not.toContain("farq-road-street");
		expect(mid).not.toContain("farq-label-poi");
		expect(mid).toContain("farq-label-neighborhood");
		expect(close).toEqual(expect.arrayContaining(["farq-building-3d", "farq-road-street", "farq-label-poi"]));
		expect(close).not.toContain("farq-label-settlement-major");
		expect(city.length).toBeLessThan(mid.length);
		expect(mid.length).toBeLessThan(close.length);
	});

	// Labels read source fields — nothing is translated or invented here.
	it("prefers the locale's own name field", () => {
		expect(JSON.stringify(farqLabelField("ar"))).toBe(JSON.stringify(["coalesce", ["get", "name_ar"], ["get", "name_en"], ["get", "name"]]));
		expect(JSON.stringify(farqLabelField("en"))).not.toContain("name_ar");
		expect(layer("farq-label-neighborhood").layout["text-field"][0]).toBe("coalesce");
	});

	it("lights buildings instead of outlining them", () => {
		expect(layer("farq-building-3d").paint["fill-extrusion-vertical-gradient"]).toBe(true);
		expect(style.layers.some((l) => l.id.includes("building") && l.type === "line")).toBe(false);
		expect(style.light?.anchor).toBe("viewport");
	});

	it("stays cheaper than the style it replaced", () => {
		expect(style.layers.length).toBeLessThanOrEqual(45);
		expect(Object.values(style.sources).filter((s) => (s as { type: string }).type === "vector")).toHaveLength(1);
	});
});
