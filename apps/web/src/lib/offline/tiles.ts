/**
 * Tile math for «حفظ المنطقة دون اتصال» (save this area for offline).
 *
 * A saved area is a bounding box and a zoom range. For each tile source the
 * map actually uses (learned from the requests it made, never guessed), every
 * tile that covers the box at every zoom in range is fetched once and kept on
 * the phone. Web-Mercator XYZ, the scheme every Mapbox tileset here uses.
 */

export type Bbox = [west: number, south: number, east: number, north: number];

/**
 * At most this many tiles on one phone, across every saved area. Mapbox's own
 * mobile SDKs default to the same 6,000-tile ceiling per user for offline
 * maps; the web SDK has no offline mode of its own, so we keep to it.
 */
export const MAX_OFFLINE_TILES = 6000;

const MAX_LAT = 85.0511287798066;

export function lngLatToTile(lng: number, lat: number, z: number): { x: number; y: number } {
	const n = 2 ** z;
	const la = Math.max(-MAX_LAT, Math.min(MAX_LAT, lat));
	const x = Math.floor(((lng + 180) / 360) * n);
	const r = (la * Math.PI) / 180;
	const y = Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * n);
	/* East edge at exactly 180° and the poles land one past the last tile. */
	return { x: Math.max(0, Math.min(n - 1, x)), y: Math.max(0, Math.min(n - 1, y)) };
}

export type TileRange = { z: number; xMin: number; xMax: number; yMin: number; yMax: number };

export function tileRange(bbox: Bbox, z: number): TileRange {
	const [w, s, e, n] = bbox;
	const a = lngLatToTile(w, n, z);
	const b = lngLatToTile(e, s, z);
	return { z, xMin: a.x, xMax: b.x, yMin: a.y, yMax: b.y };
}

export function rangeSize(r: TileRange): number {
	return (r.xMax - r.xMin + 1) * (r.yMax - r.yMin + 1);
}

/** How many tiles cover the box from zMin to zMax (inclusive), for one source. */
export function countTiles(bbox: Bbox, zMin: number, zMax: number): number {
	let total = 0;
	for (let z = zMin; z <= zMax; z += 1) total += rangeSize(tileRange(bbox, z));
	return total;
}

export function* tilesIn(bbox: Bbox, zMin: number, zMax: number): Generator<{ z: number; x: number; y: number }> {
	for (let z = zMin; z <= zMax; z += 1) {
		const r = tileRange(bbox, z);
		for (let x = r.xMin; x <= r.xMax; x += 1) for (let y = r.yMin; y <= r.yMax; y += 1) yield { z, x, y };
	}
}

/** A tile source: URL template with {z}/{x}/{y}, and the zooms it actually has. */
export type TileSource = { template: string; minzoom: number; maxzoom: number };

/**
 * The template behind a tile URL the map requested, e.g.
 * …/v4/mapbox.satellite/12/2566/1752.webp?sku=… → …/v4/mapbox.satellite/{z}/{x}/{y}.webp
 * (token and per-session sku dropped). Null for anything that is not a tile.
 */
export function templateFromTileUrl(url: string): string | null {
	let u: URL;
	try {
		u = new URL(url);
	} catch {
		return null;
	}
	const m = u.pathname.match(/^(.*)\/(\d{1,2})\/(\d+)\/(\d+)((?:@2x)?\.(?:vector\.pbf|pbf|mvt|webp|png|jpg|jpeg|pngraw))$/);
	if (!m) return null;
	u.pathname = `${m[1]}/{z}/{x}/{y}${m[5]}`;
	return decodeURI(stripVolatile(u).toString());
}

/** Fill a template; {z}/{x}/{y} survive URL encoding as %7Bz%7D, so both are handled. */
export function fillTemplate(template: string, z: number, x: number, y: number): string {
	return template
		.replace(/\{z\}|%7Bz%7D/gi, String(z))
		.replace(/\{x\}|%7Bx%7D/gi, String(x))
		.replace(/\{y\}|%7By%7D/gi, String(y));
}

function stripVolatile(u: URL): URL {
	/* The token is the same public key every time; sku changes every map load. */
	u.searchParams.delete("access_token");
	u.searchParams.delete("sku");
	u.searchParams.sort();
	return u;
}

/**
 * The key a response is kept under: the URL without token or sku, params
 * sorted, so the map's own request (new sku each load) finds what was saved.
 * Must stay in step with keyFor() in public/sw.js (a test checks they agree).
 */
export function cacheKey(url: string): string {
	try {
		return stripVolatile(new URL(url)).toString();
	} catch {
		return url;
	}
}

/**
 * Typical stored size per tile, for the estimate only (the real total is
 * shown as it downloads). Measured on Rawdat Khuraim and central Riyadh,
 * z5–z14: terrain DEM ~70 KB, satellite 10–30 KB (desert–city), streets 5–20 KB.
 */
export function typicalTileBytes(template: string): number {
	if (/terrain-dem|raster\/v1/.test(template)) return 70_000;
	if (/\.(webp|jpg|jpeg|png)/.test(template)) return 20_000;
	return 12_000;
}

export type DownloadPlan = {
	/** Tile URLs to fetch (templates filled, no token). */
	urls: string[];
	tiles: number;
	estimateBytes: number;
};

/** Every tile for every source over the box and zooms, each source clamped to the zooms it has. */
export function planTiles(sources: TileSource[], bbox: Bbox, zMin: number, zMax: number): DownloadPlan {
	const urls: string[] = [];
	let estimateBytes = 0;
	const seen = new Set<string>();
	for (const s of sources) {
		const key = cacheKey(s.template);
		if (seen.has(key)) continue;
		seen.add(key);
		/* Past its maxzoom the map overzooms the last level: nothing more to fetch. */
		const lo = Math.max(zMin, s.minzoom);
		const hi = Math.min(zMax, s.maxzoom);
		if (lo > hi) continue;
		const per = typicalTileBytes(s.template);
		for (const t of tilesIn(bbox, lo, hi)) {
			urls.push(fillTemplate(s.template, t.z, t.x, t.y));
			estimateBytes += per;
		}
	}
	return { urls, tiles: urls.length, estimateBytes };
}

/** Just the count and estimate, without building the list (for the live estimate as the camera moves). */
export function estimatePlan(sources: TileSource[], bbox: Bbox, zMin: number, zMax: number): { tiles: number; estimateBytes: number } {
	let tiles = 0;
	let estimateBytes = 0;
	const seen = new Set<string>();
	for (const s of sources) {
		const key = cacheKey(s.template);
		if (seen.has(key)) continue;
		seen.add(key);
		const lo = Math.max(zMin, s.minzoom);
		const hi = Math.min(zMax, s.maxzoom);
		if (lo > hi) continue;
		const n = countTiles(bbox, lo, hi);
		tiles += n;
		estimateBytes += n * typicalTileBytes(s.template);
	}
	return { tiles, estimateBytes };
}
