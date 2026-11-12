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
    const [lng, lat, rise] = c;
    if (!(rise >= MIN_RISE)) continue;
    const i = Math.round(lng / step);
    const j = Math.round(lat / step);
    const key = `${i},${j}`;
    if (grid.has(key)) continue;
    grid.set(key, items.length);
    items.push({ i, j, lng, lat, rise, seen: false });
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
    const region = {
      id: `gr_${crypto.createHash('sha1').update(`${centroid[0].toFixed(2)},${centroid[1].toFixed(2)}`).digest('hex').slice(0, 10)}`,
      centroid,
      bbox: [round(w - step / 2, 4), round(s - step / 2, 4), round(e + step / 2, 4), round(n + step / 2, 4)],
      area_km2: round(area, 1),
      cells: members.length,
      mean_rise: round(meanRise, 3),
      max_rise: round(mr, 3),
      ...levelOf(meanRise),
      points: pick.map((m) => [round(m.lng, 4), round(m.lat, 4)]),
    };
    /* All cells, for nearestPlace; hidden from JSON. */
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

const score = (r) => r.area_km2 * r.mean_rise * (r.place ? 1.5 : 1);

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

/** Cells `[lng, lat, rise]` at the native step on a global 0.01° grid (stable across boxes). */
function sample(st, bbox, step = STEP) {
  const cells = [];
  for (let j = Math.ceil(bbox.south / step); j * step <= bbox.north; j++) {
    const lat = j * step;
    for (let i = Math.ceil(bbox.west / step); i * step <= bbox.east; i++) {
      const lng = i * step;
      const rise = green.greenRise(st.cur.at(lng, lat), st.bas.at(lng, lat));
      if (rise >= MIN_RISE) cells.push([lng, lat, rise]);
    }
  }
  return cells;
}

function within(p, ms) {
  return Promise.race([p.catch(() => null), new Promise((r) => setTimeout(() => r(null), ms).unref())]);
}

/** `deps` (tests): { state, places }. */
async function regions({ bbox, nowMs = Date.now(), waitMs = 25_000, deps = {} }) {
  const st = deps.state !== undefined ? deps.state : await within(green.state(nowMs), waitMs);
  if (!st) return { ok: false, error: 'warming', message_ar: 'نجهّز صور الخضرة، جرّب بعد دقيقة.' };
  const places = deps.places || outdoor.loadIndex().map((f) => f.properties);
  const list = rankRegions(sample(st, bbox), places);
  return {
    ok: true,
    layer: 'green_regions',
    composite_date: st.ymd,
    baseline_dates: String(st.base || '').split(',').filter(Boolean),
    source: 'NASA VIIRS NOAA-20 NDVI 8-day composite, read from NASA GIBS; place names from OpenStreetMap',
    attribution: green.ATTRIBUTION,
    place_attribution: '© OpenStreetMap contributors',
    licence: 'NASA open data (no restrictions; credit requested); place names ODbL',
    rule: { step_deg: STEP, min_rise: MIN_RISE, min_area_km2: MIN_AREA_KM2, connectivity: 8, place_max_km: PLACE_MAX_KM },
    note_ar: 'مناطق خضرة جديدة مقارنة بالصيف، متصلة ومساحتها ٣ كم² فأكثر. الصورة مجمّعة كل ٨ أيام بدقة ~١ كم، وقد تظهر مزارع زُرعت في الخريف.',
    generated_at: new Date(nowMs).toISOString(),
    regions: list,
  };
}

module.exports = {
  STEP, MIN_RISE, MIN_AREA_KM2, MAX_SPAN_DEG, MAX_POINTS, MAX_REGIONS, PLACE_MAX_KM, LEVELS,
  levelOf, cellAreaKm2, clusterRegions, usablePlace, nearestPlace, rankRegions, tooLarge, sample, regions,
};
