'use strict';

/**
 * «وين نزل مطر» — observed rain, last 1 / 3 / 7 days, from NASA GPM IMERG (Early run, the
 * half-hourly 0.1° satellite rain estimate; GIBS layer `IMERG_Precipitation_Rate_30min`).
 *
 * Each half-hour tile is read back to mm/h through GIBS's published colour table (bins ≈5 %
 * wide), multiplied by 0.5 h, and summed into 3-hour bins per z4 tile (z4 pixel ≈ 9 km over
 * KSA ≈ IMERG's 0.1° cell). A window of N days is the sum of the bins of the N×24 h that end
 * at the newest half hour GIBS has (IMERG Early arrives ≈ 4–7 h after the rain).
 * Free, no key: NASA data carry no restriction on use (credit: NASA GPM IMERG / GIBS).
 */

const colormap = require('./colormap');
const gibs = require('./gibs');
const { KSA, tilesFor } = require('./mercator');
const { Mosaic, renderTile, stepColor } = require('./raster');
const { Lru, memo } = require('./fetcher');

const LAYER = 'IMERG_Precipitation_Rate_30min';
const MATRIX = 'GoogleMapsCompatible_Level6';
const Z = 4;
const HALF_HOUR = 30 * 60_000;
const BIN = 3 * 3600_000;
const MAX_DAYS = 7;
const ALLOWED_DAYS = [1, 3, 7];
const ATTRIBUTION = 'NASA GPM IMERG (Early) via NASA GIBS';

let lookup = null;
function rateLookup() {
  if (!lookup) lookup = colormap.buildLookup(colormap.load('GPM_Precipitation_Rate'), { zeroTransparentBelow: 0.11 });
  return lookup;
}

const TILES = tilesFor(KSA, Z);

/* State: per 3-h bin → { tiles: Map("x/y" → Float32Array mm), frames: Set(ms), missing: Set(ms) }. */
const bins = new Map();
let latestMs = null;
let latestAt = 0;
const frameInflight = new Map();

function binStart(t) {
  return Math.floor(t / BIN) * BIN;
}

/** Half-hour frame times of the `days` window ending at `latest` (inclusive), oldest first. */
function windowFrames(latest, days) {
  const out = [];
  const end = Math.floor(latest / HALF_HOUR) * HALF_HOUR;
  for (let t = end - days * 24 * 2 * HALF_HOUR + HALF_HOUR; t <= end; t += HALF_HOUR) out.push(t);
  return out;
}

async function refreshLatest(nowMs = Date.now()) {
  if (latestMs && nowMs - latestAt < 10 * 60_000) return latestMs;
  try {
    const t = await gibs.latestTime(LAYER, MATRIX, nowMs, MAX_DAYS + 2);
    if (t) {
      latestMs = t;
      latestAt = nowMs;
    }
  } catch {
    /* keep the last one */
  }
  return latestMs;
}

function binFor(t) {
  const k = binStart(t);
  let b = bins.get(k);
  if (!b) {
    b = { start: k, tiles: new Map(), frames: new Set(), missing: new Set() };
    bins.set(k, b);
  }
  return b;
}

/** Adds one half-hour frame (all KSA tiles) into its bin. Idempotent. */
function loadFrame(t) {
  const b = binFor(t);
  if (b.frames.has(t) || b.missing.has(t)) return Promise.resolve();
  if (frameInflight.has(t)) return frameInflight.get(t);
  const time = new Date(t).toISOString().replace('.000', '');
  const p = Promise.all(
    TILES.map(({ x, y }) => gibs.valuesTile(LAYER, time, MATRIX, Z, x, y, rateLookup(), { transparentValue: 0 }).catch(() => null)),
  ).then((arrs) => {
    if (arrs.every((a) => a == null)) {
      b.missing.add(t);
      return;
    }
    TILES.forEach(({ x, y }, i) => {
      const a = arrs[i];
      if (!a) return;
      const key = `${x}/${y}`;
      let sum = b.tiles.get(key);
      if (!sum) {
        sum = new Float32Array(a.length);
        b.tiles.set(key, sum);
      }
      for (let k = 0; k < a.length; k++) if (a[k] > 0) sum[k] += a[k] * 0.5;
    });
    b.frames.add(t);
  }).finally(() => frameInflight.delete(t));
  frameInflight.set(t, p);
  return p;
}

function prune(latest) {
  const keep = binStart(latest) - (MAX_DAYS + 1) * 86400_000;
  for (const k of bins.keys()) if (k < keep) bins.delete(k);
}

/** Loads the frames of a window (newest first, so a short wait still covers the recent past). */
async function ensureWindow(days, { waitMs = 20_000, nowMs = Date.now() } = {}) {
  const latest = await refreshLatest(nowMs);
  if (!latest) return null;
  prune(latest);
  const frames = windowFrames(latest, days).reverse();
  const all = Promise.all(frames.map((t) => loadFrame(t)));
  await Promise.race([all, new Promise((r) => setTimeout(r, waitMs).unref())]);
  return latest;
}

const sums = new Lru(12);
/**
 * Accumulated rain (mm) of the window as a Mosaic, plus coverage. Cached per (days, latest,
 * frames loaded).
 */
function windowSum(days, latest) {
  const frames = windowFrames(latest, days);
  /* Whole 3-h bins: the window starts at the bin of its first half hour (≤ 2.5 h earlier). */
  const first = binStart(frames[0]);
  const binKeys = [...new Set(frames.map(binStart))];
  let ok = 0;
  let missing = 0;
  for (const k of binKeys) {
    const b = bins.get(k);
    if (!b) continue;
    for (const t of b.frames) if (t >= first && t <= latest) ok++;
    for (const t of b.missing) if (t >= first && t <= latest) missing++;
  }
  const key = `${days}/${latest}/${ok}`;
  const hit = sums.get(key);
  if (hit) return hit;
  const mosaic = new Mosaic(Z);
  const last = new Mosaic(Z); // newest bin start (ms) with ≥ 1 mm, per pixel
  for (const { x, y } of TILES) {
    const acc = new Float32Array(256 * 256);
    const lastRain = new Float32Array(256 * 256).fill(NaN);
    for (const k of binKeys) {
      const b = bins.get(k);
      const a = b && b.tiles.get(`${x}/${y}`);
      if (!a) continue;
      for (let i = 0; i < a.length; i++) {
        if (a[i] > 0) acc[i] += a[i];
        if (a[i] >= 1 && !(lastRain[i] >= k)) lastRain[i] = k;
      }
    }
    mosaic.set(x, y, acc);
    last.set(x, y, lastRain);
  }
  const out = { mosaic, last, coverage: { frames_expected: Math.round((latest + HALF_HOUR - first) / HALF_HOUR), frames_ok: ok, frames_missing: missing }, from: first, to: latest + HALF_HOUR };
  sums.set(key, out);
  return out;
}

/* Legend (accumulated mm). */
const LEGEND = [
  { min: 1, max: 5, rgba: [143, 211, 255, 150], label_ar: '١–٥ ملم' },
  { min: 5, max: 10, rgba: [64, 160, 255, 175], label_ar: '٥–١٠ ملم' },
  { min: 10, max: 25, rgba: [30, 96, 230, 195], label_ar: '١٠–٢٥ ملم' },
  { min: 25, max: 50, rgba: [120, 60, 220, 210], label_ar: '٢٥–٥٠ ملم' },
  { min: 50, max: null, rgba: [200, 40, 160, 220], label_ar: 'أكثر من ٥٠ ملم' },
];
const color = stepColor(LEGEND);

function parseDays(raw) {
  const n = Number(raw || 1);
  return ALLOWED_DAYS.includes(n) ? n : null;
}

const toAr = (n) => String(n).replace(/\d/g, (c) => '٠١٢٣٤٥٦٧٨٩'[c]);

/** «اليوم» / «أمس» / «قبل ٣ أيام» from hours. */
function agoAr(hours) {
  if (!Number.isFinite(hours)) return null;
  if (hours < 12) return 'قبل ساعات';
  if (hours < 24) return 'اليوم';
  const d = Math.round(hours / 24);
  if (d <= 1) return 'أمس';
  if (d === 2) return 'قبل يومين';
  if (d <= 10) return `قبل ${toAr(d)} أيام`;
  return `قبل ${toAr(d)} يومًا`;
}

/** Point read for search: mm in the window (max of the 3×3 cells around) and hours since ≥1 mm. */
function pointInfo(sum, lng, lat, nowMs = Date.now()) {
  const mm = sum.mosaic.maxAround(lng, lat, 1);
  const lastStart = sum.last.maxAround(lng, lat, 1);
  const hoursAgo = Number.isFinite(lastStart) ? Math.max(0, (nowMs - (lastStart + BIN / 2)) / 3600_000) : NaN;
  return { mm: Number.isFinite(mm) ? Math.round(mm * 10) / 10 : 0, hoursAgo };
}

async function recent({ days, bbox, nowMs = Date.now(), waitMs }) {
  const latest = await ensureWindow(days, { waitMs, nowMs });
  if (!latest) return { ok: false, error: 'source_unavailable', message_ar: 'مصدر المطر ما رد الحين، جرّب بعد شوي.' };
  const sum = windowSum(days, latest);
  const step = 0.1;
  const cells = [];
  let max = 0;
  for (let lat = Math.ceil(bbox.south / step) * step; lat <= bbox.north; lat += step) {
    for (let lng = Math.ceil(bbox.west / step) * step; lng <= bbox.east; lng += step) {
      const mm = sum.mosaic.at(lng, lat);
      if (!(mm >= 1)) continue;
      const { hoursAgo } = pointInfo(sum, lng, lat, nowMs);
      max = Math.max(max, mm);
      cells.push([+lng.toFixed(2), +lat.toFixed(2), Math.round(mm * 10) / 10, Number.isFinite(hoursAgo) ? Math.round(hoursAgo) : null]);
    }
  }
  cells.sort((a, b) => b[2] - a[2]);
  const cap = 4000;
  return {
    ok: true,
    layer: 'rain',
    days,
    units: 'mm',
    period: { from: new Date(sum.from).toISOString(), to: new Date(sum.to).toISOString() },
    source: 'NASA GPM IMERG Early (half-hourly, 0.1°), read from NASA GIBS',
    attribution: ATTRIBUTION,
    licence: 'NASA open data (no restrictions; credit requested)',
    coverage: sum.coverage,
    complete: sum.coverage.frames_ok + sum.coverage.frames_missing >= sum.coverage.frames_expected,
    max_mm: Math.round(max * 10) / 10,
    grid: { step_deg: step, columns: ['lng', 'lat', 'mm', 'hours_since_rain'], cells: cells.slice(0, cap), truncated: cells.length > cap },
    tile_url: `/api/weather/rain/tile/${days}/{z}/{x}/{y}.png`,
    minzoom: 3,
    maxzoom: 11,
    legend: LEGEND.map(({ min, max: mx, rgba, label_ar }) => ({ min_mm: min, max_mm: mx, color: `#${rgba.slice(0, 3).map((v) => v.toString(16).padStart(2, '0')).join('')}`, label_ar })),
    note_ar: 'تقدير من الأقمار الصناعية (دقة ~١٠ كم)، يتأخر ٤–٧ ساعات. المطر الخفيف جدًا والزخات الصغيرة قد لا تظهر.',
    generated_at: new Date(nowMs).toISOString(),
  };
}

const tileCache = new Lru(800);
const tileInflight = new Map();
async function tile(days, z, x, y, nowMs = Date.now()) {
  if (!Number.isInteger(z) || z < 3 || z > 11 || x < 0 || y < 0 || x >= 2 ** z || y >= 2 ** z) return { status: 404 };
  const latest = await ensureWindow(days, { waitMs: 15_000, nowMs });
  if (!latest) return { status: 503 };
  const sum = windowSum(days, latest);
  const key = `${days}/${latest}/${sum.coverage.frames_ok}/${z}/${x}/${y}`;
  const body = await memo(tileCache, tileInflight, key, async () => renderTile(z, x, y, (lng, lat) => sum.mosaic.bilinear(lng, lat), color));
  return { status: 200, body };
}

/** Loads the whole 7-day window (resolves when every frame is in). */
function warm() {
  return ensureWindow(MAX_DAYS, { waitMs: 15 * 60_000 }).catch(() => null);
}

module.exports = {
  LAYER, MATRIX, Z, LEGEND, rateLookup, refreshLatest, ATTRIBUTION, TILES,
  windowFrames, binStart, parseDays, agoAr, pointInfo, ensureWindow, windowSum, recent, tile, warm, color,
  _reset() {
    bins.clear();
    sums.map.clear();
    tileCache.map.clear();
    latestMs = null;
    latestAt = 0;
  },
};
