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
const { tileBbox3857, tileBox, intersects } = require('./mercator');

const WMS = process.env.EUMETSAT_WMS_URL || 'https://view.eumetsat.int/geoserver/wms';
const LAYER = 'mtg_fd:ir105_hrfi';
const CAPS = 'https://view.eumetsat.int/geoserver/mtg_fd/ir105_hrfi/ows?service=WMS&version=1.3.0&request=GetCapabilities';
const STEP_MIN = 10;
const FREE_LATENCY_MIN = 60;
const WINDOW_MIN = 120;
/* Clouds over the Kingdom arrive from the Red Sea, the Levant and the Gulf: a wider box. */
const REGION = { west: 25, south: 8, east: 65, north: 40 };
const MIN_ZOOM = 3;
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

let capsCache = { at: 0, latest: null };
async function latestImageTime(nowMs = Date.now()) {
  if (capsCache.latest && nowMs - capsCache.at < 4 * 60_000) return capsCache.latest;
  try {
    const r = await fetchBuffer(CAPS, { timeoutMs: 20_000 });
    const t = r.status === 200 ? latestFromCapabilities(r.body.toString('utf8')) : null;
    if (t) capsCache = { at: nowMs, latest: t };
  } catch {
    /* keep the last known time */
  }
  return capsCache.latest;
}

async function framesPayload(nowMs = Date.now()) {
  const latest = await latestImageTime(nowMs);
  const frames = planFrames(latest, nowMs).map((f) => ({ ...f, tile_url: `/api/weather/clouds/tile/${f.id}/{z}/{x}/{y}.png` }));
  const year = new Date(nowMs).getUTCFullYear();
  return {
    ok: frames.length > 0,
    layer: 'clouds',
    source: 'EUMETSAT MTG-I FCI IR 10.5 µm (0°), EUMETView WMS',
    attribution: attribution(year),
    attribution_ar: `يحتوي على بيانات معدّلة من EUMETSAT Meteosat ${year}`,
    licence: realtimeLicensed() ? 'EUMETSAT real-time licence' : 'CC BY 4.0 (hourly) + ≥1 h delayed 10-min frames',
    latest_image: latest ? new Date(latest).toISOString() : null,
    frames,
    minzoom: MIN_ZOOM,
    maxzoom: MAX_ZOOM,
    bounds: [REGION.west, REGION.south, REGION.east, REGION.north],
    refresh_seconds: 300,
    legend: { kind: 'clouds', items_ar: ['أبيض كثيف: سحب عالية باردة (ركامي، احتمال مطر)', 'أبيض خفيف: سحب رقيقة أو منخفضة'] },
    generated_at: new Date(nowMs).toISOString(),
  };
}

/**
 * Grey IR (bright = cold cloud tops) → white with alpha. Below `lo` transparent, above `hi`
 * nearly opaque, smooth between. Pure; tested.
 */
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
async function tile(id, z, x, y, nowMs = Date.now()) {
  const t = parseFrameId(id);
  if (t == null || !Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y)) return { status: 400 };
  if (z < MIN_ZOOM || z > MAX_ZOOM || x < 0 || y < 0 || x >= 2 ** z || y >= 2 ** z) return { status: 404 };
  if (!frameAllowed(t, nowMs)) return { status: 404, reason: 'frame_not_licensed_yet' };
  if (!intersects(tileBox(z, x, y), REGION)) return { status: 200, body: emptyPng() };
  const key = `${id}/${z}/${x}/${y}`;
  const body = await memo(tileCache, inflight, key, async () => {
    /* WMS reprojects and resamples to the tile for us. */
    const size = 256;
    const [a, b, c, d] = tileBbox3857(z, x, y);
    const url = wmsMapUrl([a, b, c, d], size, size, t);
    const r = await fetchBuffer(url, { timeoutMs: 45_000 });
    if (r.status !== 200 || !/png/.test(r.type)) return null;
    const src = PNG.sync.read(r.body);
    const png = new PNG({ width: src.width, height: src.height });
    png.data = irToOverlay(src.data);
    return PNG.sync.write(png, { colorType: 6 });
  });
  if (!body) return { status: 502 };
  return { status: 200, body };
}

module.exports = {
  LAYER, REGION, MIN_ZOOM, MAX_ZOOM,
  frameId, parseFrameId, frameAllowed, planFrames, wmsMapUrl, latestImageTime, latestFromCapabilities, framesPayload, irToOverlay, tile, riyadhLabel, attribution,
  _reset() {
    capsCache = { at: 0, latest: null };
  },
};
