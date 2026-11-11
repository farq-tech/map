'use strict';

/**
 * «السحاب يمشي وين؟» — for one point: how fast and where the cloud moves, and when dense cloud
 * would reach it, from two licence-allowed MTG frames (the newest and one ~60 min older) fetched
 * as a small window centred on the point. The maths lives in cloud-motion.js (pure, tested).
 *
 * Honesty: the newest allowed picture is itself ≥ 1 h old (or the newest on-the-hour one), so every
 * time here is counted from the picture and reduced by its age; weak confidence returns
 * state `uncertain` with no numbers.
 */

const { PNG } = require('pngjs');
const { fetchBuffer, Lru, memo } = require('./fetcher');
const clouds = require('./clouds');
const motion = require('./cloud-motion');

const WINDOW_KM = 640;
const WINDOW_PX = 256; // 2.5 km per pixel; the IR image is ~2–3 km over KSA
const MAX_SPEED_KMH = 100;
/* Frames 30 min apart: clouds still correlate, and the 10-min frames older than 1 h are free. */
const MIN_DT_MIN = 20;
const TARGET_DT_MIN = 30;
const MIN_CONFIDENCE = 0.45;
const R = 6378137;

const cache = new Lru(Number(process.env.WEATHER_OUTLOOK_CACHE) || 40);
const inflight = new Map();
/* Last good window per 1° cell: served (with its true, older age) while a fresh one is being read. */
const lastGood = new Lru(Number(process.env.WEATHER_OUTLOOK_STALE_CACHE) || 40); // ~1.5 MiB a window: bounded
const STALE_MAX_MIN = 35;

function toMercator(lat, lng) {
  const x = (R * lng * Math.PI) / 180;
  const y = R * Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360));
  return [x, y];
}

/**
 * The frames to compare: the newest allowed (N), and those nearest 30 and 60 min before it (±10).
 * N-30 is the main pair; N-60 only cross-checks it, so it may be missing.
 */
function pickFrames(frames) {
  if (!frames || frames.length < 2) return null;
  const newer = frames[frames.length - 1];
  const tN = Date.parse(newer.time);
  const near = (target) => {
    let best = null;
    for (const f of frames) {
      const dt = (tN - Date.parse(f.time)) / 60000;
      if (Math.abs(dt - target) > 10) continue;
      if (!best || Math.abs(dt - target) < Math.abs((tN - Date.parse(best.time)) / 60000 - target)) best = f;
    }
    return best;
  };
  const older = near(TARGET_DT_MIN);
  if (!older) return null;
  const oldest = near(2 * TARGET_DT_MIN);
  const dt = (f) => (tN - Date.parse(f.time)) / 60000;
  return { newer, older, oldest, dtMin: dt(older), dt2Min: oldest ? (Date.parse(older.time) - Date.parse(oldest.time)) / 60000 : null };
}

/** WMS image → { gray, opacity } fields (0..1), or null when the picture is blank (EUMETView sometimes sends one). */
function fieldsFromPng(buf) {
  const src = PNG.sync.read(buf);
  const n = src.width * src.height;
  let alpha = 0;
  for (let i = 0; i < n; i++) alpha += src.data[i * 4 + 3];
  if (alpha / n < 50) return null;
  const rgba = clouds.irToOverlay(src.data);
  const gray = new Float32Array(n);
  const opacity = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    gray[i] = ((src.data[i * 4] + src.data[i * 4 + 1] + src.data[i * 4 + 2]) / 3 / 255) * (src.data[i * 4 + 3] ? 1 : 0);
    opacity[i] = rgba[i * 4 + 3] / 255;
  }
  return { gray: { w: src.width, h: src.height, data: gray }, opacity: { w: src.width, h: src.height, data: opacity } };
}

async function loadFields(box, tMs) {
  const url = clouds.wmsMapUrl(box, WINDOW_PX, WINDOW_PX, tMs);
  /* EUMETView answers 504 or a blank picture now and then: retry twice. */
  for (let k = 0; k < 3; k++) {
    try {
      const r = await fetchBuffer(url, { timeoutMs: 60_000 });
      if (r.status === 200 && /png/.test(r.type)) {
        const f = fieldsFromPng(r.body);
        if (f) return f;
      }
    } catch {
      /* timeout / reset: try again */
    }
  }
  return null;
}

/**
 * Pure glue: frames → motion (+ cross-check) and the verdict for the point at pixel (px, py).
 * `grays`: { older, newer, oldest? } brightness fields; `opacityNewer`: dense-cloud field of the newest.
 */
function motionOf(grays, dtMin, dt2Min, pxKm) {
  const opts = { maxSpeedKmh: MAX_SPEED_KMH, maxShift: Math.floor((WINDOW_PX - 100) / 2) };
  const mv = motion.estimateMotion(grays.older, grays.newer, dtMin, pxKm, opts);
  let check = null;
  let cons = null;
  if (grays.oldest && dt2Min) {
    check = motion.estimateMotion(grays.oldest, grays.older, dt2Min, pxKm, opts);
    cons = motion.consistency(mv, check);
  }
  const m2 = mv.ok && cons != null ? { ...mv, confidence: Math.min(mv.confidence, 0.15 + 0.85 * cons) } : mv;
  return { motion: m2, check, consistency: cons };
}

/**
 * Pure glue: frames → motion (+ cross-check) and the verdict for the point at pixel (px, py).
 * `grays`: { older, newer, oldest? } brightness fields; `opacityNewer`: dense-cloud field of the newest.
 * `precomputed` (the window's motion, computed once and kept with the window) skips the heavy matching.
 */
function analyse({ grays, opacityNewer, dtMin, dt2Min, pxKm, ageMin, px, py, precomputed }) {
  const m = precomputed || motionOf(grays, dtMin, dt2Min, pxKm);
  const o = motion.outlookForPoint(opacityNewer, px, py, m.motion, pxKm, ageMin, { minConfidence: MIN_CONFIDENCE });
  return { motion: m.motion, check: m.check, consistency: m.consistency, outlook: o };
}

/** Window centre = the 1° cell centre, so every point of a cell shares one fetch. */
function cellOf(lat, lng) {
  return { lat: Math.round(lat), lng: Math.round(lng) };
}

async function outlook(lat, lng, nowMs = Date.now()) {
  const latest = await clouds.latestImageTime(nowMs);
  const sel = pickFrames(clouds.planFrames(latest, nowMs));
  if (!sel) return { ok: false, error: 'not_enough_frames' };
  const cell = cellOf(lat, lng);
  const key = `${sel.newer.id}/${sel.older.id}/${sel.oldest ? sel.oldest.id : '-'}/${cell.lat}/${cell.lng}`;
  const load = () => memo(cache, inflight, key, async () => {
    const [cx, cy] = toMercator(cell.lat, cell.lng);
    const half = (WINDOW_KM * 1000) / Math.cos((cell.lat * Math.PI) / 180) / 2;
    const box = [cx - half, cy - half, cx + half, cy + half];
    const ts = [sel.newer, sel.older, sel.oldest].filter(Boolean);
    const got = [];
    for (const f of ts) got.push(await loadFields(box, Date.parse(f.time))); // one at a time: EUMETView is slow and fragile
    if (!got[0] || !got[1]) return null;
    const w = { box, newer: got[0], older: got[1], oldest: got[2] || null, sel };
    lastGood.set(`${cell.lat}/${cell.lng}`, w);
    return w;
  });
  let win = cache.get(key);
  if (!win) {
    const prev = lastGood.get(`${cell.lat}/${cell.lng}`);
    if (prev && (nowMs - Date.parse(prev.sel.newer.time)) / 60000 <= STALE_MAX_MIN + 70) {
      load().catch(() => {}); // refresh in the background
      win = prev;
    } else {
      win = await load();
    }
  }
  if (!win) return { ok: false, error: 'upstream_unavailable' };
  const [x, y] = toMercator(lat, lng);
  const px = ((x - win.box[0]) / (win.box[2] - win.box[0])) * (WINDOW_PX - 1);
  const py = ((win.box[3] - y) / (win.box[3] - win.box[1])) * (WINDOW_PX - 1);
  const pxKm = WINDOW_KM / WINDOW_PX;
  /* The frames may have taken minutes to load: age counts from now, not from the request's start. */
  const nowAfter = Math.max(nowMs, Date.now());
  const ageMin = Math.max(0, (nowAfter - Date.parse(win.sel.newer.time)) / 60000);
  const grays = { newer: win.newer.gray, older: win.older.gray, oldest: win.oldest ? win.oldest.gray : null };
  /* The matching is the expensive part (~0.3 s): once per window, then every point in the cell reuses it. */
  if (!win.motionResult) win.motionResult = motionOf(grays, win.sel.dtMin, win.sel.dt2Min, pxKm);
  const a = analyse({
    grays, opacityNewer: win.newer.opacity, dtMin: win.sel.dtMin, dt2Min: win.sel.dt2Min, pxKm, ageMin, px, py,
    precomputed: win.motionResult,
  });
  const mv = a.motion;
  const o = a.outlook;
  const year = new Date(nowMs).getUTCFullYear();
  return {
    ok: true,
    layer: 'clouds_outlook',
    point: { lat, lng },
    state: o.state,
    confidence: Math.round((mv.confidence || 0) * 100) / 100,
    min_confidence: MIN_CONFIDENCE,
    motion: mv.ok && o.state !== 'uncertain'
      ? {
        bearing_deg: mv.bearingDeg == null ? null : Math.round(mv.bearingDeg),
        speed_kmh: Math.round(mv.speedKmh),
        direction_ar: mv.bearingDeg == null ? null : motion.directionAr(mv.bearingDeg),
      }
      : null,
    eta_minutes: o.etaMin ?? null,
    clearing_minutes: o.clearingInMin ?? null,
    margin_minutes: o.marginMin ?? null,
    distance_km: o.distanceKm == null ? null : Math.round(o.distanceKm),
    scanned_km: o.scannedKm ?? null,
    image_time: win.sel.newer.time,
    image_age_min: Math.round(ageMin),
    compared_with: [win.sel.older.time, win.sel.oldest ? win.sel.oldest.time : null].filter(Boolean),
    dt_minutes: Math.round(win.sel.dtMin),
    cross_check: a.consistency == null ? null : Math.round(a.consistency * 100) / 100,
    method: 'NCC block matching on MTG FCI IR frames 30 min apart, cross-checked on the pair before; linear advection assumed',
    caveats_ar: 'تقدير من حركة السحاب فقط بين صور متأخرة؛ ما يتنبأ بالمطر، والسحب قد تتكوّن أو تتبدد.',
    attribution: clouds.attribution(year),
    generated_at: new Date(nowMs).toISOString(),
  };
}

module.exports = { pickFrames, analyse, fieldsFromPng, toMercator, cellOf, outlook, WINDOW_KM, WINDOW_PX, MIN_CONFIDENCE };
