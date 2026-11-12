'use strict';

/**
 * «السحاب الآن» — EUMETSAT Meteosat Third Generation (MTG-I, 0°) FCI infrared 10.5 µm,
 * 1 km, a full-disk image every 10 minutes, read from EUMETSAT's public WMS (EUMETView).
 *
 * Licence (EUMETSAT Data Policy, amended 25 Nov 2025, Art. 4–6 and 14):
 *  - "Hourly" Level-1 FCI data (the repeat cycle on each clock hour, UTC) is *Core*: free and
 *    unrestricted under CC BY 4.0, whatever its latency → usable live, commercially.
 *  - Every other (10-minute) cycle is *Recommended*: free for any use once it is ≥ 1 hour old;
 *    in real time (< 1 h) it needs an annual licence (EUR 4,000 end user / EUR 8,000 service
 *    provider).
 * So the free animation is: the 10-minute frames that are already ≥ 60 min old, plus the
 * newest on-the-hour frame(s). Set EUMETSAT_REALTIME_LICENSED=1 only once the licence is bought;
 * then every 10-minute frame is used as soon as it exists.
 * Attribution (Art. 6.3): «Contains modified EUMETSAT Meteosat data <year>».
 *
 * The infrared picture is turned into a transparent overlay here: cold (bright) cloud tops →
 * white with opacity, warm ground → fully transparent, so the satellite basemap stays visible.
 */

const { PNG } = require('pngjs');
const { fetchBuffer, Lru, memo } = require('./fetcher');
const { tileBbox3857, tileBox, intersects, tilesFor } = require('./mercator');

const WMS = process.env.EUMETSAT_WMS_URL || 'https://view.eumetsat.int/geoserver/wms';
const LAYER = 'mtg_fd:ir105_hrfi';
const CAPS = process.env.EUMETSAT_CAPS_URL || 'https://view.eumetsat.int/geoserver/mtg_fd/ir105_hrfi/ows?service=WMS&version=1.3.0&request=GetCapabilities';
/* Hard caps on every upstream call. Measured 2026-11-12: capabilities 0.4 s, but one 256 px GetMap tile took 38.6 s,
 * so tiles get 60 s; people never wait that long (route deadline 11 s) and the work continues in the background. */
const CAPS_TIMEOUT_MS = Number(process.env.CLOUD_CAPS_TIMEOUT_MS) || 8_000;
const TILE_TIMEOUT_MS = Number(process.env.CLOUD_TILE_TIMEOUT_MS) || 60_000;
const CAPS_FRESH_MS = 4 * 60_000; // the capabilities time is re-read at most this often
const CAPS_STALE_MAX_MS = (Number(process.env.CLOUD_STALE_MAX_HOURS) || 6) * 3600_000; // last good time kept this long
const STALE_AFTER_MIN = 90; // a newest frame older than this is flagged `stale: true`
const STEP_MIN = 10;
const FREE_LATENCY_MIN = 60;
const WINDOW_MIN = 120;
/* Clouds over the Kingdom arrive from the Red Sea, the Levant and the Gulf: a wider box. */
const REGION = { west: 25, south: 8, east: 65, north: 40 };
const MIN_ZOOM = 0; // the globe view too: full-disk IR is one picture at every zoom
const MAX_ZOOM = 9; // FCI IR is 1 km at nadir (~2 km over KSA): past z9 only magnified


const attribution = (year) => `Contains modified EUMETSAT Meteosat data ${year}`;

function realtimeLicensed() {
  return process.env.EUMETSAT_REALTIME_LICENSED === '1';
}

/** `2026-11-07T11:10:00Z` ⇄ `20261107T1110Z` (path-safe frame id). */
function frameId(iso) {
  const d = new Date(iso);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}T${p(d.getUTCHours())}${p(d.getUTCMinutes())}Z`;
}
function parseFrameId(id) {
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})Z$/.exec(String(id || ''));
  if (!m) return null;
  const t = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
  return Number.isFinite(t) ? t : null;
}

/** May this sensing time be shown at `nowMs` without the real-time licence? */
function frameAllowed(tMs, nowMs, licensed = realtimeLicensed()) {
  if (tMs > nowMs + 60_000) return false;
  if (licensed) return true;
  const d = new Date(tMs);
  const onTheHour = d.getUTCMinutes() === 0;
  return onTheHour || nowMs - tMs >= FREE_LATENCY_MIN * 60_000;
}

/** Arabic clock label in Riyadh time (UTC+3, no DST): «٢:١٠ م». */
function riyadhLabel(tMs) {
  const d = new Date(tMs + 3 * 3600_000);
  let h = d.getUTCHours();
  const m = d.getUTCMinutes();
  const pm = h >= 12;
  h = h % 12 || 12;
  const ar = (s) => String(s).replace(/\d/g, (c) => '٠١٢٣٤٥٦٧٨٩'[c]);
  return `${ar(h)}:${ar(String(m).padStart(2, '0'))} ${pm ? 'م' : 'ص'}`;
}

/**
 * The frames of the last `windowMin` minutes ending at the newest image, oldest first, keeping
 * only those the licence allows now.
 */
function planFrames(latestMs, nowMs, { windowMin = WINDOW_MIN, licensed = realtimeLicensed() } = {}) {
  if (!Number.isFinite(latestMs)) return [];
  const step = STEP_MIN * 60_000;
  const end = Math.floor(latestMs / step) * step;
  const out = [];
  for (let t = end - windowMin * 60_000; t <= end; t += step) {
    if (!frameAllowed(t, nowMs, licensed)) continue;
    const onTheHour = new Date(t).getUTCMinutes() === 0;
    out.push({
      id: frameId(t),
      time: new Date(t).toISOString(),
      label_ar: riyadhLabel(t),
      licence: onTheHour ? 'core-hourly' : nowMs - t >= FREE_LATENCY_MIN * 60_000 ? 'recommended-delayed' : 'recommended-realtime',
    });
  }
  return out;
}

/** The newest image time in the WMS capabilities (`…/2026-11-07T11:10:00.000Z/PT10M`). */
function latestFromCapabilities(xml) {
  const m = /<Dimension[^>]*name="time"[^>]*>([^<]*)<\/Dimension>/.exec(String(xml || ''));
  if (!m) return null;
  const parts = m[1].trim().split(',').pop().split('/');
  const end = parts.length >= 2 ? parts[1] : parts[0];
  const t = Date.parse(end);
  return Number.isFinite(t) ? t : null;
}

let capsCache = { at: 0, latest: null, ok_at: 0, error: null };
let capsInflight = null;

/**
 * One read of the WMS capabilities, shared by everyone who asks while it runs. Always settles
 * (timeout + queue timeout) and always clears `capsInflight`; a failure keeps the last good time.
 */
function refreshCaps(nowMs) {
  if (capsInflight) return capsInflight;
  const p = (async () => {
    try {
      const r = await fetchBuffer(CAPS, { timeoutMs: CAPS_TIMEOUT_MS, queueTimeoutMs: 4_000, label: 'clouds' });
      const t = r.status === 200 ? latestFromCapabilities(r.body.toString('utf8')) : null;
      if (t) capsCache = { at: nowMs, latest: t, ok_at: nowMs, error: null };
      else capsCache = { ...capsCache, error: `caps_status_${r.status}` };
    } catch (e) {
      capsCache = { ...capsCache, error: e.code || e.name || 'error' };
    } finally {
      capsInflight = null;
    }
    return capsCache.latest;
  })();
  capsInflight = p;
  return p;
}

/**
 * Newest image time (ms) in the capabilities. Stale-while-revalidate: a cached time younger than
 * 4 min is returned as is; an older one (up to CLOUD_STALE_MAX_HOURS) is returned at once while a
 * refresh runs in the background; only a cold start waits for the upstream (bounded: ≤ ~12 s).
 */
async function latestImageTime(nowMs = Date.now()) {
  const age = nowMs - capsCache.at;
  if (capsCache.latest && age < CAPS_FRESH_MS) return capsCache.latest;
  if (capsCache.latest && age < CAPS_STALE_MAX_MS) {
    refreshCaps(nowMs);
    return capsCache.latest;
  }
  const fresh = await refreshCaps(nowMs);
  return fresh && nowMs - capsCache.at < CAPS_STALE_MAX_MS ? fresh : null; // too old to show as news
}

/** How fresh our knowledge of the upstream is (for the payload and for logs). */
function capsStatus(nowMs = Date.now()) {
  return {
    checked_at: capsCache.ok_at ? new Date(capsCache.ok_at).toISOString() : null,
    checked_age_min: capsCache.ok_at ? Math.max(0, Math.round((nowMs - capsCache.ok_at) / 60000)) : null,
    last_error: capsCache.error,
  };
}

async function framesPayload(nowMs = Date.now()) {
  const latest = await latestImageTime(nowMs);
  const plan = planFrames(latest, nowMs);
  const frames = plan.map((f) => ({
    ...f,
    image_age_min: Math.max(0, Math.round((nowMs - Date.parse(f.time)) / 60000)),
    tile_url: `/api/weather/clouds/tile/${f.id}/{z}/{x}/{y}.png?v=2`,
  }));
  const newest = frames.length ? frames[frames.length - 1] : null;
  const ageMin = newest ? newest.image_age_min : null;
  const stale = newest ? ageMin > STALE_AFTER_MIN : true;
  const caps = capsStatus(nowMs);
  const year = new Date(nowMs).getUTCFullYear();
  return {
    ok: frames.length > 0,
    layer: 'clouds',
    source: 'EUMETSAT MTG-I FCI IR 10.5 µm (0°), EUMETView WMS',
    attribution: attribution(year),
    attribution_ar: `يحتوي على بيانات معدّلة من EUMETSAT Meteosat ${year}`,
    licence: realtimeLicensed() ? 'EUMETSAT real-time licence' : 'CC BY 4.0 (hourly) + ≥1 h delayed 10-min frames',
    latest_image: latest ? new Date(latest).toISOString() : null,
    newest_frame_time: newest ? newest.time : null,
    age_min: ageMin,
    stale,
    stale_after_min: STALE_AFTER_MIN,
    upstream_checked_at: caps.checked_at,
    upstream_checked_age_min: caps.checked_age_min,
    upstream_error: caps.last_error,
    frames,
    minzoom: MIN_ZOOM,
    maxzoom: MAX_ZOOM,
    bounds: [REGION.west, REGION.south, REGION.east, REGION.north],
    refresh_seconds: 300,
    legend: { kind: 'clouds', items_ar: ['سماوي: قمم باردة جدًا (ركامي، احتمال مطر)', 'أبيض: سحب كثيفة', 'أزرق فاتح: سحب رقيقة'] },
    generated_at: new Date(nowMs).toISOString(),
  };
}

/**
 * Grey IR (bright = cold cloud tops) → white with alpha. Below `lo` transparent, above `hi`
 * nearly opaque, smooth between. Pure; tested.
 */
/* The picture drawn on the map: thin/mid cloud (IR ~75–175) must show on a bright satellite basemap.
 * (The outlook keeps the default curve: its "dense cloud" thresholds were tuned on it.) */
const TILE_CURVE = { lo: 75, hi: 175, maxAlpha: 245 };

function irToOverlay(rgba, { lo = 105, hi = 205, maxAlpha = 235 } = {}) {
  const out = Buffer.alloc(rgba.length);
  for (let i = 0; i < rgba.length; i += 4) {
    const a = rgba[i + 3];
    const v = (rgba[i] + rgba[i + 1] + rgba[i + 2]) / 3;
    let k = (v - lo) / (hi - lo);
    k = k <= 0 ? 0 : k >= 1 ? 1 : k * k * (3 - 2 * k);
    out[i] = 255;
    out[i + 1] = 255;
    out[i + 2] = 255;
    out[i + 3] = a === 0 ? 0 : Math.round(k * maxAlpha);
  }
  return out;
}

/** WMS GetMap URL for a EPSG:3857 box [minx, miny, maxx, maxy] at sensing time `tMs`. */
function wmsMapUrl([a, b, c, d], width, height, tMs) {
  return `${WMS}?service=WMS&version=1.3.0&request=GetMap&layers=${encodeURIComponent(LAYER)}&styles=&crs=EPSG:3857`
    + `&bbox=${a},${b},${c},${d}&width=${width}&height=${height}&format=image/png&transparent=true`
    + `&time=${encodeURIComponent(new Date(tMs).toISOString().replace('.000', ''))}`;
}


const lerp = (a, b, t) => a + (b - a) * t;
const smooth = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));

/**
 * The picture drawn on the map, readable on pale sand and on dark night ground alike:
 *  - colour by cloud-top temperature (brightness): thin cloud pale blue, thick cloud white, very cold
 *    tops (deep convection, where rain can come from) ice-cyan;
 *  - a soft dark shadow under and beside the cloud (offset down-right), so white does not melt into sand.
 * Pure; `rgba` is the WMS grey picture, returns a new RGBA buffer of the same size.
 */
function cloudTileRgba(rgba, w, h) {
  const n = w * h;
  const a = new Float32Array(n); // cloud alpha 0..1
  const col = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const v = (rgba[i * 4] + rgba[i * 4 + 1] + rgba[i * 4 + 2]) / 3;
    const k = rgba[i * 4 + 3] === 0 ? 0 : smooth((v - TILE_CURVE.lo) / (TILE_CURVE.hi - TILE_CURVE.lo));
    a[i] = k * (TILE_CURVE.maxAlpha / 255);
    const thin = smooth((v - 75) / 80); // 0 pale blue … 1 white
    const cold = smooth((v - 205) / 35); // → ice cyan
    let r = lerp(165, 255, thin);
    let g = lerp(200, 255, thin);
    let b = lerp(238, 255, thin);
    r = lerp(r, 120, cold);
    g = lerp(g, 214, cold);
    b = lerp(b, 255, cold);
    col[i * 3] = r;
    col[i * 3 + 1] = g;
    col[i * 3 + 2] = b;
  }
  /* Shadow: 5×5 box blur of the alpha, shifted (+2, +3) px. */
  const blur = new Float32Array(n);
  const R = 2;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let sum = 0;
      let c = 0;
      for (let dy = -R; dy <= R; dy++) {
        const yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (let dx = -R; dx <= R; dx++) {
          const xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          sum += a[yy * w + xx];
          c++;
        }
      }
      blur[y * w + x] = sum / c;
    }
  }
  const out = Buffer.alloc(n * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      const sx = x - 2;
      const sy = y - 3;
      const sa = sx >= 0 && sy >= 0 ? blur[sy * w + sx] * 0.5 : 0; // shadow alpha
      const ca = a[i];
      const oa = ca + sa * (1 - ca);
      if (oa <= 0.002) continue;
      /* over: cloud colour on top of a dark blue-grey shadow (20, 28, 52). */
      const wc = ca / oa;
      out[i * 4] = Math.round(col[i * 3] * wc + 20 * (1 - wc));
      out[i * 4 + 1] = Math.round(col[i * 3 + 1] * wc + 28 * (1 - wc));
      out[i * 4 + 2] = Math.round(col[i * 3 + 2] * wc + 52 * (1 - wc));
      out[i * 4 + 3] = Math.round(oa * 255);
    }
  }
  return out;
}

const tileCache = new Lru(Number(process.env.WEATHER_CLOUD_TILE_CACHE) || 1500);
const inflight = new Map();
let EMPTY;
function emptyPng() {
  if (!EMPTY) {
    const p = new PNG({ width: 1, height: 1 });
    EMPTY = PNG.sync.write(p);
  }
  return EMPTY;
}

/**
 * One overlay tile. Returns { status, body } — 404 for a frame the licence does not allow
 * yet or a bad tile, an empty PNG outside the region.
 */
async function tile(id, z, x, y, nowMs = Date.now(), { legacy = false, background = false } = {}) {
  const t = parseFrameId(id);
  if (t == null || !Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y)) return { status: 400 };
  if (z < MIN_ZOOM || z > MAX_ZOOM || x < 0 || y < 0 || x >= 2 ** z || y >= 2 ** z) return { status: 404 };
  if (!frameAllowed(t, nowMs)) return { status: 404, reason: 'frame_not_licensed_yet' };
  if (!intersects(tileBox(z, x, y), REGION)) return { status: 200, body: emptyPng() };
  const key = `${id}/${z}/${x}/${y}${legacy ? '/legacy' : ''}`;
  const body = await memo(tileCache, inflight, key, async () => {
    /* WMS reprojects and resamples to the tile for us. */
    const size = 256;
    const [a, b, c, d] = tileBbox3857(z, x, y);
    const url = wmsMapUrl([a, b, c, d], size, size, t);
    const r = await fetchBuffer(url, {
      timeoutMs: TILE_TIMEOUT_MS, queueTimeoutMs: background ? 120_000 : 20_000, background, label: 'clouds',
    });
    if (r.status !== 200 || !/png/.test(r.type)) return null;
    const src = PNG.sync.read(r.body);
    const png = new PNG({ width: src.width, height: src.height });
    /* `legacy` = the Build 41–43 look (white on a thin curve), kept only to compare before/after. */
    png.data = legacy ? irToOverlay(src.data) : cloudTileRgba(src.data, src.width, src.height);
    return PNG.sync.write(png, { colorType: 6 });
  }, { timeoutMs: TILE_TIMEOUT_MS + 25_000 });
  if (!body) return { status: 502 };
  return { status: 200, body };
}

/**
 * Warm the tile cache for the newest frames over the Kingdom (z3–z5, ~25 tiles a frame), so the first
 * person to open «السحاب الآن» after a new picture does not watch the map fill in square by square.
 * It is strictly BACKGROUND work: at most WARM_CONCURRENCY tiles at a time, low priority in the
 * fetcher (which keeps half of the slots free for people), one run at a time, a time budget, and a
 * stop after repeated failures — so a slow EUMETView can never queue up in front of a user request.
 */
const WARM_CONCURRENCY = Number(process.env.CLOUD_WARM_CONCURRENCY) || 2;
const WARM_BUDGET_MS = Number(process.env.CLOUD_WARM_BUDGET_MS) || 4 * 60_000;
const WARM_MAX_FAILS = 6;
let warming = false;

async function warm(nowMs = Date.now(), { frames = 4, concurrency = WARM_CONCURRENCY, budgetMs = WARM_BUDGET_MS } = {}) {
  if (warming) return { skipped: 'already_running', frames: 0, tiles: 0 };
  warming = true;
  const started = Date.now();
  try {
    const latest = await latestImageTime(nowMs);
    const plan = planFrames(latest, nowMs).slice(-frames).reverse(); // newest first
    const KSA_BOX = { west: 34, south: 16, east: 56, north: 33 };
    const base = [0, 1, 2, 3, 4, 5].flatMap((z) => tilesFor(KSA_BOX, z));
    /* The newest picture also gets z6 (what a person zoomed in a little asks for). Deeper zooms (up to z9)
     * would be thousands of upstream tiles a frame, so they stay on demand. */
    const closer = tilesFor(KSA_BOX, 6);
    const jobs = plan.flatMap((f, i) => (i === 0 ? base.concat(closer) : base).map((t) => ({ id: f.id, ...t })));
    let next = 0;
    let fails = 0;
    let done = 0;
    const stop = () => fails >= WARM_MAX_FAILS || Date.now() - started > budgetMs;
    await Promise.all(Array.from({ length: Math.max(1, Math.min(concurrency, jobs.length)) }, async () => {
      while (next < jobs.length && !stop()) {
        const j = jobs[next++];
        try {
          const r = await tile(j.id, j.z, j.x, j.y, nowMs, { background: true });
          if (r.status === 502) fails++;
          else if (r.body !== emptyPng()) fails = 0; // a real upstream success (not the empty off-region tile)
        } catch {
          fails++;
        }
        done++;
      }
    }));
    const out = { frames: plan.length, tiles: jobs.length, done, failed_streak: fails, ms: Date.now() - started };
    if (done < jobs.length) out.stopped = fails >= WARM_MAX_FAILS ? 'upstream_failing' : 'budget';
    if (!process.env.NODE_TEST_CONTEXT) console.log(`[clouds] warm ${JSON.stringify(out)}`);
    return out;
  } finally {
    warming = false;
  }
}

module.exports = {
  LAYER, REGION, MIN_ZOOM, MAX_ZOOM,
  frameId, parseFrameId, frameAllowed, planFrames, warm, wmsMapUrl, latestImageTime, latestFromCapabilities, framesPayload, capsStatus, STALE_AFTER_MIN, irToOverlay, cloudTileRgba, TILE_CURVE, tile, riyadhLabel, attribution,
  _reset() {
    capsCache = { at: 0, latest: null, ok_at: 0, error: null };
    capsInflight = null;
    warming = false;
    tileCache.map.clear();
    inflight.clear();
  },
};
