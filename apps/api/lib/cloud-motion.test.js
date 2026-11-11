'use strict';

/* Cloud motion: synthetic frames with a known displacement, no network. */

const test = require('node:test');
const assert = require('node:assert/strict');
const m = require('./weather/cloud-motion');

function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

/** A big world of soft cloud blobs, sampled bilinearly so sub-pixel shifts are exact-ish. */
function makeWorld(size, seed, { blobs = 140, cover = 1 } = {}) {
  const r = rng(seed);
  const data = new Float32Array(size * size);
  for (let i = 0; i < blobs * cover; i++) {
    const cx = r() * size;
    const cy = r() * size;
    const rad = 4 + r() * 14;
    const amp = 0.4 + r() * 0.6;
    const x0 = Math.max(0, Math.floor(cx - 3 * rad));
    const x1 = Math.min(size - 1, Math.ceil(cx + 3 * rad));
    const y0 = Math.max(0, Math.floor(cy - 3 * rad));
    const y1 = Math.min(size - 1, Math.ceil(cy + 3 * rad));
    for (let y = y0; y <= y1; y++) {
      for (let x = x0; x <= x1; x++) {
        const d2 = ((x - cx) ** 2 + (y - cy) ** 2) / (rad * rad);
        data[y * size + x] += amp * Math.exp(-d2);
      }
    }
  }
  for (let i = 0; i < data.length; i++) data[i] = Math.min(1, data[i]);
  return { w: size, h: size, data };
}

function sample(world, x, y) {
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const fx = x - x0;
  const fy = y - y0;
  const g = (xx, yy) => world.data[Math.max(0, Math.min(world.h - 1, yy)) * world.w + Math.max(0, Math.min(world.w - 1, xx))];
  return (g(x0, y0) * (1 - fx) + g(x0 + 1, y0) * fx) * (1 - fy) + (g(x0, y0 + 1) * (1 - fx) + g(x0 + 1, y0 + 1) * fx) * fy;
}

/** Frame of `n`×`n` whose top-left is world (ox, oy). */
function crop(world, n, ox, oy) {
  const data = new Float32Array(n * n);
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) data[y * n + x] = sample(world, ox + x, oy + y);
  return { w: n, h: n, data };
}

/** Older + newer frame where the cloud pattern moved by (dx, dy) px (dy>0 = south). */
function pair(world, n, dx, dy) {
  const ox = 100;
  const oy = 100;
  return [crop(world, n, ox, oy), crop(world, n, ox - dx, oy - dy)];
}

const PX_KM = 4;
const DT = 60;

test('estimateMotion: direction ±15° and speed ±20% for 8 directions × 3 speeds', () => {
  const world = makeWorld(420, 7);
  const n = 190;
  for (const kmh of [18, 40, 70]) {
    for (let bearing = 0; bearing < 360; bearing += 45) {
      const shiftPx = (kmh * (DT / 60)) / PX_KM;
      const dx = shiftPx * Math.sin(m.bearingOf(0, -1) * 0 + (bearing * Math.PI) / 180);
      const dy = -shiftPx * Math.cos((bearing * Math.PI) / 180);
      const [a, b] = pair(world, n, dx, dy);
      const r = m.estimateMotion(a, b, DT, PX_KM, { maxShift: 28 });
      assert.ok(r.ok, `${kmh}/${bearing}: ${r.reason}`);
      assert.ok(m.angleDiff(r.bearingDeg, bearing) <= 15, `bearing ${bearing}@${kmh}: got ${r.bearingDeg}`);
      assert.ok(Math.abs(r.speedKmh - kmh) / kmh <= 0.2, `speed ${kmh}@${bearing}: got ${r.speedKmh}`);
      assert.ok(r.confidence > 0.6, `confidence ${r.confidence} @${kmh}/${bearing}`);
    }
  }
});

test('estimateMotion: odd angle and dt=45 min', () => {
  const world = makeWorld(420, 11);
  const kmh = 33;
  const bearing = 112;
  const shiftPx = (kmh * 0.75) / PX_KM;
  const [a, b] = pair(world, 190, shiftPx * Math.sin((bearing * Math.PI) / 180), -shiftPx * Math.cos((bearing * Math.PI) / 180));
  const r = m.estimateMotion(a, b, 45, PX_KM, { maxShift: 30 });
  assert.ok(m.angleDiff(r.bearingDeg, bearing) <= 15);
  assert.ok(Math.abs(r.speedKmh - kmh) / kmh <= 0.2);
});

test('estimateMotion: no motion → stationary, no bearing', () => {
  const world = makeWorld(420, 3);
  const [a, b] = pair(world, 190, 0, 0);
  const r = m.estimateMotion(a, b, DT, PX_KM, { maxShift: 28 });
  assert.ok(r.ok);
  assert.ok(r.stationary);
  assert.equal(r.bearingDeg, null);
  assert.ok(r.speedKmh < 4);
});

test('estimateMotion: clear sky (no texture) and missing data → not ok, zero confidence', () => {
  const blank = { w: 190, h: 190, data: new Float32Array(190 * 190) };
  const r = m.estimateMotion(blank, blank, DT, PX_KM, { maxShift: 28 });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'flat');
  assert.equal(r.confidence, 0);
  assert.equal(m.estimateMotion(null, blank, DT, PX_KM).ok, false);
  assert.equal(m.estimateMotion(blank, blank, 0, PX_KM).reason, 'bad_dt');
  const tiny = { w: 20, h: 20, data: new Float32Array(400) };
  assert.equal(m.estimateMotion(tiny, tiny, DT, PX_KM, { maxShift: 28 }).ok, false);
});

test('estimateMotion: uncorrelated frames give low confidence', () => {
  const [a] = pair(makeWorld(420, 5), 190, 0, 0);
  const [b] = pair(makeWorld(420, 99), 190, 0, 0);
  const r = m.estimateMotion(a, b, DT, PX_KM, { maxShift: 28 });
  assert.ok(!r.ok || r.confidence < 0.45, `confidence ${r.confidence}`);
});

test('estimateMotion: motion beyond the search range is rejected, not mis-reported', () => {
  const world = makeWorld(420, 7);
  const [a, b] = pair(world, 190, 40, 0); // 40 px > maxShift 28
  const r = m.estimateMotion(a, b, DT, PX_KM, { maxShift: 28 });
  assert.ok(!r.ok || r.confidence < 0.45);
});

test('estimateMotion: moderate noise keeps direction within tolerance', () => {
  const world = makeWorld(420, 21);
  const [a, b] = pair(world, 190, 8, -6); // east-north-east-ish: bearing ≈ 53°, 10 px
  const r = new (class { })();
  const noisy = (f, seed) => {
    const g = rng(seed);
    return { w: f.w, h: f.h, data: Float32Array.from(f.data, (v) => Math.max(0, Math.min(1, v + (g() - 0.5) * 0.12))) };
  };
  const out = m.estimateMotion(noisy(a, 1), noisy(b, 2), DT, PX_KM, { maxShift: 28 });
  void r;
  assert.ok(out.ok);
  assert.ok(m.angleDiff(out.bearingDeg, m.bearingOf(8, -6)) <= 15);
  assert.ok(Math.abs(out.speedKmh - 40) / 40 <= 0.2);
});

test('bearingOf and directionAr', () => {
  assert.equal(Math.round(m.bearingOf(0, -1)), 0);
  assert.equal(Math.round(m.bearingOf(1, 0)), 90);
  assert.equal(Math.round(m.bearingOf(0, 1)), 180);
  assert.equal(Math.round(m.bearingOf(-1, 0)), 270);
  assert.equal(m.directionAr(90), 'شرقًا');
  assert.equal(m.directionAr(359), 'شمالًا');
  assert.equal(m.directionAr(225), 'جنوب غربي');
});

/** A solid dense cloud band: x in [bx0, bx1), all rows. */
function bandFrame(n, bx0, bx1) {
  const data = new Float32Array(n * n);
  for (let y = 0; y < n; y++) for (let x = bx0; x < bx1; x++) data[y * n + x] = 1;
  return { w: n, h: n, data };
}

test('outlookForPoint: cloud upwind → approaching, ETA = distance / speed − image age', () => {
  const n = 200;
  const f = bandFrame(n, 10, 40); // band in the west; clouds move east
  const motion = { ok: true, dx: 5, dy: 0, speedKmh: 40, bearingDeg: 90, confidence: 0.9, stationary: false };
  // point at x=100: nearest cloud edge at x=39 → 61 px × 4 km = 244 km; horizon 300
  const o = m.outlookForPoint(f, 100, 100, motion, 4, 90, { horizonKm: 300, horizonMin: 600 });
  assert.equal(o.state, 'approaching');
  // 244 km / 40 km/h = 366 min after the picture, minus 90 min of age
  assert.ok(Math.abs(o.etaMin - (366 - 90)) <= 6, `eta ${o.etaMin}`);
  assert.ok(o.marginMin >= 15);
});

test('outlookForPoint: closer cloud, small age', () => {
  const f = bandFrame(200, 80, 95);
  const motion = { ok: true, dx: 5, dy: 0, speedKmh: 40, bearingDeg: 90, confidence: 0.9, stationary: false };
  const o = m.outlookForPoint(f, 120, 100, motion, 4, 60);
  // edge x=94 → 26 px → 104 km → 156 min; minus 60
  assert.equal(o.state, 'approaching');
  assert.ok(Math.abs(o.etaMin - 96) <= 4, `eta ${o.etaMin}`);
});

test('outlookForPoint: image older than the ETA → arrived, no number', () => {
  const f = bandFrame(200, 80, 95);
  const motion = { ok: true, dx: 5, dy: 0, speedKmh: 40, bearingDeg: 90, confidence: 0.9, stationary: false };
  const o = m.outlookForPoint(f, 120, 100, motion, 4, 200);
  assert.equal(o.state, 'arrived');
  assert.equal(o.etaMin, undefined);
});

test('outlookForPoint: under cloud → overhead, with when it clears', () => {
  const f = bandFrame(200, 80, 110);
  const motion = { ok: true, dx: 5, dy: 0, speedKmh: 40, bearingDeg: 90, confidence: 0.9, stationary: false };
  const o = m.outlookForPoint(f, 100, 100, motion, 4, 0);
  assert.equal(o.state, 'overhead');
  // band x 80..109, point x=100, moving east: the trailing (west) edge is 20 px behind → 21 px × 4 km / 40 km/h ≈ 126 min.
  // (The leading edge, 10 px ahead, would wrongly say ~66 min.)
  assert.ok(o.clearingInMin > 110 && o.clearingInMin < 140, `clearing ${o.clearingInMin}`);
});

test('outlookForPoint: nothing upwind → clear; low confidence → uncertain; no motion → stationary', () => {
  const f = bandFrame(200, 150, 190); // cloud only downwind (east) of a point at x=100
  const mv = { ok: true, dx: 5, dy: 0, speedKmh: 40, bearingDeg: 90, confidence: 0.9, stationary: false };
  assert.equal(m.outlookForPoint(f, 100, 100, mv, 4, 60).state, 'clear');
  assert.equal(m.outlookForPoint(f, 100, 100, { ...mv, confidence: 0.2 }, 4, 60).state, 'uncertain');
  assert.equal(m.outlookForPoint(f, 100, 100, { ok: false, confidence: 0 }, 4, 60).state, 'uncertain');
  assert.equal(m.outlookForPoint(f, 100, 100, { ...mv, stationary: true, speedKmh: 1, bearingDeg: null }, 4, 60).state, 'stationary');
});

test('outlookForPoint: ETA beyond the horizon is "clear", not a far-off number', () => {
  const f = bandFrame(200, 0, 3);
  const mv = { ok: true, dx: 1, dy: 0, speedKmh: 8, bearingDeg: 90, confidence: 0.9, stationary: false };
  const o = m.outlookForPoint(f, 100, 100, mv, 4, 60, { horizonKm: 500, horizonMin: 360 });
  assert.equal(o.state, 'clear');
});

test('marginMinutes grows with weak confidence and distance', () => {
  assert.ok(m.marginMinutes(120, 0.5) > m.marginMinutes(120, 1));
  assert.ok(m.marginMinutes(240, 0.8) > m.marginMinutes(60, 0.8));
});

test('estimateMotion: a small shift that barely beats "no motion" is not reported with confidence', () => {
  const world = makeWorld(420, 7);
  const [a, b] = pair(world, 190, 1.2, 0); // ~1.2 px
  // Make the pair almost identical plus noise so the displaced peak ≈ the zero-shift peak.
  const g = rng(5);
  const noisy = (f) => ({ w: f.w, h: f.h, data: Float32Array.from(f.data, (v) => Math.max(0, Math.min(1, v + (g() - 0.5) * 0.6))) });
  const r = m.estimateMotion(noisy(a), noisy(b), DT, PX_KM, { maxShift: 28 });
  assert.ok(!r.ok || r.stationary || r.confidence < 0.45, `confidence ${r.confidence} speed ${r.speedKmh}`);
});
