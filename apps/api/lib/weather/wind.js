'use strict';

/**
 * «اتجاه الرياح» — wind over the Kingdom as a coarse grid (1.5°) of the ECMWF HRES forecast for
 * the current hour, read point by point from MET Norway's Locationforecast (free, no key, CC BY 4.0
 * + NLOD 2.0, commercial use allowed with credit and an identifying User-Agent; docs/weather-sources.md §٤).
 *
 * Honesty: this is a MODEL forecast for the current hour, not a measurement and not "live"; the
 * grid is ~150 km, so local wind (wadis, sea breeze, thunderstorm outflow) is not shown. Everything
 * carries the model's own age.
 *
 * Pure parts (parse, u/v, bilinear, streamlines) are tested without a network.
 */

const { fetchBuffer, limiter } = require('./fetcher');
const { KSA, inKsa } = require('./mercator');

const STEP = 1.5;
const LAT0 = 15;
const LAT1 = 33;
const LNG0 = 34;
const LNG1 = 56.5;
const NLAT = Math.round((LAT1 - LAT0) / STEP) + 1;
const NLNG = Math.round((LNG1 - LNG0) / STEP) + 1;
const REFRESH_MS = 60 * 60_000;
const MIN_COVER = 0.9;
const ATTRIBUTION = 'Data from MET Norway (ECMWF HRES), CC BY 4.0';
const BASE = process.env.MET_LOCATIONFORECAST_URL || 'https://api.met.no/weatherapi/locationforecast/2.0/compact';

const rad = (d) => (d * Math.PI) / 180;

/** Meteorological "from" direction (deg) + speed (m/s) → eastward/northward components of the air's motion. */
function toUV(speed, fromDeg) {
  return { u: -speed * Math.sin(rad(fromDeg)), v: -speed * Math.cos(rad(fromDeg)) };
}

/** Components → { speed, fromDeg (0..360, where it blows FROM), toDeg }. */
function fromUV(u, v) {
  const speed = Math.hypot(u, v);
  const to = ((Math.atan2(u, v) * 180) / Math.PI + 360) % 360;
  return { speed, toDeg: to, fromDeg: (to + 180) % 360 };
}

/**
 * Locationforecast compact JSON → the entry nearest to `nowMs`:
 * { u, v, speed, fromDeg, validTime, updatedAt } or null.
 */
function parseForecast(json, nowMs) {
  const ts = json && json.properties && json.properties.timeseries;
  if (!Array.isArray(ts) || !ts.length) return null;
  let best = null;
  let bestD = Infinity;
  for (const e of ts) {
    const d = e && e.data && e.data.instant && e.data.instant.details;
    if (!d || !Number.isFinite(d.wind_speed) || !Number.isFinite(d.wind_from_direction)) continue;
    const dt = Math.abs(Date.parse(e.time) - nowMs);
    if (dt < bestD) {
      bestD = dt;
      best = { e, d };
    }
  }
  if (!best || bestD > 3 * 3600_000) return null;
  const { u, v } = toUV(best.d.wind_speed, best.d.wind_from_direction);
  const meta = json.properties.meta || {};
  return {
    u,
    v,
    speed: best.d.wind_speed,
    fromDeg: best.d.wind_from_direction,
    validTime: best.e.time,
    updatedAt: meta.updated_at || null,
  };
}

/* ---------- the grid ---------- */

function makeGrid() {
  const n = NLAT * NLNG;
  return { u: new Float32Array(n).fill(NaN), v: new Float32Array(n).fill(NaN), ok: 0, validTime: null, updatedAt: null, fetchedAt: 0 };
}
const idx = (i, j) => j * NLNG + i; // i = column (lng), j = row (lat, south→north)
const cellLat = (j) => LAT0 + j * STEP;
const cellLng = (i) => LNG0 + i * STEP;

/** Bilinear { u, v } at a point (cells with no data are skipped); null outside the grid or with no data near. */
function sampleGrid(grid, lng, lat) {
  const fx = (lng - LNG0) / STEP;
  const fy = (lat - LAT0) / STEP;
  if (fx < 0 || fy < 0 || fx > NLNG - 1 || fy > NLAT - 1) return null;
  const i0 = Math.min(NLNG - 2, Math.floor(fx));
  const j0 = Math.min(NLAT - 2, Math.floor(fy));
  const ax = fx - i0;
  const ay = fy - j0;
  let su = 0;
  let sv = 0;
  let sw = 0;
  for (const [di, dj, w] of [[0, 0, (1 - ax) * (1 - ay)], [1, 0, ax * (1 - ay)], [0, 1, (1 - ax) * ay], [1, 1, ax * ay]]) {
    const k = idx(i0 + di, j0 + dj);
    if (w > 0 && Number.isFinite(grid.u[k])) {
      su += grid.u[k] * w;
      sv += grid.v[k] * w;
      sw += w;
    }
  }
  return sw > 0.25 ? { u: su / sw, v: sv / sw } : null;
}

/* ---------- streamlines ---------- */

/** Cheap deterministic jitter in [0,1) so the seeds do not line up in rows. */
function jitter(a, b) {
  const s = Math.sin(a * 127.1 + b * 311.7) * 43758.5453;
  return s - Math.floor(s);
}

/**
 * Streamlines of `grid` as GeoJSON. Each line follows the current field for `hours` (the distance
 * the air would cover at the current speed, so length ∝ speed) with an arrowhead at the end.
 * RK2 steps of `dtMin` minutes. Seeds every `seedDeg`° inside the Kingdom; calm cells (< minSpeed) get no line.
 */
function streamlines(grid, { seedDeg = 1, hours = 6, dtMin = 20, minSpeed = 1, bbox = KSA } = {}) {
  const features = [];
  const dt = dtMin * 60;
  const steps = Math.round((hours * 60) / dtMin);
  const mPerDegLat = 111320;
  const advance = (lng, lat, u, v, h) => [lng + (u * h) / (mPerDegLat * Math.cos(rad(lat))), lat + (v * h) / mPerDegLat];
  let n = 0;
  for (let lat = bbox.south + 0.5; lat <= bbox.north; lat += seedDeg) {
    for (let lng = bbox.west + 0.5; lng <= bbox.east; lng += seedDeg) {
      n++;
      const sLng = lng + (jitter(lat, lng) - 0.5) * seedDeg * 0.8;
      const sLat = lat + (jitter(lng, lat) - 0.5) * seedDeg * 0.8;
      if (!inKsa(sLng, sLat)) continue;
      const first = sampleGrid(grid, sLng, sLat);
      if (!first || Math.hypot(first.u, first.v) < minSpeed) continue;
      const pts = [[sLng, sLat]];
      let p = [sLng, sLat];
      let speedSum = 0;
      for (let s = 0; s < steps; s++) {
        const a = sampleGrid(grid, p[0], p[1]);
        if (!a) break;
        const mid = advance(p[0], p[1], a.u, a.v, dt / 2);
        const b = sampleGrid(grid, mid[0], mid[1]) || a;
        p = advance(p[0], p[1], b.u, b.v, dt);
        speedSum += Math.hypot(b.u, b.v);
        pts.push(p);
      }
      if (pts.length < 3) continue;
      const tip = pts[pts.length - 1];
      const prev = pts[pts.length - 2];
      /* Arrowhead: two barbs ~14 km long, ±28° off the way back. */
      const kmLng = 111.32 * Math.cos(rad(tip[1]));
      const dir = Math.atan2((prev[0] - tip[0]) * kmLng, (prev[1] - tip[1]) * 111.32);
      const barb = (da) => [tip[0] + (Math.sin(dir + da) * 14) / kmLng, tip[1] + (Math.cos(dir + da) * 14) / 111.32];
      const speed = speedSum / (pts.length - 1);
      const r3 = (c) => [Math.round(c[0] * 1000) / 1000, Math.round(c[1] * 1000) / 1000];
      features.push({
        type: 'Feature',
        properties: { speed_ms: Math.round(speed * 10) / 10, speed_kmh: Math.round(speed * 3.6) },
        geometry: { type: 'MultiLineString', coordinates: [pts.map(r3), [r3(barb(rad(28))), r3(tip), r3(barb(-rad(28)))]] },
      });
    }
  }
  return { type: 'FeatureCollection', features, seeds: n };
}

/* ---------- fetching ---------- */

function userAgent() {
  const contact = process.env.WEATHER_CONTACT ? ` ${process.env.WEATHER_CONTACT}` : '';
  return `SaryAlbarq-API/1.0 (+https://github.com/farq-tech/map)${contact}`;
}

async function fetchPoint(lat, lng, nowMs) {
  /* MET: at most 4 decimals, identifying User-Agent, gzip handled by fetch. */
  const url = `${BASE}?lat=${lat.toFixed(4)}&lon=${lng.toFixed(4)}`;
  const r = await fetchBuffer(url, { timeoutMs: 20_000, headers: { 'user-agent': userAgent() } });
  if (r.status === 429 || r.status === 403) {
    const e = new Error(`met_${r.status}`);
    e.throttled = true;
    throw e;
  }
  if (r.status !== 200) return null;
  return parseForecast(JSON.parse(r.body.toString('utf8')), nowMs);
}

let grid = null;
let refreshing = null;
let lastFailAt = 0;
/* Few at a time and a little apart: MET asks for a flat traffic curve, not bursts. */
const gate = limiter(3);

async function refreshGrid(nowMs) {
  const g = makeGrid();
  let throttled = false;
  const jobs = [];
  for (let j = 0; j < NLAT; j++) {
    for (let i = 0; i < NLNG; i++) {
      jobs.push(gate(async () => {
        if (throttled) return;
        try {
          const f = await fetchPoint(cellLat(j), cellLng(i), nowMs);
          if (!f) return;
          const k = idx(i, j);
          g.u[k] = f.u;
          g.v[k] = f.v;
          g.ok++;
          if (!g.validTime || f.validTime < g.validTime) g.validTime = f.validTime;
          if (f.updatedAt && (!g.updatedAt || f.updatedAt < g.updatedAt)) g.updatedAt = f.updatedAt;
        } catch (e) {
          if (e.throttled) throttled = true;
        }
      }));
    }
  }
  await Promise.all(jobs);
  g.fetchedAt = nowMs;
  if (g.ok / (NLAT * NLNG) < MIN_COVER) return null;
  return g;
}

/**
 * The current grid: fresh (< 60 min) or refreshed now; while a refresh runs the previous grid is
 * served with its true age. null when nothing could be read.
 */
async function currentGrid(nowMs = Date.now()) {
  if (grid && nowMs - grid.fetchedAt < REFRESH_MS) return grid;
  if (!refreshing && nowMs - lastFailAt > 5 * 60_000) {
    refreshing = refreshGrid(nowMs)
      .then((g) => {
        if (g) grid = g;
        else lastFailAt = Date.now();
        return g;
      })
      .catch(() => {
        lastFailAt = Date.now();
        return null;
      })
      .finally(() => {
        refreshing = null;
      });
  }
  if (grid) return grid; // stale but honest: the response carries model_age_min
  return refreshing ? refreshing : null;
}

const NAMES_FROM = ['شمالية', 'شمالية شرقية', 'شرقية', 'جنوبية شرقية', 'جنوبية', 'جنوبية غربية', 'غربية', 'شمالية غربية'];
const fromAr = (deg) => NAMES_FROM[Math.round((((deg % 360) + 360) % 360) / 45) % 8];

function metaOf(g, nowMs) {
  const updated = g.updatedAt ? Date.parse(g.updatedAt) : Date.parse(g.validTime);
  return {
    valid_time: g.validTime,
    model_updated_at: g.updatedAt,
    model_age_min: Math.max(0, Math.round((nowMs - updated) / 60000)),
    grid_age_min: Math.round((nowMs - g.fetchedAt) / 60000),
    grid_step_deg: STEP,
    forecast_model: true,
    source: 'MET Norway Locationforecast 2.0 (ECMWF HRES)',
    attribution: ATTRIBUTION,
    caveats_ar: 'توقّع نموذج جوي للساعة الحالية على شبكة ~١٥٠ كم، مو قياس ولا بث حي. الرياح المحلية (الأودية، نسيم البحر، العواصف) ما تظهر.',
    generated_at: new Date(nowMs).toISOString(),
  };
}

async function atPoint(lat, lng, nowMs = Date.now()) {
  const g = await currentGrid(nowMs);
  if (!g) return { ok: false, error: 'upstream_unavailable' };
  const s = sampleGrid(g, lng, lat);
  if (!s) return { ok: false, error: 'no_data' };
  const w = fromUV(s.u, s.v);
  return {
    ok: true,
    layer: 'wind',
    point: { lat, lng },
    speed_ms: Math.round(w.speed * 10) / 10,
    speed_kmh: Math.round(w.speed * 3.6),
    from_deg: Math.round(w.fromDeg),
    toward_deg: Math.round(w.toDeg),
    from_ar: fromAr(w.fromDeg),
    calm: w.speed < 0.5,
    ...metaOf(g, nowMs),
  };
}

async function lines(nowMs = Date.now()) {
  const g = await currentGrid(nowMs);
  if (!g) return { ok: false, error: 'upstream_unavailable' };
  const fc = streamlines(g);
  return {
    ok: true,
    layer: 'wind_streamlines',
    line_hours: 6,
    note_ar: 'طول الخط = المسافة اللي يقطعها الهواء في ٦ ساعات لو بقيت الريح كما هي الحين؛ السهم يبيّن وجهة الريح.',
    ...metaOf(g, nowMs),
    type: fc.type,
    features: fc.features,
  };
}

module.exports = {
  STEP, NLAT, NLNG, ATTRIBUTION,
  toUV, fromUV, parseForecast, makeGrid, idx, cellLat, cellLng, sampleGrid, streamlines, fromAr, atPoint, lines, currentGrid,
  _reset() {
    grid = null;
    refreshing = null;
    lastFailAt = 0;
  },
};
