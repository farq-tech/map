'use strict';

/**
 * Cloud motion from two consecutive satellite frames, and "when does cloud reach this point".
 * Pure functions (no network, no globals) so they are tested on synthetic frames of known motion.
 *
 * A *field* is { w, h, data: Float32Array(w*h) } holding cloud opacity 0..1 (0 = clear ground,
 * 1 = dense cold cloud top), row 0 = north. `pxKm` is the ground size of one pixel.
 *
 * Method: normalised cross-correlation (NCC) of a central window of the older frame against the
 * newer frame over a range of integer shifts, then a parabolic fit around the best shift for the
 * sub-pixel part. Pure advection is assumed; clouds that grow or decay, rotate, or move at several
 * speeds at different heights lower the peak, and the confidence says so.
 */

const clamp01 = (v) => (v <= 0 ? 0 : v >= 1 ? 1 : v);
const rad = (d) => (d * Math.PI) / 180;

/** Compass bearing 0..360 (clockwise from north) of a screen-space vector (dx east+, dy south+). */
function bearingOf(dx, dy) {
  const b = (Math.atan2(dx, -dy) * 180) / Math.PI;
  return (b + 360) % 360;
}

/** Smallest absolute angle between two bearings, 0..180. */
function angleDiff(a, b) {
  const d = Math.abs(((a - b) % 360 + 540) % 360 - 180);
  return d;
}

/** Mean and standard deviation of a window. */
function windowStats(f, x0, y0, tw, th) {
  let s = 0;
  let s2 = 0;
  for (let y = 0; y < th; y++) {
    const row = (y0 + y) * f.w + x0;
    for (let x = 0; x < tw; x++) {
      const v = f.data[row + x];
      s += v;
      s2 += v * v;
    }
  }
  const n = tw * th;
  const mean = s / n;
  return { mean, std: Math.sqrt(Math.max(0, s2 / n - mean * mean)) };
}

/**
 * NCC surface over shifts in [-maxShift, +maxShift]². The template is the central
 * (w - 2*maxShift)² window of `a`; the candidate is the same window of `b` displaced by (sx, sy).
 * Returns { surface: Float32Array((2m+1)²), size, template stats } or null when the window is flat.
 */
function nccSurface(a, b, maxShift, minStd) {
  const tw = a.w - 2 * maxShift;
  const th = a.h - 2 * maxShift;
  if (tw < 8 || th < 8 || a.w !== b.w || a.h !== b.h) return null;
  const t = windowStats(a, maxShift, maxShift, tw, th);
  if (t.std < minStd) return { flat: true, template: t };
  const n = tw * th;
  const tz = new Float32Array(n);
  for (let y = 0; y < th; y++) {
    for (let x = 0; x < tw; x++) tz[y * tw + x] = a.data[(maxShift + y) * a.w + maxShift + x] - t.mean;
  }
  const size = 2 * maxShift + 1;
  const surface = new Float32Array(size * size);
  const tNorm = t.std * Math.sqrt(n);
  for (let sy = -maxShift; sy <= maxShift; sy++) {
    for (let sx = -maxShift; sx <= maxShift; sx++) {
      let s = 0;
      let s2 = 0;
      let sp = 0;
      for (let y = 0; y < th; y++) {
        const row = (maxShift + y + sy) * b.w + maxShift + sx;
        const trow = y * tw;
        for (let x = 0; x < tw; x++) {
          const v = b.data[row + x];
          s += v;
          s2 += v * v;
          sp += tz[trow + x] * v;
        }
      }
      const mean = s / n;
      const varB = s2 - n * mean * mean;
      const r = varB > 1e-9 ? sp / (tNorm * Math.sqrt(varB)) : 0;
      surface[(sy + maxShift) * size + sx + maxShift] = r;
    }
  }
  return { surface, size, template: t, flat: false };
}

/**
 * Estimate the motion between `older` and `newer` (`dtMin` minutes apart).
 * Result: { ok, reason, dx, dy (px, to where the pattern moved), speedKmh, bearingDeg, confidence 0..1,
 *           peak, distinct, texture, stationary }.
 * `ok:false` with a reason ('no_data' | 'flat' | 'edge' | 'bad_dt') when nothing trustworthy comes out.
 */
function estimateMotion(older, newer, dtMin, pxKm, opts = {}) {
  const { maxSpeedKmh = 140, minStd = 0.04, stationaryKmh = 4 } = opts;
  if (!older || !newer || !(dtMin > 0) || !(pxKm > 0)) return { ok: false, reason: 'bad_dt', confidence: 0 };
  const maxShift = Math.max(2, Math.min(opts.maxShift || 1e9, Math.floor((maxSpeedKmh * dtMin / 60) / pxKm)));
  const s = nccSurface(older, newer, maxShift, minStd);
  if (!s) return { ok: false, reason: 'no_data', confidence: 0 };
  if (s.flat) return { ok: false, reason: 'flat', confidence: 0, texture: s.template.std };

  const { surface, size } = s;
  let best = -2;
  let bi = 0;
  for (let i = 0; i < surface.length; i++) {
    if (surface[i] > best) {
      best = surface[i];
      bi = i;
    }
  }
  const bx = bi % size;
  const by = Math.floor(bi / size);
  /* A peak on the search border means the true shift is probably larger than we can see. */
  if (bx === 0 || by === 0 || bx === size - 1 || by === size - 1) {
    return { ok: false, reason: 'edge', confidence: 0, peak: best };
  }
  const at = (x, y) => surface[y * size + x];
  const fit = (l, c, r) => {
    const d = l - 2 * c + r;
    return Math.abs(d) < 1e-9 ? 0 : Math.max(-0.5, Math.min(0.5, (0.5 * (l - r)) / d));
  };
  const dx = bx - maxShift + fit(at(bx - 1, by), best, at(bx + 1, by));
  const dy = by - maxShift + fit(at(bx, by - 1), best, at(bx, by + 1));

  /* Runner-up: best value outside a 6-px disc around the peak. */
  let second = -2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if ((x - bx) ** 2 + (y - by) ** 2 <= 36) continue;
      if (surface[y * size + x] > second) second = surface[y * size + x];
    }
  }
  /* And how well "no motion" explains the pair: a stationary scene correlates at shift 0. */
  const zero = at(maxShift, maxShift);

  const peakScore = clamp01((best - 0.35) / 0.5);
  const distinct = clamp01((best - Math.max(second, -1)) / 0.12);
  const texture = clamp01(s.template.std / 0.12);
  const confidence = Math.min(peakScore, distinct, texture);

  const shiftPx = Math.hypot(dx, dy);
  const speedKmh = (shiftPx * pxKm) / (dtMin / 60);
  const stationary = speedKmh < stationaryKmh;
  return {
    ok: true,
    dx,
    dy,
    speedKmh,
    bearingDeg: stationary ? null : bearingOf(dx, dy),
    confidence,
    peak: best,
    zeroShiftCorrelation: zero,
    distinct,
    texture,
    stationary,
  };
}

/** Mean opacity of a (2r+1)² patch around (cx, cy), edge-clamped. */
function patchMean(f, cx, cy, r = 2) {
  let s = 0;
  let n = 0;
  for (let y = Math.max(0, Math.round(cy) - r); y <= Math.min(f.h - 1, Math.round(cy) + r); y++) {
    for (let x = Math.max(0, Math.round(cx) - r); x <= Math.min(f.w - 1, Math.round(cx) + r); x++) {
      s += f.data[y * f.w + x];
      n++;
    }
  }
  return n ? s / n : 0;
}

/**
 * Where is cloud relative to (cx, cy) along the motion axis, in the *newer* frame?
 * Marches upwind (against the motion) for the first dense patch, and downwind for the first clear one.
 * Distances in km, or null when not found within `horizonKm` / inside the frame.
 */
function scanAlongMotion(newer, cx, cy, motion, pxKm, { dense = 0.45, clear = 0.2, horizonKm = 300 } = {}) {
  const len = Math.hypot(motion.dx, motion.dy);
  if (!len) return { here: patchMean(newer, cx, cy), upwindKm: null, downwindKm: null };
  const ux = motion.dx / len;
  const uy = motion.dy / len;
  const here = patchMean(newer, cx, cy);
  const maxSteps = Math.floor(horizonKm / pxKm);
  let upwindKm = null;
  for (let i = 1; i <= maxSteps; i++) {
    const x = cx - ux * i;
    const y = cy - uy * i;
    if (x < 0 || y < 0 || x > newer.w - 1 || y > newer.h - 1) break;
    if (patchMean(newer, x, y) >= dense) {
      upwindKm = i * pxKm;
      break;
    }
  }
  let downwindKm = null;
  for (let i = 1; i <= maxSteps; i++) {
    const x = cx + ux * i;
    const y = cy + uy * i;
    if (x < 0 || y < 0 || x > newer.w - 1 || y > newer.h - 1) break;
    if (patchMean(newer, x, y) <= clear) {
      downwindKm = i * pxKm;
      break;
    }
  }
  return { here, upwindKm, downwindKm };
}

/** ± margin (minutes) around an arrival estimate: grows with weak confidence and with distance. */
function marginMinutes(etaImageMin, confidence) {
  const rel = 0.15 + 0.35 * (1 - clamp01(confidence));
  return Math.round(15 + etaImageMin * rel);
}

/**
 * The verdict for one point. `ageMin` is how old the *newer* frame already is: the estimate counts
 * from the moment of the picture, so the time left is reduced by that age.
 *
 * state: 'uncertain' | 'stationary' | 'overhead' | 'approaching' | 'arrived' | 'clear'
 * Numbers are only present for the states that can honestly carry them.
 */
function outlookForPoint(newer, cx, cy, motion, pxKm, ageMin, opts = {}) {
  const { minConfidence = 0.45, horizonMin = 360 } = opts;
  const base = { ageMin, confidence: motion && motion.confidence ? motion.confidence : 0 };
  if (!motion || !motion.ok || motion.confidence < minConfidence) return { ...base, state: 'uncertain' };
  const scan = scanAlongMotion(newer, cx, cy, motion, pxKm, opts);
  const common = {
    ...base,
    speedKmh: motion.speedKmh,
    bearingDeg: motion.bearingDeg,
    hereOpacity: scan.here,
  };
  if (motion.stationary) return { ...common, state: 'stationary' };
  if (scan.here >= (opts.dense || 0.45)) {
    const clearImg = scan.downwindKm != null ? (scan.downwindKm / motion.speedKmh) * 60 : null;
    const clearNow = clearImg != null ? clearImg - ageMin : null;
    return {
      ...common,
      state: 'overhead',
      clearingInMin: clearNow != null && clearNow > 0 ? Math.round(clearNow) : null,
      marginMin: clearImg != null ? marginMinutes(clearImg, motion.confidence) : null,
    };
  }
  if (scan.upwindKm == null) return { ...common, state: 'clear', horizonKm: opts.horizonKm || 300 };
  const etaImg = (scan.upwindKm / motion.speedKmh) * 60;
  const etaNow = etaImg - ageMin;
  const margin = marginMinutes(etaImg, motion.confidence);
  if (etaNow <= 0) return { ...common, state: 'arrived', distanceKm: scan.upwindKm, marginMin: margin };
  if (etaNow > horizonMin) return { ...common, state: 'clear', horizonKm: opts.horizonKm || 300 };
  return { ...common, state: 'approaching', etaMin: Math.round(etaNow), marginMin: margin, distanceKm: scan.upwindKm };
}

/** Arabic compass word for "moving toward" a bearing: «شرقًا», «شمال شرقي»… */
function directionAr(bearing) {
  const names = ['شمالًا', 'شمال شرقي', 'شرقًا', 'جنوب شرقي', 'جنوبًا', 'جنوب غربي', 'غربًا', 'شمال غربي'];
  return names[Math.round((((bearing % 360) + 360) % 360) / 45) % 8];
}

module.exports = {
  bearingOf, angleDiff, estimateMotion, scanAlongMotion, outlookForPoint, marginMinutes, directionAr, patchMean,
};
