'use strict';

/* Cloud outlook glue: frame choice, blank-picture guard, cross-check, and the HTTP contract (fake WMS). */

process.env.WEATHER_WARM = '0';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { PNG } = require('pngjs');
const fetcher = require('./weather/fetcher');
const clouds = require('./weather/clouds');
const out = require('./weather/cloud-outlook');
const motion = require('./weather/cloud-motion');

const MIN = 60_000;
const frame = (iso) => ({ id: clouds.frameId(iso), time: iso });

test('pickFrames: newest, one ~30 min before, one ~60 min before', () => {
  const t0 = Date.parse('2026-11-11T19:00:00Z');
  const fs = [];
  for (let m = 120; m >= 0; m -= 10) fs.push(frame(new Date(t0 - m * MIN).toISOString()));
  const s = out.pickFrames(fs);
  assert.equal(s.newer.time, '2026-11-11T19:00:00.000Z');
    assert.equal(s.oldest.time, '2026-11-11T18:00:00.000Z');
  assert.equal(s.dtMin, 30);
  assert.equal(s.dt2Min, 30);
});

test('pickFrames: free-licence gaps (only hourly frames near the newest) still pair, or give up', () => {
  const hourly = ['2026-11-11T17:00:00Z', '2026-11-11T18:00:00Z', '2026-11-11T19:00:00Z'].map(frame);
  assert.equal(out.pickFrames(hourly), null); // nothing within 30 ± 10 min of the newest
  const some = ['2026-11-11T18:30:00Z', '2026-11-11T18:50:00Z', '2026-11-11T19:00:00Z'].map(frame);
  const s = out.pickFrames(some);
    assert.equal(s.oldest, null);
  assert.equal(out.pickFrames([frame('2026-11-11T19:00:00Z')]), null);
  assert.equal(out.pickFrames([]), null);
});

function pngOf(fn, size = 16, alpha = 255) {
  const p = new PNG({ width: size, height: size });
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const v = fn(x, y);
      p.data.set([v, v, v, alpha], (y * size + x) * 4);
    }
  }
  return PNG.sync.write(p);
}

test('fieldsFromPng: a blank (transparent) picture is rejected, a real one gives gray + opacity', () => {
  assert.equal(out.fieldsFromPng(pngOf(() => 255, 16, 0)), null);
  const f = out.fieldsFromPng(pngOf((x) => (x < 8 ? 40 : 230)));
  assert.ok(f.gray.data[0] < 0.2 && f.gray.data[15] > 0.8);
  assert.equal(f.opacity.data[0], 0);
  assert.ok(f.opacity.data[15] > 0.9);
});

test('cellOf rounds to a 1° cell', () => {
  assert.deepEqual(out.cellOf(24.71, 46.68), { lat: 25, lng: 47 });
});

test('consistency: agreeing pairs ≈ 1, disagreeing ≈ 0', () => {
  const m = (b, s) => ({ ok: true, bearingDeg: b, speedKmh: s, stationary: false });
  assert.equal(motion.consistency(m(60, 50), m(70, 55)), 1);
  assert.ok(motion.consistency(m(60, 50), m(200, 50)) < 0.1);
  assert.ok(motion.consistency(m(60, 50), m(60, 120)) < 0.1);
  assert.equal(motion.consistency(m(60, 50), { ok: false }), 0);
});

/** Fake WMS: frames are one drifting texture so motion between them is real. */
function textured(shiftPx, size = 256) {
  const p = new PNG({ width: size, height: size });
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const X = x - shiftPx;
      const v = 120 + 80 * Math.sin(X / 9) * Math.cos(y / 11) + 40 * Math.sin((X + y) / 5);
      const c = Math.max(0, Math.min(255, Math.round(v)));
      p.data.set([c, c, c, 255], (y * size + x) * 4);
    }
  }
  return PNG.sync.write(p);
}

test('HTTP: /weather/clouds/outlook — bad point 400; fake WMS gives a motion estimate with its age', async () => {
  const nowMs = Date.parse('2026-11-11T19:59:00Z');
  const real = Date.now;
  Date.now = () => nowMs;
  clouds._reset();
  const shifts = { '2026-11-11T19:00:00Z': 20, '2026-11-11T18:30:00Z': 10, '2026-11-11T18:00:00Z': 0 };
  fetcher.setFetch(async (url) => {
    if (/GetCapabilities/.test(url)) {
      return { status: 200, type: 'text/xml', body: Buffer.from('<Dimension name="time">2026-11-10T00:00:00Z/2026-11-11T19:00:00.000Z/PT10M</Dimension>') };
    }
    const t = /time=([^&]+)/.exec(url)[1].replace(/%3A/g, ':');
    return { status: 200, type: 'image/png', body: textured(shifts[t] ?? 0) };
  });
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    let r = await fetch(`${base}/api/weather/clouds/outlook?lat=0&lng=0`);
    assert.equal(r.status, 400);
    assert.equal((await r.json()).error, 'bad_point');
    r = await fetch(`${base}/api/weather/clouds/outlook?lat=25.2&lng=55.3`); // Dubai: inside the box, outside the Kingdom
    assert.equal(r.status, 400);
    r = await fetch(`${base}/api/weather/clouds/outlook?lat=abc&lng=46`);
    assert.equal(r.status, 400);
    r = await fetch(`${base}/api/weather/clouds/outlook?lat=24.7&lng=46.7`);
    assert.equal(r.status, 200);
    assert.equal(r.headers.get('cache-control'), 'no-store');
    const j = await r.json();
    assert.equal(j.ok, true);
    assert.equal(j.image_time, '2026-11-11T19:00:00.000Z');
    assert.equal(j.image_age_min, 59);
    assert.equal(j.dt_minutes, 30);
    assert.equal(j.compared_with.length, 2);
    /* 10 px / 30 min at 2.5 km/px = 50 km/h toward the east. */
    assert.ok(j.motion, JSON.stringify(j));
    assert.ok(Math.abs(j.motion.speed_kmh - 50) <= 10, `speed ${j.motion.speed_kmh}`);
    assert.ok(motion.angleDiff(j.motion.bearing_deg, 90) <= 15, `bearing ${j.motion.bearing_deg}`);
    assert.equal(j.cross_check, 1);
    assert.match(j.attribution, /EUMETSAT/);
  } finally {
    server.close();
    fetcher.setFetch(null);
    Date.now = real;
    clouds._reset();
  }
});

test('clouds.warm: fetches the Kingdom tiles of the newest frames once, newest first', async () => {
  const nowMs = Date.parse('2026-11-11T19:59:00Z');
  clouds._reset();
  const seen = [];
  fetcher.setFetch(async (url) => {
    if (/GetCapabilities/.test(url)) {
      return { status: 200, type: 'text/xml', body: Buffer.from('<Dimension name="time">2026-11-10T00:00:00Z/2026-11-11T19:00:00.000Z/PT10M</Dimension>') };
    }
    seen.push(/time=([^&]+)/.exec(url)[1]);
    return { status: 200, type: 'image/png', body: textured(0) };
  });
  try {
    const r = await clouds.warm(nowMs, { frames: 2 });
    assert.equal(r.frames, 2);
    assert.ok(r.tiles >= 20 && r.tiles <= 200, `tiles ${r.tiles}`);
    assert.equal(seen.length, r.tiles);
    assert.match(decodeURIComponent(seen[0]), /T19:00:00Z/); // newest first
  } finally {
    fetcher.setFetch(null);
    clouds._reset();
  }
});

test('cloudTileRgba: colour by thickness, soft shadow down-right, clear ground untouched', () => {
  const w = 24;
  const h = 24;
  const buf = Buffer.alloc(w * h * 4);
  const put = (x, y, v) => buf.set([v, v, v, 255], (y * w + x) * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) put(x, y, 40); // warm ground
  for (let y = 6; y < 12; y++) for (let x = 6; x < 12; x++) put(x, y, 225); // very cold top
  for (let y = 6; y < 12; y++) for (let x = 14; x < 20; x++) put(x, y, 190); // thick
  for (let y = 16; y < 22; y++) for (let x = 6; x < 12; x++) put(x, y, 110); // thin
  const o = clouds.cloudTileRgba(buf, w, h);
  const px = (x, y) => [...o.subarray((y * w + x) * 4, (y * w + x) * 4 + 4)];
  assert.equal(px(0, 0)[3], 0, 'warm ground transparent');
  const cold = px(9, 8);
  const thick = px(17, 8);
  const thin = px(9, 18);
  assert.ok(cold[3] > 220 && cold[0] < thick[0], 'cold top is cyan (less red than white)');
  assert.ok(thick[0] > 230 && thick[1] > 230 && thick[2] > 230, 'thick cloud is white');
  assert.ok(thin[2] > thin[0] + 25 && thin[3] > 0 && thin[3] < thick[3], 'thin cloud pale blue and lighter');
  const shadow = px(13, 13); // just below-right of the cold block
  assert.ok(shadow[3] > 15 && shadow[0] < 60, `soft dark shadow ${shadow}`);
  assert.equal(o.length, w * h * 4);
});

test('clouds tiles: mid-level cloud is drawn clearly (stronger curve than the outlook\'s), warm ground stays transparent', () => {
  const px = Buffer.from([50, 50, 50, 255, 140, 140, 140, 255, 190, 190, 190, 255]);
  const tile = clouds.irToOverlay(px, clouds.TILE_CURVE);
  const dflt = clouds.irToOverlay(px);
  assert.equal(tile[3], 0);
  assert.ok(tile[7] > dflt[7] + 40, `mid cloud alpha ${tile[7]} vs ${dflt[7]}`);
  assert.ok(tile[11] >= 240);
});
