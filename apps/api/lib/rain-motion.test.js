'use strict';

/* Rain motion: known drifts on synthetic IMERG-like fields, the honest "no" cases, and the HTTP contract with a fake GIBS. */

process.env.WEATHER_WARM = '0';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { PNG } = require('pngjs');
const fetcher = require('./weather/fetcher');
const colormap = require('./weather/colormap');
const rain = require('./weather/rain');
const rm = require('./weather/rain-motion');
const motion = require('./weather/cloud-motion');

const N = rm.SIZE;

/** Rain-cell pattern drifted by (dx, dy) pixels (east+, south+): blobs of different size, so there is texture to match. */
function pattern(x, y) {
  const v = Math.sin(x / 6.3) * Math.cos(y / 8.1) + 0.6 * Math.sin((x + y) / 4.7) + 0.3 * Math.cos((x - 2 * y) / 9.3);
  return v > 0.55 ? Math.min(1, 0.25 + (v - 0.55)) : 0;
}
function field(dx, dy, fn = pattern) {
  const data = new Float32Array(N * N);
  let rainy = 0;
  for (let y = 0; y < N; y++) {
    for (let x = 0; x < N; x++) {
      const v = fn(x - dx, y - dy);
      data[y * N + x] = v;
      if (v > 0.05) rainy++;
    }
  }
  return { w: N, h: N, data, rainyPx: rainy, missing: 0 };
}
const LAT = 24.5;
const kmpx = rm.pxKmAt(LAT);

test('pxKmAt: ≈ 9 km at 24.5°N for z4', () => {
  assert.ok(kmpx > 8.5 && kmpx < 9.5, `${kmpx}`);
});

test('analyse: known drifts come back within ±15° and ±20 % (and 60 min between frames)', () => {
  for (const [dx, dy] of [[3, 0], [0, -3], [-4, 2], [2, 3], [5, -2]]) {
    const a = rm.analyse({ f2: field(-2 * dx, -2 * dy), f1: field(-dx, -dy), f0: field(0, 0) }, LAT);
    /* f1→f0 moves the pattern by (+dx, +dy). */
    const want = { dx, dy };
    const wantB = motion.bearingOf(want.dx, want.dy);
    const wantKmh = Math.hypot(dx, dy) * kmpx;
    assert.equal(a.state, 'moving', `${dx},${dy}: ${a.state} conf ${a.confidence}`);
    assert.ok(motion.angleDiff(a.est.bearingDeg, wantB) <= 15, `bearing ${a.est.bearingDeg} vs ${wantB}`);
    assert.ok(Math.abs(a.est.speedKmh - wantKmh) <= 0.2 * wantKmh, `speed ${a.est.speedKmh} vs ${wantKmh}`);
    assert.ok(a.confidence >= rm.MIN_CONFIDENCE);
  }
});

test('analyse: no rain around → no_rain (no arrow, no guess)', () => {
  const none = field(0, 0, () => 0);
  assert.equal(rm.analyse({ f1: none, f0: none }, LAT).state, 'no_rain');
});

test('analyse: unrelated patterns → uncertain (hidden), not a confident wrong arrow', () => {
  const other = (x, y) => (Math.sin(x * 1.7 + y * 0.3) * Math.cos(y * 2.1) > 0.4 ? 0.7 : 0);
  const a = rm.analyse({ f1: field(0, 0, other), f0: field(0, 0, (x, y) => other(x * 0.9 + 13, y * 1.1 - 7)) }, LAT);
  assert.notEqual(a.state, 'moving');
});

test('analyse: the two hourly pairs disagree → confidence drops below the floor', () => {
  const a = rm.analyse({ f2: field(0, 0), f1: field(6, 0), f0: field(6, 6) }, LAT);
  /* f2→f1 moves east, f1→f0 moves south: inconsistent. */
  assert.equal(a.state, 'uncertain');
  assert.ok(a.confidence < rm.MIN_CONFIDENCE);
});

test('analyse: an unreadable earlier hour (rain just appeared) is a small penalty, not a veto', () => {
  const clear = field(0, 0, () => 0);
  const withCheck = rm.analyse({ f2: field(-6, 0), f1: field(-3, 0), f0: field(0, 0) }, LAT);
  const noCheck = rm.analyse({ f2: clear, f1: field(-3, 0), f0: field(0, 0) }, LAT);
  assert.equal(noCheck.state, 'moving');
  assert.equal(noCheck.cross_check, null, 'no verdict claimed from a check that could not be read');
  assert.ok(noCheck.confidence < withCheck.confidence, 'but less sure than when confirmed');
  assert.ok(motion.angleDiff(noCheck.est.bearingDeg, 90) <= 15);
});

test('analyse: a fixed pattern is stationary, not a direction', () => {
  const a = rm.analyse({ f2: field(0, 0), f1: field(0, 0), f0: field(0, 0) }, LAT);
  assert.equal(a.state, 'stationary');
});

test('margins: widen as confidence falls; never below half a pixel-hour', () => {
  const hi = rm.margins({ confidence: 0.95, speedKmh: 30 }, kmpx);
  const lo = rm.margins({ confidence: 0.5, speedKmh: 30 }, kmpx);
  assert.ok(hi.angle < lo.angle && hi.speed <= lo.speed);
  assert.ok(hi.speed >= kmpx / 2 - 1);
  assert.ok(lo.angle <= 90);
});

test('rainContrast: zero stays zero, drizzle and downpour both visible, capped at 1', () => {
  assert.equal(rm.rainContrast(0), 0);
  assert.ok(rm.rainContrast(0.2) > 0.05);
  assert.equal(rm.rainContrast(100), 1);
});

/* ---- HTTP with a fake GIBS: rain drifts 3 px/h east in global z4 pixel coordinates ---- */
function rgbOf(predicate) {
  return colormap.load('GPM_Precipitation_Rate').entries.find(predicate).rgb;
}

test('HTTP: /weather/rain/motion — bad point 400; drifting rain gives bearing ≈ east, speed ≈ 27 km/h, with age and margins', async () => {
  const latest = Date.parse('2026-11-11T14:30:00Z');
  const nowMs = latest + 5 * 3600_000;
  const real = Date.now;
  Date.now = () => nowMs;
  rain._reset();
  rm._reset();
  const two = rgbOf((e) => !e.nodata && e.lo <= 2 && e.hi > 2);
  let tileCalls = 0;
  fetcher.setFetch(async (url) => {
    if (url.endsWith('.xml')) return { status: 200, type: 'text/xml', body: Buffer.from('<Domain>2026-11-01/2026-11-11T14:30:00Z/PT30M</Domain>') };
    tileCalls++;
    const m = /IMERG_Precipitation_Rate_30min\/default\/([^/]+)\/[^/]+\/4\/(\d+)\/(\d+)\.png/.exec(url);
    const t = Date.parse(m[1]);
    const ty = Number(m[2]);
    const tx = Number(m[3]);
    const hours = (t - latest) / 3600_000;
    const p = new PNG({ width: 256, height: 256 });
    for (let y = 0; y < 256; y++) {
      for (let x = 0; x < 256; x++) {
        const v = pattern(tx * 256 + x - 3 * hours, ty * 256 + y);
        if (v > 0) p.data.set([...two, 255], (y * 256 + x) * 4);
      }
    }
    return { status: 200, type: 'image/png', body: PNG.sync.write(p) };
  });
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    let r = await fetch(`${base}/api/weather/rain/motion?lat=0&lng=0`);
    assert.equal(r.status, 400);
    r = await fetch(`${base}/api/weather/rain/motion?lat=24.5&lng=46.5`);
    assert.equal(r.status, 200);
    const j = await r.json();
    assert.equal(j.ok, true);
    assert.equal(j.state, 'moving', JSON.stringify(j));
    assert.ok(motion.angleDiff(j.motion.bearing_deg, 90) <= 15, `bearing ${j.motion.bearing_deg}`);
    const want = 3 * rm.pxKmAt(24.5);
    assert.ok(Math.abs(j.motion.speed_kmh - want) <= 0.2 * want, `speed ${j.motion.speed_kmh} vs ${want}`);
    assert.ok(j.motion.margin_deg >= 15 && j.motion.margin_kmh >= 4);
    assert.equal(j.image_time, '2026-11-11T14:30:00Z');
    assert.equal(j.image_age_min, 300);
    assert.equal(j.dt_minutes, 60);
    assert.equal(j.compared_with.length, 2);
    assert.match(j.caveats_ar, /مو توقع/);
    assert.match(j.attribution, /IMERG/);
    const before = tileCalls;
    await fetch(`${base}/api/weather/rain/motion?lat=24.6&lng=46.6`); // same half-degree cell → memoised
    assert.equal(tileCalls, before);
  } finally {
    server.close();
    fetcher.setFetch(null);
    Date.now = real;
    rain._reset();
    rm._reset();
  }
});

test('HTTP: no rain in the window → state no_rain with no motion; missing frames → 503', async () => {
  const latest = Date.parse('2026-11-11T14:30:00Z');
  rain._reset();
  rm._reset();
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const dry = PNG.sync.write(new PNG({ width: 256, height: 256 }));
    fetcher.setFetch(async (url) => (url.endsWith('.xml')
      ? { status: 200, type: 'text/xml', body: Buffer.from('<Domain>2026-11-01/2026-11-11T14:30:00Z/PT30M</Domain>') }
      : { status: 200, type: 'image/png', body: dry }));
    let r = await fetch(`${base}/api/weather/rain/motion?lat=24.5&lng=46.5`);
    let j = await r.json();
    assert.equal(j.state, 'no_rain');
    assert.equal(j.motion, null);
    rain._reset();
    rm._reset();
    fetcher.setFetch(async (url) => (url.endsWith('.xml')
      ? { status: 200, type: 'text/xml', body: Buffer.from('<Domain>2026-11-01/2026-11-11T14:30:00Z/PT30M</Domain>') }
      : { status: 404, type: 'text/plain', body: Buffer.from('') }));
    r = await fetch(`${base}/api/weather/rain/motion?lat=24.5&lng=46.5`);
    assert.equal(r.status, 503);
    assert.ok(latest);
  } finally {
    server.close();
    fetcher.setFetch(null);
    rain._reset();
    rm._reset();
  }
});
