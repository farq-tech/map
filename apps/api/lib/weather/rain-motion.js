'use strict';

/**
 * «المطر وين كان يمشي؟» — the direction and speed in which the observed rain around a point was
 * moving, from two consecutive-hour NASA GPM IMERG (Early) frames. Pure advection of the pattern
 * (cloud-motion.js `estimateMotion`), no forecast: it says where the rain WAS going when the
 * satellites last saw it, 4–7 hours ago, and nothing about what it will do.
 *
 * Honest limits, repeated in the response: IMERG fills the gaps between satellite passes by moving
 * rain along a model wind field ("morphing"), so the motion is partly the model's, not an
 * independent measurement; one pixel is ~9 km, so an hour of motion resolves ~9 km/h per pixel.
 */

const gibs = require('./gibs');
const rain = require('./rain');
const motion = require('./cloud-motion');
const { lngToX, latToY, TILE } = require('./mercator');
const { Lru, memo } = require('./fetcher');

const Z = 4;
const HALF = 48; // window = 96 px ≈ 850 km
const SIZE = HALF * 2;
const DT_MIN = 60;
const MAX_SPEED_KMH = 80;
const MIN_CONFIDENCE = 0.45;
const MIN_RAINY_PX = 12;
const CHECK_MIN_CONFIDENCE = 0.3;
const HALF_HOUR = 30 * 60_000;

const tiles = new Lru(48);
const inflight = new Map();
const results = new Lru(200);
const resInflight = new Map();

const iso = (t) => new Date(t).toISOString().replace('.000', '');

/** Ground size of one z4 pixel at a latitude. */
function pxKmAt(lat) {
  return (40075.017 * Math.cos((lat * Math.PI) / 180)) / (TILE * 2 ** Z);
}

/** mm/h → 0..1 contrast for matching (log-ish: drizzle and downpours both leave a pattern). */
function rainContrast(rate) {
  return rate > 0 ? Math.min(1, Math.log1p(rate) / Math.log1p(8)) : 0;
}

/** Window field (SIZE²) around (lng, lat) from z4 tile arrays: { w, h, data, rainyPx }. `tileAt(tx, ty)` → Float32Array | null. */
function windowField(tileAt, lng, lat) {
  const cx = Math.round(lngToX(lng, Z));
  const cy = Math.round(latToY(lat, Z));
  const data = new Float32Array(SIZE * SIZE);
  let rainy = 0;
  let missing = 0;
  for (let y = 0; y < SIZE; y++) {
    const gy = cy - HALF + y;
    for (let x = 0; x < SIZE; x++) {
      const gx = cx - HALF + x;
      const t = tileAt(Math.floor(gx / TILE), Math.floor(gy / TILE));
      if (!t) {
        missing++;
        continue;
      }
      const r = t[(gy - Math.floor(gy / TILE) * TILE) * TILE + (gx - Math.floor(gx / TILE) * TILE)];
      const c = Number.isFinite(r) ? rainContrast(r) : 0;
      data[y * SIZE + x] = c;
      if (c > 0.05) rainy++;
    }
  }
  return { w: SIZE, h: SIZE, data, rainyPx: rainy, missing };
}

/** "Rain here" at the window centre of the newer frame: max contrast within 2 px, as mm/h is not kept. */
function rainAtCentre(f) {
  let m = 0;
  for (let y = HALF - 2; y <= HALF + 2; y++) for (let x = HALF - 2; x <= HALF + 2; x++) m = Math.max(m, f.data[y * SIZE + x]);
  return m > 0.05;
}

/** Spread of the estimate: wider when the match is weak; never tighter than the pixel size allows. */
function margins(est, pxKm) {
  const c = est.confidence;
  const angle = Math.round(Math.min(90, 15 + 60 * (1 - c)));
  const floor = pxKm / (DT_MIN / 60) / 2; // half a pixel per hour
  const speed = Math.round(Math.max(floor, est.speedKmh * (0.15 + 0.4 * (1 - c))));
  return { angle, speed };
}

/**
 * Frames (older → newer, dt 60 min) + the one before for the cross-check → verdict.
 * `fields`: { f0 (newest), f1 (−60), f2 (−120, optional) }.
 */
function analyse({ f0, f1, f2 }, lat) {
  const pxKm = pxKmAt(lat);
  const opts = { maxSpeedKmh: MAX_SPEED_KMH, minStd: 0.03, stationaryKmh: pxKm / 2 };
  if (f0.rainyPx < MIN_RAINY_PX && f1.rainyPx < MIN_RAINY_PX) return { state: 'no_rain', pxKm, confidence: 0 };
  const est = motion.estimateMotion(f1, f0, DT_MIN, pxKm, opts);
  if (!est.ok) return { state: 'uncertain', pxKm, confidence: 0, reason: est.reason };
  let conf = est.confidence;
  let cons = null;
  if (f2) {
    const chk = motion.estimateMotion(f2, f1, DT_MIN, pxKm, opts);
    if (chk.ok && chk.confidence >= CHECK_MIN_CONFIDENCE) {
      /* The earlier hour is itself readable: the two must agree, or the picture is changing faster than it moves. */
      cons = motion.consistency(est, chk);
      conf = Math.min(conf, 0.15 + 0.85 * cons);
    } else {
      /* Rain that has just appeared (or an unreadable earlier hour) cannot confirm or deny: a small penalty, not a veto. */
      conf *= 0.85;
    }
  } else {
    conf *= 0.85;
  }
  const e = { ...est, confidence: conf };
  if (conf < MIN_CONFIDENCE) return { state: 'uncertain', pxKm, confidence: conf, est: e, cross_check: cons };
  return { state: e.stationary ? 'stationary' : 'moving', pxKm, confidence: conf, est: e, cross_check: cons };
}

function tileFor(timeMs, tx, ty) {
  const key = `${timeMs}/${tx}/${ty}`;
  return memo(tiles, inflight, key, async () => {
    const t = await gibs.valuesTile(rain.LAYER, iso(timeMs), rain.MATRIX, Z, tx, ty, rain.rateLookup(), { transparentValue: 0 }).catch(() => null);
    return t || undefined; // a missing tile is not cached
  });
}

async function loadField(timeMs, lng, lat) {
  const cx = Math.round(lngToX(lng, Z));
  const cy = Math.round(latToY(lat, Z));
  const xs = new Set([Math.floor((cx - HALF) / TILE), Math.floor((cx + HALF - 1) / TILE)]);
  const ys = new Set([Math.floor((cy - HALF) / TILE), Math.floor((cy + HALF - 1) / TILE)]);
  const got = new Map();
  for (const ty of ys) for (const tx of xs) got.set(`${tx}/${ty}`, await tileFor(timeMs, tx, ty));
  const f = windowField((tx, ty) => got.get(`${tx}/${ty}`) || null, lng, lat);
  return f.missing > SIZE * SIZE * 0.05 ? null : f;
}

async function motionAt(lat, lng, nowMs = Date.now()) {
  const latest = await rain.refreshLatest(nowMs);
  if (!latest) return { ok: false, error: 'upstream_unavailable' };
  const cell = { lat: Math.round(lat * 2) / 2, lng: Math.round(lng * 2) / 2 };
  const key = `${latest}/${cell.lat}/${cell.lng}`;
  const fields = await memo(results, resInflight, key, async () => {
    const f0 = await loadField(latest, cell.lng, cell.lat);
    const f1 = await loadField(latest - 2 * HALF_HOUR, cell.lng, cell.lat);
    if (!f0 || !f1) return undefined;
    const f2 = await loadField(latest - 4 * HALF_HOUR, cell.lng, cell.lat);
    return { f0, f1, f2 };
  });
  if (!fields) return { ok: false, error: 'not_enough_frames' };
  const a = analyse(fields, cell.lat);
  const ageMin = Math.max(0, Math.round((nowMs - latest) / 60000));
  const out = {
    ok: true,
    layer: 'rain_motion',
    point: { lat, lng },
    state: a.state,
    confidence: Math.round(a.confidence * 100) / 100,
    min_confidence: MIN_CONFIDENCE,
    motion: null,
    rain_at_point: rainAtCentre(fields.f0),
    image_time: iso(latest),
    image_age_min: ageMin,
    compared_with: [iso(latest - 2 * HALF_HOUR), fields.f2 ? iso(latest - 4 * HALF_HOUR) : null].filter(Boolean),
    dt_minutes: DT_MIN,
    cross_check: a.cross_check == null ? null : Math.round(a.cross_check * 100) / 100,
    window_km: Math.round(SIZE * a.pxKm),
    method: 'NCC block matching on NASA IMERG Early rain-rate frames 60 min apart, cross-checked on the pair before; linear advection assumed',
    caveats_ar: 'اتجاه حركة المطر وقت آخر صورة (متأخرة ٤–٧ ساعات)، مو توقع. بيانات IMERG نفسها تحرّك المطر بين الأقمار بنموذج رياح، فالحركة جزء منها تقدير نموذج.',
    attribution: rain.ATTRIBUTION,
    generated_at: new Date(nowMs).toISOString(),
  };
  if (a.state === 'moving') {
    const m = margins(a.est, a.pxKm);
    out.motion = {
      bearing_deg: Math.round(a.est.bearingDeg),
      speed_kmh: Math.round(a.est.speedKmh),
      direction_ar: motion.directionAr(a.est.bearingDeg),
      margin_deg: m.angle,
      margin_kmh: m.speed,
    };
  }
  return out;
}

module.exports = { pxKmAt, rainContrast, windowField, margins, analyse, motionAt, MIN_CONFIDENCE, SIZE, HALF, Z, _reset() { tiles.map.clear(); results.map.clear(); } };
