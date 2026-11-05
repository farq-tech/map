import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { asRequestedByMap } from "./offlineAreas";
import {
	cacheKey,
	countTiles,
	estimatePlan,
	fillTemplate,
	lngLatToTile,
	MAX_OFFLINE_TILES,
	planTiles,
	templateFromTileUrl,
	tileRange,
	tilesIn,
	type Bbox,
} from "./tiles";

/* The real public/sw.js, evaluated as the classic script it is (no service-worker globals here). */
const sw = (() => {
	const mod = { exports: {} };
	new Function("module", "self", "caches", readFileSync(resolve(__dirname, "../../../public/sw.js"), "utf8"))(mod, undefined, undefined);
	return mod.exports;
})() as {
	keyFor: (u: string) => string;
	routeFor: (method: string, url: string, mode: string, origin: string) => string;
};

/* Rawdat Khuraim, roughly 11 × 9 km. */
const khuraim: Bbox = [47.25, 25.33, 47.36, 25.41];

describe("tile coordinates", () => {
	it("matches the known XYZ tile for Riyadh", () => {
		const t = lngLatToTile(46.6753, 24.7136, 10);
		expect(t).toEqual({ x: 644, y: 439 });
		/* Independent check: the tile's own corners (inverse formula) contain the point. */
		const lon = (x: number) => (x / 1024) * 360 - 180;
		const lat = (y: number) => (Math.atan(Math.sinh(Math.PI * (1 - (2 * y) / 1024))) * 180) / Math.PI;
		expect(lon(t.x)).toBeLessThanOrEqual(46.6753);
		expect(lon(t.x + 1)).toBeGreaterThan(46.6753);
		expect(lat(t.y)).toBeGreaterThanOrEqual(24.7136);
		expect(lat(t.y + 1)).toBeLessThan(24.7136);
		expect(lngLatToTile(0, 0, 1)).toEqual({ x: 1, y: 1 });
		expect(lngLatToTile(-180, 85.06, 3)).toEqual({ x: 0, y: 0 });
		expect(lngLatToTile(180, -85.06, 3)).toEqual({ x: 7, y: 7 });
	});

	it("covers the box with north at the top (smaller y)", () => {
		const r = tileRange(khuraim, 12);
		expect(r.xMin).toBeLessThanOrEqual(r.xMax);
		expect(r.yMin).toBeLessThanOrEqual(r.yMax);
	});

	it("counts the same tiles it lists", () => {
		const listed = [...tilesIn(khuraim, 8, 14)].length;
		expect(countTiles(khuraim, 8, 14)).toBe(listed);
	});

	it("roughly quadruples per zoom level once the box spans several tiles", () => {
		const a = countTiles(khuraim, 15, 15);
		const b = countTiles(khuraim, 16, 16);
		expect(b / a).toBeGreaterThan(3);
		expect(b / a).toBeLessThan(5);
	});

	it("a single zoom-0 tile for the world", () => {
		expect(countTiles([-180, -85, 180, 85], 0, 0)).toBe(1);
		expect(countTiles([-180, -85, 180, 85], 0, 2)).toBe(1 + 4 + 16);
	});
});

describe("planning an area", () => {
	const vector = { template: "https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/{z}/{x}/{y}.vector.pbf", minzoom: 0, maxzoom: 16 };
	const dem = { template: "https://api.mapbox.com/raster/v1/mapbox.mapbox-terrain-dem-v1/{z}/{x}/{y}.webp", minzoom: 0, maxzoom: 14 };

	it("does not fetch past a source's maxzoom (the map overzooms it)", () => {
		const p = planTiles([dem], khuraim, 10, 16);
		expect(p.tiles).toBe(countTiles(khuraim, 10, 14));
	});

	it("adds sources together and the estimate agrees with the plan", () => {
		const p = planTiles([vector, dem], khuraim, 8, 15);
		const e = estimatePlan([vector, dem], khuraim, 8, 15);
		expect(p.tiles).toBe(countTiles(khuraim, 8, 15) + countTiles(khuraim, 8, 14));
		expect(e.tiles).toBe(p.tiles);
		expect(e.estimateBytes).toBe(p.estimateBytes);
		expect(p.urls[0]).toMatch(/\/8\/\d+\/\d+\.vector\.pbf$/);
	});

	it("does not count one source twice", () => {
		expect(planTiles([vector, { ...vector }], khuraim, 10, 12).tiles).toBe(countTiles(khuraim, 10, 12));
	});

	it("a trip-sized area at street detail fits under the cap", () => {
		expect(estimatePlan([vector, dem], khuraim, 6, 15).tiles).toBeLessThan(MAX_OFFLINE_TILES);
	});
});

describe("tile URLs and cache keys", () => {
	const seen = "https://api.mapbox.com/v4/mapbox.satellite/12/2566/1752.webp?sku=101OGyDTGqQip&access_token=pk.x";

	it("learns a template from a tile the map requested, without token or sku", () => {
		expect(templateFromTileUrl(seen)).toBe("https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}.webp");
		expect(templateFromTileUrl("https://api.mapbox.com/fonts/v1/mapbox/DIN%20Pro%20Medium/0-255.pbf?access_token=x")).toBeNull();
		expect(templateFromTileUrl("https://api.mapbox.com/styles/v1/mapbox/standard-satellite?sdk=js-3.28.1")).toBeNull();
	});

	it("a saved tile is found again on the next visit, whatever its sku", () => {
		const saved = cacheKey(fillTemplate(templateFromTileUrl(seen)!, 12, 2566, 1752));
		const nextVisit = "https://api.mapbox.com/v4/mapbox.satellite/12/2566/1752.webp?access_token=pk.x&sku=999";
		expect(sw.keyFor(nextVisit)).toBe(saved);
	});

	it("rewrites TileJSON templates the way the map requests them", () => {
		const tj = "https://a.tiles.mapbox.com/raster/v1/mapbox.mapbox-terrain-dem-v1/{z}/{x}/{y}.png?access_token=pk.x";
		const t = asRequestedByMap(tj);
		expect(t.startsWith("https://api.mapbox.com/raster/v1/")).toBe(true);
		const requested = "https://api.mapbox.com/raster/v1/mapbox.mapbox-terrain-dem-v1/9/322/219.webp?sku=abc&access_token=pk.x";
		expect(cacheKey(fillTemplate(t, 9, 322, 219))).toBe(sw.keyFor(requested));
		const vec = asRequestedByMap("https://b.tiles.mapbox.com/v4/mapbox.mapbox-streets-v8/{z}/{x}/{y}.vector.pbf?access_token=pk.x&language=ar");
		expect(cacheKey(fillTemplate(vec, 14, 1, 2))).toBe(
			sw.keyFor("https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/14/1/2.vector.pbf?language=ar&sku=s&access_token=pk.x"),
		);
	});

	it("the page and the service worker agree on keys", () => {
		for (const u of [seen, "https://api.mapbox.com/fonts/v1/mapbox/DIN%20Pro%20Medium/1536-1791.pbf?access_token=pk.x", "https://x.test/a?b=2&a=1"]) {
			expect(sw.keyFor(u)).toBe(cacheKey(u));
		}
	});
});

describe("what the service worker touches", () => {
	const o = "https://sary.example";
	it("never /api or /_api, nor anything that is not a GET", () => {
		expect(sw.routeFor("GET", `${o}/api/outings/live`, "cors", o)).toBe("skip");
		expect(sw.routeFor("GET", `${o}/_api/health`, "cors", o)).toBe("skip");
		expect(sw.routeFor("GET", `${o}/api`, "navigate", o)).toBe("skip");
		expect(sw.routeFor("POST", "https://api.mapbox.com/v4/x/1/1/1.vector.pbf", "cors", o)).toBe("skip");
		expect(sw.routeFor("GET", "https://api.mapbox.com/map-sessions/v1?sku=1", "cors", o)).toBe("skip");
		expect(sw.routeFor("GET", "https://events.mapbox.com/events/v2", "cors", o)).toBe("skip");
		expect(sw.routeFor("GET", "https://api-production.example/api/x", "cors", o)).toBe("skip");
	});
	it("serves pages, hashed assets and Mapbox from the saved copy when it must", () => {
		expect(sw.routeFor("GET", `${o}/map?layer=trips`, "navigate", o)).toBe("page");
		expect(sw.routeFor("GET", `${o}/assets/index-abc.js`, "cors", o)).toBe("asset");
		expect(sw.routeFor("GET", "https://api.mapbox.com/v4/mapbox.satellite/1/1/1.webp", "cors", o)).toBe("mapbox");
	});
});
