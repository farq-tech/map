'use strict';

/**
 * «أقرب ربيع» — the greened pixels of «وين ربّع» (green.js) grouped into connected regions, so
 * the driving compass points at an area of spring, not a lone pixel.
 *
 * Sample the VIIRS 8-day NDVI rise at its native step (0.01° ≈ one z7 pixel), keep cells with
 * rise ≥ 0.06 (the legend's first level), join them with 8-neighbour connectivity and drop
 * regions under MIN_AREA_KM2. Each region is named after the nearest OSM روضة / فيضة within
 * PLACE_MAX_KM, if any. Pure parts (clusterRegions, levelOf, nearestPlace) need no network.
 */

const crypto = require('crypto');
const green = require('./green');
const outdoor = require('../outdoor');
const { haversineKm } = require('./mercator');

const STEP = 0.01;
const MIN_RISE = 0.06;
const MIN_AREA_KM2 = 3;
const MAX_SPAN_DEG = 3;
const MAX_POINTS = 60;
const MAX_REGIONS = 40;
const PLACE_MAX_KM = 5;
const PLACE_KINDS = new Set(['rawdah', 'fayad']);
/* A region whose cells were ALREADY green in summer (baseline NDVI ≥ 0.15, the same bar as green.js) is almost
 * certainly irrigated farmland, not rain-fed spring: it is flagged and, by default, left out of «أقرب ربيع». */
const SUMMER_GREEN_NDVI = 0.15;
const FARM_SHARE = 0.5;
const SNAP = 0.5;
const FRESH_MS = 6 * 3600_000;
const STALE_MAX_MS = 14 * 24 * 3600_000;
const CACHE_MAX = 200;
const FARM_LABEL_AR = 'خضرة جديدة (قد تكون مزارع)';
const KM_PER_DEG = (Math.PI / 180) * 6371.0088;

const LEVELS = [
  { level: 'dense', min: 0.2, label_ar: 'ربيع كثيف' },
  { level: 'clear', min: 0.12, label_ar: 'ربيع واضح' },
  { level: 'start', min: 0.06, label_ar: 'بداية خضرة' },
];

/** Legend level of a rise (thresholds 0.06 / 0.12 / 0.2), null below the first. Pure. */
function levelOf(rise) {
  for (const l of LEVELS) if (rise >= l.min) return { level: l.level, label_ar: l.label_ar };
  return null;
}

/** km² of one step×step cell centred at `lat`. Pure. */
function cellAreaKm2(lat, step = STEP) {
  return (step * KM_PER_DEG) ** 2 * Math.cos((lat * Math.PI) / 180);
}

const round = (n, d) => Math.round(n * 10 ** d) / 10 ** d;

/** Evenly spaced pick of at most `n` items, keeping order. */
function spread(list, n) {
  if (list.length <= n) return list.slice();
  const out = [];
  for (let k = 0; k < n; k++) out.push(list[Math.floor((k * list.length) / n)]);
  return out;
}

/**
 * Cells `[lng, lat, rise]` on a step grid → connected regions (8-neighbour), largest first;
 * regions under `minAreaKm2` are dropped. Pure.
 */
function clusterRegions(cells, { minAreaKm2 = MIN_AREA_KM2, step = STEP, maxPoints = MAX_POINTS } = {}) {
  const grid = new Map();
  const items = [];
  for (const c of cells) {
    const [lng, lat, rise, base] = c;
    if (!(rise >= MIN_RISE)) continue;
    const i = Math.round(lng / step);
    const j = Math.round(lat / step);
    const key = `${i},${j}`;
    if (grid.has(key)) continue;
    grid.set(key, items.length);
    items.push({ i, j, lng, lat, rise, base: Number.isFinite(base) ? base : NaN, seen: false });
  }
  const regions = [];
  for (const start of items) {
    if (start.seen) continue;
    start.seen = true;
    const members = [start];
    for (let q = 0; q < members.length; q++) {
      const m = members[q];
      for (let dj = -1; dj <= 1; dj++) {
        for (let di = -1; di <= 1; di++) {
          if (!di && !dj) continue;
          const k = grid.get(`${m.i + di},${m.j + dj}`);
          if (k === undefined || items[k].seen) continue;
          items[k].seen = true;
          members.push(items[k]);
        }
      }
    }
    let area = 0;
    let sx = 0;
    let sy = 0;
    let sr = 0;
    let mr = 0;
    let baseN = 0;
    let baseGreen = 0;
    let baseSum = 0;
    let w = Infinity;
    let s = Infinity;
    let e = -Infinity;
    let n = -Infinity;
    const edge = [];
    const inner = [];
    for (const m of members) {
      const a = cellAreaKm2(m.lat, step);
      area += a;
      sx += m.lng * a;
      sy += m.lat * a;
      sr += m.rise;
      if (m.rise > mr) mr = m.rise;
      if (Number.isFinite(m.base)) {
        baseN++;
        baseSum += m.base;
        if (m.base >= SUMMER_GREEN_NDVI) baseGreen++;
      }
      w = Math.min(w, m.lng);
      e = Math.max(e, m.lng);
      s = Math.min(s, m.lat);
      n = Math.max(n, m.lat);
      const closed = grid.has(`${m.i + 1},${m.j}`) && grid.has(`${m.i - 1},${m.j}`) && grid.has(`${m.i},${m.j + 1}`) && grid.has(`${m.i},${m.j - 1}`);
      (closed ? inner : edge).push(m);
    }
    if (area < minAreaKm2) continue;
    /* Edge cells first (the nearest point of an area is on its edge), interior to fill. */
    const pick = spread(edge, maxPoints);
    if (pick.length < maxPoints) pick.push(...spread(inner, maxPoints - pick.length));
    const centroid = [round(sx / area, 4), round(sy / area, 4)];
    const meanRise = sr / members.length;
    const summerShare = baseN ? baseGreen / baseN : null;
    const kind = summerShare === null ? 'unknown' : summerShare >= FARM_SHARE ? 'likely_farm' : 'rain_fed';
    const region = {
      id: `gr_${crypto.createHash('sha1').update(`${centroid[0].toFixed(2)},${centroid[1].toFixed(2)}`).digest('hex').slice(0, 10)}`,
      centroid,
      bbox: [round(w - step / 2, 4), round(s - step / 2, 4), round(e + step / 2, 4), round(n + step / 2, 4)],
      area_km2: round(area, 1),
      cells: members.length,
      mean_rise: round(meanRise, 3),
      max_rise: round(mr, 3),
      ...levelOf(meanRise),
      kind,
      summer_green_share: summerShare === null ? null : round(summerShare, 2),
      mean_baseline: baseN ? round(baseSum / baseN, 3) : null,
      points: pick.map((m) => [round(m.lng, 4), round(m.lat, 4)]),
    };
    /* All cells, for nearestPlace; hidden from JSON. */
    if (kind === 'likely_farm') region.label_ar = FARM_LABEL_AR;
    Object.defineProperty(region, '_members', { value: members, enumerable: false });
    regions.push(region);
  }
  regions.sort((a, b) => b.area_km2 - a.area_km2);
  return regions;
}

/** A place row usable for naming: our OSM روضة / فيضة with a name, never Google (`gm:`). */
function usablePlace(p) {
  if (!p || !PLACE_KINDS.has(p.kind) || !p.name) return false;
  if (!Number.isFinite(p.lat) || !Number.isFinite(p.lng)) return false;
  for (const k of [p.id, p.key, p.source_id]) if (String(k || '').startsWith('gm:')) return false;
  return true;
}

/**
 * Nearest usable place within `maxKm` of the region (its centroid or any of its cells) as
 * `{ name, kind, distance_km }`, else null. Pure.
 */
function nearestPlace(region, places, maxKm = PLACE_MAX_KM) {
  const [w, s, e, n] = region.bbox;
  const padLat = maxKm / KM_PER_DEG;
  const padLng = padLat / Math.max(0.2, Math.cos((((s + n) / 2) * Math.PI) / 180));
  const cells = region._members || region.points.map(([lng, lat]) => ({ lng, lat }));
  const centre = { lng: region.centroid[0], lat: region.centroid[1] };
  let best = null;
  for (const p of places) {
    if (!usablePlace(p)) continue;
    if (p.lng < w - padLng || p.lng > e + padLng || p.lat < s - padLat || p.lat > n + padLat) continue;
    let d = haversineKm(centre, p);
    for (const c of cells) {
      if (d === 0) break;
      const dc = haversineKm(c, p);
      if (dc < d) d = dc;
    }
    if (d <= maxKm && (!best || d < best.d)) best = { d, p };
  }
  return best ? { name: best.p.name, kind: best.p.kind, distance_km: round(best.d, 1) } : null;
}

const score = (r) => r.area_km2 * r.mean_rise * (r.place ? 1.5 : 1) * (r.kind === 'likely_farm' ? 0.3 : 1);

/** Clustered, named and ranked regions from sampled cells. Pure. */
function rankRegions(cells, places, opts = {}) {
  const regions = clusterRegions(cells, opts);
  for (const r of regions) {
    r.place = nearestPlace(r, places, opts.placeMaxKm);
  }
  regions.sort((a, b) => score(b) - score(a) || b.area_km2 - a.area_km2);
  return regions.slice(0, MAX_REGIONS);
}

/** Box too large for one request? (each side ≤ MAX_SPAN_DEG) */
function tooLarge(bbox) {
  return bbox.east - bbox.west > MAX_SPAN_DEG + 1e-9 || bbox.north - bbox.south > MAX_SPAN_DEG + 1e-9;
}

/** Cells `[lng, lat, rise, summer baseline]` at the native step on a global 0.01° grid (stable across boxes). */
function sample(st, bbox, step = STEP) {
  const cells = [];
  for (let j = Math.ceil(bbox.south / step); j * step <= bbox.north; j++) {
    const lat = j * step;
    for (let i = Math.ceil(bbox.west / step); i * step <= bbox.east; i++) {
      const lng = i * step;
      const rise = green.greenRise(st.cur.at(lng, lat), st.bas.at(lng, lat));
      if (rise >= MIN_RISE) cells.push([lng, lat, rise, st.bas.at(lng, lat)]);
    }
  }
  return cells;
}


function within(p, ms) {
  return Promise.race([p.catch(() => null), new Promise((r) => setTimeout(() => r(null), ms).unref())]);
}

/**
 * The box actually computed: the request grown outward to a 0.5° grid, so nearby phones share one answer (and
 * the warm-up hits it). A superset of what was asked, which is fine: the app picks the nearest point itself.
 */
function snapBbox(b) {
  return {
    west: Math.floor((b.west + 1e-9) / SNAP) * SNAP,
    south: Math.floor((b.south + 1e-9) / SNAP) * SNAP,
    east: Math.ceil((b.east - 1e-9) / SNAP) * SNAP,
    north: Math.ceil((b.north - 1e-9) / SNAP) * SNAP,
  };
}
const keyOf = (s) => `${s.west},${s.south},${s.east},${s.north}`;

/* Last good answer per snapped box. Fresh for 6 h; up to 14 days old it is still served at once (flagged `stale`)
 * while a new one is built in the background, so no request waits on NASA after the first warm-up. */
const cache = new Map();
const inflight = new Map();
function remember(k, entry) {
  cache.delete(k);
  cache.set(k, entry);
  while (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value);
}

const WARMING = { ok: false, error: 'warming', retry_after_s: 30, message_ar: 'نجهّز صور الخضرة، جرّب بعد دقيقة.' };

/** Build (or join the build of) the full answer for a snapped box. `null` while NASA's pictures are not ready. */
function build(snap, { nowMs, waitMs, deps }) {
  const k = keyOf(snap);
  if (inflight.has(k)) return inflight.get(k);
  const job = (async () => {
    const st = deps.state !== undefined ? deps.state : await within(green.state(nowMs), waitMs);
    if (!st) return null;
    const places = deps.places || outdoor.loadIndex().map((f) => f.properties);
    const list = rankRegions(sample(st, snap), places);
    const body = {
      ok: true,
      layer: 'green_regions',
      is_forecast: false,
      composite_date: st.ymd,
      baseline_dates: String(st.base || '').split(',').filter(Boolean),
      source: 'NASA VIIRS NOAA-20 NDVI 8-day composite, read from NASA GIBS; place names from OpenStreetMap',
      attribution: green.ATTRIBUTION,
      place_attribution: '© OpenStreetMap contributors',
      licence: 'NASA open data (no restrictions; credit requested); place names ODbL',
      rule: { step_deg: STEP, min_rise: MIN_RISE, min_area_km2: MIN_AREA_KM2, connectivity: 8, place_max_km: PLACE_MAX_KM },
      farm_rule: { summer_ndvi_min: SUMMER_GREEN_NDVI, share_min: FARM_SHARE },
      note_ar: 'مناطق خضرة جديدة مرصودة بالأقمار الآن (ليست تنبؤًا) مقارنة بالصيف، متصلة ومساحتها ٣ كم² فأكثر. المناطق التي كانت خضراء في الصيف (غالبًا مزارع مروية) تُستبعد، وقد تبقى مزارع زُرعت في الخريف.',
      box: [snap.west, snap.south, snap.east, snap.north],
      generated_at: new Date(nowMs).toISOString(),
      regions: list,
    };
    remember(k, { at: nowMs, body });
    return body;
  })().finally(() => inflight.delete(k));
  inflight.set(k, job);
  return job;
}

/** What the phone gets: farms out unless asked for, how old the answer is. */
function view(entry, nowMs, includeFarms, stale) {
  const all = entry.body.regions;
  const regions = includeFarms ? all : all.filter((r) => r.kind !== 'likely_farm');
  return {
    ...entry.body,
    stale: !!stale,
    age_s: Math.max(0, Math.round((nowMs - entry.at) / 1000)),
    farms_excluded: all.length - regions.length,
    regions,
  };
}

/** `deps` (tests): { state, places }. Never throws; `{ok:false,error:'warming'}` while NASA's pictures load. */
async function regions({ bbox, nowMs = Date.now(), waitMs = 8_000, includeFarms = false, deps = {} }) {
  const snap = snapBbox(bbox);
  const k = keyOf(snap);
  const hit = cache.get(k);
  if (hit && nowMs - hit.at < FRESH_MS) return view(hit, nowMs, includeFarms, false);
  if (hit && nowMs - hit.at < STALE_MAX_MS) {
    build(snap, { nowMs, waitMs: 60_000, deps }).catch(() => {});
    return view(hit, nowMs, includeFarms, true);
  }
  let body = null;
  try {
    body = await build(snap, { nowMs, waitMs, deps });
  } catch {
    body = null;
  }
  if (!body) return { ...WARMING };
  return view({ at: nowMs, body }, nowMs, includeFarms, false);
}

/* Key cells, so the compass never starts cold: Qassim (Unaizah, Buraydah, Ar Rass), Riyadh, Hail, Medina, Dammam. */
const WARM_CELLS = (process.env.GREEN_REGIONS_WARM_CELLS
  ? process.env.GREEN_REGIONS_WARM_CELLS.split(';').map((c) => c.split(',').map(Number)).filter((c) => c.length === 2 && c.every(Number.isFinite))
  : [[26.08, 43.99], [26.33, 43.97], [25.87, 43.5], [24.71, 46.68], [27.52, 41.7], [24.5, 39.6], [26.4, 50.1]]);
let warming = false;
async function warmRegions(nowMs = Date.now(), cells = WARM_CELLS, deps = {}) {
  if (warming) return { skipped: 'already_running' };
  warming = true;
  const out = { cells: cells.length, ok: 0, failed: 0 };
  try {
    for (const [lat, lng] of cells) {
      const snap = snapBbox({ west: lng - 1.5, south: lat - 1.5, east: lng + 1.5, north: lat + 1.5 });
      const hit = cache.get(keyOf(snap));
      if (hit && nowMs - hit.at < FRESH_MS / 2) {
        out.ok++;
        continue;
      }
      try {
        const b = await build(snap, { nowMs, waitMs: 60_000, deps });
        if (b) out.ok++;
        else out.failed++;
      } catch {
        out.failed++;
      }
    }
    if (!process.env.NODE_TEST_CONTEXT) console.log(`[green] regions warm ${JSON.stringify(out)}`);
    return out;
  } finally {
    warming = false;
  }
}

/** Tests only: forget every cached answer. */
function _reset() {
  cache.clear();
  inflight.clear();
}

module.exports = {
  STEP, MIN_RISE, MIN_AREA_KM2, MAX_SPAN_DEG, MAX_POINTS, MAX_REGIONS, PLACE_MAX_KM, LEVELS,
  SUMMER_GREEN_NDVI, FARM_SHARE, FARM_LABEL_AR, WARM_CELLS, FRESH_MS, STALE_MAX_MS,
  levelOf, cellAreaKm2, clusterRegions, usablePlace, nearestPlace, rankRegions, tooLarge, sample,
  snapBbox, regions, warmRegions, _reset,
};
