'use strict';

/**
 * «وين ربّع» — where the desert has turned green, from NASA VIIRS (NOAA-20) 8-day NDVI
 * (GIBS layer `VIIRS_NOAA20_NDVI_8Day`, read at z7 ≈ 1.1 km pixels over KSA).
 *
 * "Greened" = the newest 8-day NDVI is green enough (≥ 0.15) AND it rose by ≥ 0.06 over the
 * dry-season baseline: per pixel, the greenest of three summer composites (20 Jun, 20 Jul,
 * 25 Aug). Irrigated farms and parks are green at some point of the summer, so the rise filters
 * most of them out and leaves the rain-fed spring (ربيع، روضة، فيضة). Autumn-sown fields can
 * still show; the layer says so.
 * Free, no key (NASA open data; credit: NASA VIIRS / GIBS).
 */

const colormap = require('./colormap');
const gibs = require('./gibs');
const { KSA, tilesFor } = require('./mercator');
const { Mosaic, renderTile, stepColor } = require('./raster');
const { Lru, memo } = require('./fetcher');

const LAYER = 'VIIRS_NOAA20_NDVI_8Day';
const MATRIX = 'GoogleMapsCompatible_Level8';
const Z = 7;
const MIN_NDVI = 0.15;
const MIN_RISE = 0.06;
const ATTRIBUTION = 'NASA VIIRS NOAA-20 NDVI (8-day) via NASA GIBS';
const TILES = tilesFor(KSA, Z);

let lookup = null;
function ndviLookup() {
  /* Bare ground (NDVI < 0) is transparent in GIBS: read it as 0, not unknown. */
  if (!lookup) lookup = colormap.buildLookup(colormap.load('MODIS_NDVI'), { zeroTransparentBelow: 0.001 });
  return lookup;
}

/** The dry-season baseline dates for a composite date: the summer before this season. */
function baselineDates(currentYmd) {
  const [y, m] = currentYmd.split('-').map(Number);
  const yy = m >= 9 ? y : y - 1;
  return [`${yy}-06-20`, `${yy}-07-20`, `${yy}-08-25`];
}

/** Pixel-wise maximum of mosaics (NaN ignored). */
function maxMosaic(list) {
  const out = new Mosaic(Z);
  for (const { x, y } of TILES) {
    let acc = null;
    for (const m of list) {
      const a = m.get(x, y);
      if (!a) continue;
      if (!acc) acc = Float32Array.from(a);
      else for (let i = 0; i < a.length; i++) if (!(acc[i] >= a[i])) acc[i] = Number.isFinite(a[i]) ? a[i] : acc[i];
    }
    if (acc) out.set(x, y, acc);
  }
  return out;
}

/** Greened rise (NDVI points) or NaN/≤0 when not greened. Pure. */
function greenRise(now, base) {
  if (!Number.isFinite(now) || !Number.isFinite(base)) return NaN;
  if (now < MIN_NDVI) return 0;
  const d = now - base;
  return d >= MIN_RISE ? d : 0;
}

let latest = { at: 0, ymd: null };
async function currentDate(nowMs = Date.now()) {
  if (latest.ymd && nowMs - latest.at < 6 * 3600_000) return latest.ymd;
  try {
    const t = await gibs.latestTime(LAYER, MATRIX, nowMs, 40);
    if (t) latest = { at: nowMs, ymd: gibs.ymd(t) };
  } catch {
    /* keep */
  }
  return latest.ymd;
}

let baseCache = null;
const mosaics = new Lru(6); // date → Promise<Mosaic>
const mosaicInflight = new Map();
function mosaicFor(ymd) {
  return memo(mosaics, mosaicInflight, ymd, async () => {
    const m = new Mosaic(Z);
    const arrs = await Promise.all(TILES.map(({ x, y }) => gibs.valuesTile(LAYER, ymd, MATRIX, Z, x, y, ndviLookup(), { transparentValue: NaN }).catch(() => null)));
    let ok = 0;
    TILES.forEach(({ x, y }, i) => {
      if (arrs[i]) {
        m.set(x, y, arrs[i]);
        ok++;
      }
    });
    m.ok = ok;
    return ok ? m : null;
  });
}

async function state(nowMs = Date.now()) {
  const ymd = await currentDate(nowMs);
  if (!ymd) return null;
  const dates = baselineDates(ymd);
  const [cur, ...summer] = await Promise.all([mosaicFor(ymd), ...dates.map(mosaicFor)]);
  const have = summer.filter(Boolean);
  if (!cur || !have.length) return null;
  const key = `${ymd}|${dates.join(',')}|${have.length}`;
  if (!baseCache || baseCache.key !== key) baseCache = { key, mosaic: maxMosaic(have) };
  const bas = baseCache.mosaic;
  return { ymd, base: dates.join(','), cur, bas, rise: (lng, lat) => greenRise(cur.bilinear(lng, lat), bas.bilinear(lng, lat)) };
}

/** Point read: NDVI now, baseline, rise (max over the 3×3 pixels around). */
function pointInfo(st, lng, lat) {
  const ndvi = st.cur.maxAround(lng, lat, 1);
  const base = st.bas.at(lng, lat);
  const rise = greenRise(ndvi, base);
  return { ndvi: Number.isFinite(ndvi) ? Math.round(ndvi * 100) / 100 : null, rise: Number.isFinite(rise) ? Math.round(rise * 100) / 100 : 0 };
}

const LEGEND = [
  { min: 0.06, max: 0.12, rgba: [170, 230, 120, 140], label_ar: 'بداية خضرة' },
  { min: 0.12, max: 0.2, rgba: [90, 200, 70, 175], label_ar: 'ربيع واضح' },
  { min: 0.2, max: null, rgba: [20, 140, 40, 205], label_ar: 'ربيع كثيف' },
];
const color = stepColor(LEGEND);

function within(p, ms) {
  return Promise.race([p.catch(() => null), new Promise((r) => setTimeout(() => r(null), ms).unref())]);
}

async function areas({ bbox, nowMs = Date.now(), waitMs = 25_000 }) {
  const st = await within(state(nowMs), waitMs);
  if (!st) return { ok: false, error: 'warming', message_ar: 'نجهّز صور الخضرة، جرّب بعد دقيقة.' };
  const step = 0.02;
  const cells = [];
  const area = (bbox.east - bbox.west) * (bbox.north - bbox.south);
  const s = area / (step * step) > 250_000 ? Math.sqrt(area / 250_000) : step;
  for (let lat = bbox.south; lat <= bbox.north; lat += s) {
    for (let lng = bbox.west; lng <= bbox.east; lng += s) {
      const ndvi = st.cur.at(lng, lat);
      const rise = greenRise(ndvi, st.bas.at(lng, lat));
      if (rise > 0) cells.push([+lng.toFixed(3), +lat.toFixed(3), Math.round(ndvi * 100) / 100, Math.round(rise * 100) / 100]);
    }
  }
  cells.sort((a, b) => b[3] - a[3]);
  const cap = 3000;
  return {
    ok: true,
    layer: 'green',
    composite_date: st.ymd,
    baseline_dates: st.base.split(','),
    source: 'NASA VIIRS NOAA-20 NDVI 8-day composite, read from NASA GIBS',
    attribution: ATTRIBUTION,
    licence: 'NASA open data (no restrictions; credit requested)',
    rule: { min_ndvi: MIN_NDVI, min_rise_over_baseline: MIN_RISE },
    grid: { step_deg: +s.toFixed(3), columns: ['lng', 'lat', 'ndvi', 'rise'], cells: cells.slice(0, cap), truncated: cells.length > cap },
    tile_url: '/api/weather/green/tile/{z}/{x}/{y}.png',
    minzoom: 4,
    maxzoom: 12,
    legend: LEGEND.map(({ min, max, rgba, label_ar }) => ({ min_rise: min, max_rise: max, color: `#${rgba.slice(0, 3).map((v) => v.toString(16).padStart(2, '0')).join('')}`, label_ar })),
    note_ar: 'خضرة جديدة مقارنة بالصيف (أغلب المزارع والحدائق المروية مستبعدة، وقد تظهر مزارع زُرعت في الخريف). الصورة مجمّعة كل ٨ أيام بدقة ~١ كم.',
    generated_at: new Date(nowMs).toISOString(),
  };
}

const tileCache = new Lru(800);
const inflight = new Map();
async function tile(z, x, y, nowMs = Date.now()) {
  if (!Number.isInteger(z) || z < 4 || z > 12 || x < 0 || y < 0 || x >= 2 ** z || y >= 2 ** z) return { status: 404 };
  const st = await within(state(nowMs), 25_000);
  if (!st) return { status: 503 };
  const key = `${st.ymd}/${z}/${x}/${y}`;
  const body = await memo(tileCache, inflight, key, async () => renderTile(z, x, y, st.rise, color));
  return { status: 200, body };
}

/** Loads the composites now and every 6 h (the caller chains it before the rain warm-up). */
function warm() {
  return state().catch(() => null);
}

module.exports = {
  LAYER, Z, LEGEND, ATTRIBUTION, MIN_NDVI, MIN_RISE, TILES,
  baselineDates, maxMosaic, greenRise, state, pointInfo, areas, tile, warm, color,
  _reset() {
    latest = { at: 0, ymd: null };
    baseCache = null;
    mosaics.map.clear();
    tileCache.map.clear();
  },
};
