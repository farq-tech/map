// @vitest-environment node
import { describe, expect, it } from "vitest";
import spec from "mapbox-gl/dist/style-spec/index.cjs";
import { buildFarqBasemapStyle, farqLabelField, FARQ_BASEMAP_COLORS as C } from "./farqBasemap";

const style = buildFarqBasemapStyle("ar");
const byId = new Map(style.layers.map((l) => [l.id, l as Record<string, any>]));
const layer = (id: string) => {
	const found = byId.get(id);
	if (!found) throw new Error(`missing layer ${id}`);
	return found;
};
const order = (id: string) => style.layers.findIndex((l) => l.id === id);

function paintAt(id: string, prop: string, zoom: number, type = "LineString", state: Record<string, unknown> = {}): number {
	const target = layer(id);
	const expression = spec.expression.createPropertyExpression(target.paint[prop], spec.latest[`paint_${target.type}`][prop]);
	return expression.value.evaluate({ zoom }, { properties: {}, type }, state);
}

function textSizeAt(id: string, zoom: number): number {
	const expression = spec.expression.createPropertyExpression(layer(id).layout["text-size"], spec.latest.layout_symbol["text-size"]);
	return expression.value.evaluate({ zoom }, { properties: {}, type: "Point" });
}

/** Relative luminance — the only honest way to assert "darker than". */
const lum = (hex: string) => {
	const n = Number.parseInt(hex.slice(1), 16);
	return (0.2126 * ((n >> 16) & 255) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255)) / 255;
};
const visibleAt = (zoom: number) => style.layers.filter((l) => (l.minzoom ?? 0) <= zoom && (l.maxzoom ?? 24) > zoom).map((l) => l.id);

describe("Farq Dusk style", () => {
	it("is a valid Mapbox style in both locales", () => {
		expect(spec.validate(buildFarqBasemapStyle("ar"))).toEqual([]);
		expect(spec.validate(buildFarqBasemapStyle("en"))).toEqual([]);
	});

	it("gives every layer its own id", () => {
		expect(new Set(style.layers.map((l) => l.id)).size).toBe(style.layers.length);
	});
});

describe("lighting rig", () => {
	// Blue hour: a cool sky over a warm low sun. Reverse them and it reads as noon.
	it("puts a cool ambient over a warm key light", () => {
		const ambient = style.lights?.find((l) => l.type === "ambient");
		const directional = style.lights?.find((l) => l.type === "directional");
		expect(ambient && directional).toBeTruthy();
		expect(lum(ambient!.properties!.color as string)).toBeLessThan(lum(directional!.properties!.color as string));
		expect((directional!.properties!.direction as number[])[1]).toBeLessThan(60);
	});

	it("casts no shadows, so mobile keeps its frames", () => {
		expect(style.lights?.find((l) => l.type === "directional")?.properties?.["cast-shadows"]).toBe(false);
		expect(layer("farq-building-3d").paint["fill-extrusion-cast-shadows"]).toBe(false);
	});

	// The palette is the design; only buildings may react to the sun.
	it("opts every flat layer out of the light rig", () => {
		const lit = style.layers
			.filter((l) => l.type !== "fill-extrusion")
			.filter((l) => {
				const key = Object.keys(l.paint ?? {}).find((k) => k.endsWith("emissive-strength"));
				return !key || (l.paint as Record<string, unknown>)[key] !== 1;
			});
		expect(lit.map((l) => l.id)).toEqual([]);
	});
});

describe("buildings", () => {
	it("reads as an architectural model, not extruded blocks", () => {
		const paint = layer("farq-building-3d").paint;
		expect(paint["fill-extrusion-vertical-gradient"]).toBe(true);
		expect(paint["fill-extrusion-ambient-occlusion-intensity"]).toBeGreaterThan(0.3);
		expect(paint["fill-extrusion-cutoff-fade-range"]).toBeGreaterThan(0);
		expect(style.layers.some((l) => l.id.includes("building") && l.type === "line")).toBe(false);
	});

	it("stays matte", () => {
		expect(paintAt("farq-building-3d", "fill-extrusion-emissive-strength", 17, "Polygon")).toBeLessThanOrEqual(0.1);
	});

	it("gives taller stock more presence", () => {
		expect(lum(C.buildingLow)).toBeLessThan(lum(C.buildingMid));
		expect(lum(C.buildingMid)).toBeLessThan(lum(C.buildingTall));
	});
});

describe("selected opportunity", () => {
	const focused = { farqFocus: true };

	it("lights the building from within instead of painting it green", () => {
		expect(paintAt("farq-building-3d", "fill-extrusion-emissive-strength", 17, "Polygon", focused)).toBeGreaterThan(
			paintAt("farq-building-3d", "fill-extrusion-emissive-strength", 17, "Polygon") * 5,
		);
		expect(lum(C.accentBuilding)).toBeLessThan(0.35);
		expect(lum(C.accentBuilding)).toBeLessThan(lum(C.accent));
	});

	it("spills flood light only from the selection", () => {
		expect(paintAt("farq-building-3d", "fill-extrusion-flood-light-ground-radius", 17, "Polygon", focused)).toBeGreaterThan(0);
		expect(paintAt("farq-building-3d", "fill-extrusion-flood-light-ground-radius", 17, "Polygon")).toBe(0);
		expect(layer("farq-building-3d").paint["fill-extrusion-flood-light-color"]).toBe(C.accent);
	});

	// Mint is a signal, not map paint.
	it("keeps mint on the focus layers only", () => {
		const minted = style.layers.filter((l) => JSON.stringify(l.paint ?? {}).toLowerCase().includes(C.accent.toLowerCase())).map((l) => l.id);
		expect(minted.sort()).toEqual(["farq-building-3d", "farq-focus-glow", "farq-focus-road-accent"]);
	});

	it("walks the eye road → building → glow", () => {
		expect(order("farq-focus-road-accent")).toBeGreaterThan(order("farq-building-3d"));
		expect(order("farq-focus-glow")).toBeGreaterThan(order("farq-focus-road-accent"));
	});
});

describe("road system", () => {
	// A tie anywhere in the ladder flattens the city.
	it.each([10, 12, 14, 16, 18])("keeps the hierarchy strict at z%s", (zoom) => {
		const ladder = ["farq-road-motorway", "farq-road-trunk", "farq-road-primary", "farq-road-secondary", "farq-road-street", "farq-road-service", "farq-road-path"]
			.filter((id) => (layer(id).minzoom ?? 0) <= zoom)
			.map((id) => paintAt(id, "line-width", zoom));
		expect(ladder).toEqual([...ladder].sort((a, b) => b - a));
		expect(new Set(ladder).size).toBe(ladder.length);
	});

	it("weights casings by rank and spares the locals", () => {
		const casing = (id: string) => paintAt(id, "line-border-width", 16);
		expect(casing("farq-road-motorway")).toBeGreaterThan(casing("farq-road-trunk"));
		expect(casing("farq-road-trunk")).toBeGreaterThan(casing("farq-road-primary"));
		expect(layer("farq-road-secondary").paint["line-border-width"]).toBeUndefined();
		expect(layer("farq-road-street").paint["line-border-width"]).toBeUndefined();
		expect(paintAt("farq-road-motorway", "line-border-width", 9)).toBe(0);
	});

	it("brightens roads by rank", () => {
		expect(lum(C.motorway)).toBeGreaterThan(lum(C.primary));
		expect(lum(C.primary)).toBeGreaterThan(lum(C.street));
	});
});

describe("bridges and tunnels", () => {
	it("flies bridges over the buildings, shadow first", () => {
		expect(order("farq-bridge-major")).toBeGreaterThan(order("farq-building-3d"));
		expect(order("farq-bridge-shadow")).toBeLessThan(order("farq-bridge-minor"));
		expect(paintAt("farq-bridge-shadow", "line-width", 16)).toBeGreaterThan(paintAt("farq-bridge-major", "line-width", 16));
		expect(paintAt("farq-bridge-shadow", "line-blur", 16)).toBeGreaterThan(0);
	});

	it("keeps ground roads clear of bridges and tunnels", () => {
		for (const id of ["farq-road-motorway", "farq-road-street"]) expect(JSON.stringify(layer(id).filter)).toContain('"bridge","tunnel"');
	});

	it("recesses tunnels without losing them", () => {
		expect(lum(C.tunnel)).toBeLessThan(lum(C.street));
		expect(layer("farq-road-tunnel").paint["line-dasharray"]).toBeTruthy();
		expect(paintAt("farq-road-tunnel", "line-opacity", 16)).toBeGreaterThan(0.5);
	});
});

describe("shields and labels", () => {
	it("fills the Farq shield from the source ref", () => {
		const shield = layer("farq-label-road-shield");
		expect(JSON.stringify(shield.layout["text-field"])).toBe('["get","ref"]');
		expect(shield.layout["icon-image"]).toBe("farq-road-shield");
		expect(shield.layout["icon-text-fit"]).toBe("both");
		expect(JSON.stringify(shield.filter)).toContain("reflen");
		expect(shield.layout["icon-rotation-alignment"]).toBe("viewport");
		expect(textSizeAt("farq-label-road-shield", 16)).toBeLessThanOrEqual(textSizeAt("farq-label-road-major", 16));
	});

	it("weights labels by importance", () => {
		expect(textSizeAt("farq-label-neighborhood", 13)).toBeGreaterThan(textSizeAt("farq-label-road-major", 13));
		expect(textSizeAt("farq-label-road-major", 16)).toBeGreaterThan(textSizeAt("farq-label-road-minor", 16));
		expect(layer("farq-label-settlement-major").layout["text-font"][0]).toContain("Bold");
		expect(layer("farq-label-neighborhood").layout["text-font"][0]).toContain("Medium");
	});

	// The map has to know when to stay quiet.
	it("opens POI density one rank at a time", () => {
		expect(JSON.stringify(layer("farq-label-poi").filter)).toContain('"step"');
	});

	// Labels read source fields — nothing is translated or invented here.
	it("prefers the locale's own name field", () => {
		expect(JSON.stringify(farqLabelField("ar"))).toBe(JSON.stringify(["coalesce", ["get", "name_ar"], ["get", "name_en"], ["get", "name"]]));
		expect(JSON.stringify(farqLabelField("en"))).not.toContain("name_ar");
		expect(layer("farq-label-neighborhood").layout["text-field"][0]).toBe("coalesce");
	});
});

describe("zoom story", () => {
	it("tells a different story per band", () => {
		const city = visibleAt(10);
		const neighbourhood = visibleAt(14);
		const close = visibleAt(17.5);
		expect(city.some((id) => id.startsWith("farq-building"))).toBe(false);
		expect(city).not.toContain("farq-road-street");
		expect(neighbourhood).toContain("farq-label-neighborhood");
		expect(neighbourhood).not.toContain("farq-label-poi");
		expect(neighbourhood).not.toContain("farq-label-settlement-major");
		expect(close).toEqual(expect.arrayContaining(["farq-building-3d", "farq-road-street", "farq-label-poi"]));
	});

	it("gets richer with zoom, never busier", () => {
		const counts = [10, 12, 14, 16, 17.5].map((z) => visibleAt(z).length);
		expect(counts).toEqual([...counts].sort((a, b) => a - b));
	});

	it("stays cheaper than the style it replaced", () => {
		expect(style.layers.length).toBeLessThanOrEqual(48);
		expect(Object.values(style.sources).filter((s) => (s as { type: string }).type === "vector")).toHaveLength(1);
	});
});
