/**
 * «حفظ المنطقة دون اتصال» — keep an area on the phone before a trip.
 *
 * The page does the saving (so it can show progress and be cancelled); the
 * service worker in public/sw.js only reads the saved copy back when the
 * network is gone. Nothing is saved without the user asking, the service
 * worker exists only while at least one area is saved, and /api is never
 * saved or served from a copy.
 *
 * What is saved for an area:
 *   - the app shell (this page and the scripts/styles it loaded),
 *   - the map style, sprites/icons, glyph ranges and TileJSON the map loaded,
 *   - every tile of every tile source the map is using, over the area's
 *     box, from zMin to zMax (each source clamped to the zooms it has).
 */

import {
	cacheKey,
	estimatePlan,
	MAX_OFFLINE_TILES,
	planTiles,
	templateFromTileUrl,
	type Bbox,
	type TileSource,
} from "./tiles";

export const OFFLINE_CACHE = "sary-offline-v1";
const META_PREFIX = "/__sary-offline/";
const CONCURRENCY = 6;

export type OfflineArea = {
	id: string;
	name: string;
	bbox: Bbox;
	zMin: number;
	zMax: number;
	tiles: number;
	bytes: number;
	failed: number;
	savedAt: number;
	basemap: string;
};

export type SaveProgress = { done: number; total: number; bytes: number; failed: number };

export function offlineSupported(): boolean {
	return typeof window !== "undefined" && "serviceWorker" in navigator && "caches" in window && window.isSecureContext;
}

const metaUrl = (path: string) => `${location.origin}${META_PREFIX}${path}`;

async function readJson<T>(cache: Cache, path: string): Promise<T | null> {
	const hit = await cache.match(metaUrl(path));
	if (!hit) return null;
	try {
		return (await hit.json()) as T;
	} catch {
		return null;
	}
}

function writeJson(cache: Cache, path: string, value: unknown): Promise<void> {
	return cache.put(metaUrl(path), new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } }));
}

export async function listAreas(): Promise<OfflineArea[]> {
	if (!offlineSupported()) return [];
	try {
		if (!(await caches.has(OFFLINE_CACHE))) return [];
		const cache = await caches.open(OFFLINE_CACHE);
		return (await readJson<OfflineArea[]>(cache, "areas.json")) || [];
	} catch {
		return [];
	}
}

/** Tiles already kept on this phone, across all areas (counted against MAX_OFFLINE_TILES). */
export async function savedTileCount(): Promise<number> {
	return (await listAreas()).reduce((n, a) => n + a.tiles, 0);
}

/* ---------------- what the map is using right now ---------------- */

function resourceUrls(): string[] {
	try {
		return performance.getEntriesByType("resource").map((e) => e.name);
	} catch {
		return [];
	}
}

const isTileJson = (u: string) => /^https:\/\/api\.mapbox\.com\/v4\/[^/]+\.json(\?|$)/.test(u);

/**
 * Mapbox GL rewrites TileJSON tile URLs before requesting them (tile CDN host
 * → api.mapbox.com, raster image extensions → .webp; see normalizeTileURL in
 * mapbox-gl). Do the same so the saved key is the key the map will ask for.
 */
export function asRequestedByMap(template: string): string {
	return template
		.replace(/^https:\/\/[a-d]\.tiles\.mapbox\.com\//, "https://api.mapbox.com/")
		.replace(/\.(png|jpg|jpeg|webp)(?=\?|$)/, ".webp");
}

/** Tile sources in use: from TileJSON the map loaded, and raster tiles it requested on this page. */
export async function currentTileSources(urls = resourceUrls()): Promise<TileSource[]> {
	const out: TileSource[] = [];
	for (const u of new Set(urls.filter(isTileJson))) {
		try {
			const tj = (await (await fetch(u, { cache: "force-cache" })).json()) as { tiles?: string[]; minzoom?: number; maxzoom?: number };
			const t = tj.tiles?.[0];
			if (!t) continue;
			out.push({ template: templateFromTileUrl(fillDummy(asRequestedByMap(t))) || asRequestedByMap(t), minzoom: tj.minzoom ?? 0, maxzoom: tj.maxzoom ?? 22 });
		} catch {
			/* that source simply is not saved */
		}
	}
	for (const u of urls) {
		const t = templateFromTileUrl(u);
		if (t) out.push({ template: t, minzoom: 0, maxzoom: 22 });
	}
	return out;
}

/* templateFromTileUrl needs numbers to recognise a tile path; it puts the placeholders back. */
function fillDummy(t: string): string {
	return t.replace(/\{z\}/, "1").replace(/\{x\}/, "1").replace(/\{y\}/, "1");
}

/** Everything else the map and the app need to start with no network. */
export function shellAndStyleUrls(urls = resourceUrls()): string[] {
	const out = new Set<string>([`${location.origin}/`]);
	for (const u of urls) {
		let p: URL;
		try {
			p = new URL(u);
		} catch {
			continue;
		}
		if (p.origin === location.origin) {
			if (/^\/(assets|models|brand|platform_icons)\//.test(p.pathname) || /\.(svg|png|webp|glb)$/.test(p.pathname)) out.add(u);
			continue;
		}
		if (p.hostname === "fonts.googleapis.com" || p.hostname === "fonts.gstatic.com") {
			out.add(u);
			continue;
		}
		if (p.hostname !== "api.mapbox.com") continue;
		if (/^\/(map-sessions|events)\//.test(p.pathname)) continue;
		if (templateFromTileUrl(u)) continue; // tiles are planned per area
		out.add(u);
	}
	/* Scripts and styles in the document (the entry chunk may predate the resource buffer). */
	document.querySelectorAll<HTMLScriptElement | HTMLLinkElement>("script[src], link[rel=stylesheet][href], link[rel=modulepreload][href]").forEach((el) => {
		const src = "src" in el && el.src ? el.src : (el as HTMLLinkElement).href;
		if (src && src.startsWith(location.origin)) out.add(src);
	});
	return [...out];
}

/** Count and estimated size for a box and zoom range, for the sources in use. */
export async function estimateArea(bbox: Bbox, zMin: number, zMax: number): Promise<{ tiles: number; estimateBytes: number; sources: number }> {
	const sources = await currentTileSources();
	return { ...estimatePlan(sources, bbox, zMin, zMax), sources: sources.length };
}

/* ---------------- service worker ---------------- */

async function ensureWorker(): Promise<void> {
	const reg = await navigator.serviceWorker.register("/sw.js", { scope: "/" });
	if (!reg.active) await navigator.serviceWorker.ready;
}

async function dropWorkerIfUnused(): Promise<void> {
	const regs = await navigator.serviceWorker.getRegistrations();
	await Promise.all(regs.filter((r) => r.active?.scriptURL.endsWith("/sw.js")).map((r) => r.unregister()));
}

/* ---------------- save / delete ---------------- */

export class OfflineLimitError extends Error {}

/**
 * The map's own session sku (Mapbox's per-load billing tag), read from a tile
 * it requested: some tile APIs (raster/v1, terrain) refuse requests without
 * it. Saving is part of this map session, so it reuses it; never invented.
 */
export function currentSku(urls = resourceUrls()): string | null {
	for (const u of urls) {
		const m = /^https:\/\/api\.mapbox\.com\/.*[?&]sku=([^&]+)/.exec(u);
		if (m) return decodeURIComponent(m[1]);
	}
	return null;
}

function withToken(url: string, token: string, sku: string | null): string {
	if (!/^https:\/\/api\.mapbox\.com\//.test(url)) return url;
	const u = new URL(url);
	if (!u.searchParams.has("access_token")) u.searchParams.set("access_token", token);
	if (sku && templateFromTileUrl(url) && !u.searchParams.has("sku")) u.searchParams.set("sku", sku);
	return u.toString();
}

async function keep(cache: Cache, url: string, token: string, sku: string | null, signal?: AbortSignal): Promise<number> {
	const r = await fetch(withToken(url, token, sku), { signal, mode: "cors", credentials: "omit" });
	if (!r.ok) throw new Error(String(r.status));
	const body = await r.arrayBuffer();
	const headers = new Headers();
	const type = r.headers.get("content-type");
	if (type) headers.set("content-type", type);
	/* The body is already decoded: no content-encoding on the copy. */
	await cache.put(cacheKey(url), new Response(body, { status: 200, headers }));
	return body.byteLength;
}

/**
 * Save the box for offline. Rejects with OfflineLimitError when it would take
 * this phone past MAX_OFFLINE_TILES; with an AbortError if cancelled (what was
 * saved so far is removed again).
 */
export async function saveArea(
	opts: { name: string; bbox: Bbox; zMin: number; zMax: number; token: string; basemap: string },
	onProgress: (p: SaveProgress) => void,
	signal?: AbortSignal,
): Promise<OfflineArea> {
	const sources = await currentTileSources();
	const plan = planTiles(sources, opts.bbox, opts.zMin, opts.zMax);
	const already = await savedTileCount();
	if (!plan.tiles) throw new Error("no-sources");
	if (already + plan.tiles > MAX_OFFLINE_TILES) throw new OfflineLimitError(String(MAX_OFFLINE_TILES - already));

	await ensureWorker();
	const cache = await caches.open(OFFLINE_CACHE);
	const statics = shellAndStyleUrls();
	const sku = currentSku();
	const jobs = [...statics, ...plan.urls];
	const p: SaveProgress = { done: 0, total: jobs.length, bytes: 0, failed: 0 };
	onProgress({ ...p });
	let next = 0;
	const worker = async () => {
		while (next < jobs.length) {
			if (signal?.aborted) return;
			const url = jobs[next++];
			try {
				const n = await keep(cache, url, opts.token, sku, signal);
				p.bytes += n;
			} catch {
				if (signal?.aborted) return;
				p.failed += 1;
			}
			p.done += 1;
			onProgress({ ...p });
		}
	};
	await Promise.all(Array.from({ length: CONCURRENCY }, worker));

	const id = `a${Date.now().toString(36)}`;
	const keys = jobs.map(cacheKey);
	if (signal?.aborted) {
		await forget(cache, keys, await otherKeys(cache, null));
		throw new DOMException("cancelled", "AbortError");
	}
	const area: OfflineArea = {
		id,
		name: opts.name,
		bbox: opts.bbox,
		zMin: opts.zMin,
		zMax: opts.zMax,
		tiles: plan.tiles,
		bytes: p.bytes,
		failed: p.failed,
		savedAt: Date.now(),
		basemap: opts.basemap,
	};
	await writeJson(cache, `area/${id}.json`, keys);
	const areas = (await readJson<OfflineArea[]>(cache, "areas.json")) || [];
	await writeJson(cache, "areas.json", [...areas, area]);
	/* Ask the browser not to evict it under storage pressure, where it lets us. */
	try {
		await navigator.storage?.persist?.();
	} catch {
		/* best effort */
	}
	return area;
}

async function otherKeys(cache: Cache, exceptId: string | null): Promise<Set<string>> {
	const areas = (await readJson<OfflineArea[]>(cache, "areas.json")) || [];
	const keep = new Set<string>();
	for (const a of areas) {
		if (a.id === exceptId) continue;
		for (const k of (await readJson<string[]>(cache, `area/${a.id}.json`)) || []) keep.add(k);
	}
	return keep;
}

async function forget(cache: Cache, keys: string[], stillUsed: Set<string>): Promise<void> {
	await Promise.all(keys.filter((k) => !stillUsed.has(k)).map((k) => cache.delete(k)));
}

export async function deleteArea(id: string): Promise<void> {
	const cache = await caches.open(OFFLINE_CACHE);
	const areas = (await readJson<OfflineArea[]>(cache, "areas.json")) || [];
	const rest = areas.filter((a) => a.id !== id);
	if (!rest.length) {
		await caches.delete(OFFLINE_CACHE);
		await dropWorkerIfUnused();
		return;
	}
	await forget(cache, (await readJson<string[]>(cache, `area/${id}.json`)) || [], await otherKeys(cache, id));
	await cache.delete(metaUrl(`area/${id}.json`));
	await writeJson(cache, "areas.json", rest);
}

export function formatBytes(n: number, ar: boolean): string {
	const mb = n / (1024 * 1024);
	const v = mb >= 10 ? Math.round(mb) : Math.round(mb * 10) / 10;
	const s = ar ? v.toLocaleString("ar-SA") : String(v);
	return ar ? `${s} م.ب` : `${s} MB`;
}
