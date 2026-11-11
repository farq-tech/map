'use strict';

/* Wind layer: u/v maths, MET parsing, bilinear grid, streamlines (length ∝ speed, direction), HTTP contract with a fake MET. */

process.env.WEATHER_WARM = '0';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const fetcher = require('./weather/fetcher');
const wind = require('./weather/wind');
const { haversineKm } = require('./weather/mercator');

const close = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} vs ${b}`);

test('toUV/fromUV: "from" convention, round trip', () => {
  let { u, v } = wind.toUV(10, 0); // from the north → blows south
  close(u, 0); close(v, -10);
  ({ u, v } = wind.toUV(10, 270)); // from the west → blows east
  close(u, 10); close(v, 0);
  for (const [s, d] of [[3, 45], [12, 135], [7.5, 300], [1, 359]]) {
    const w = wind.fromUV(...Object.values(wind.toUV(s, d)));
    close(w.speed, s); close(w.fromDeg, d, 1e-6); close(w.toDeg, (d + 180) % 360, 1e-6);
  }
});

const met = (entries, updated = '2026-11-11T19:50:45Z') => ({
  properties: {
    meta: { updated_at: updated },
    timeseries: entries.map(([time, speed, dir]) => ({ time, data: { instant: { details: { wind_speed: speed, wind_from_direction: dir } } } })),
  },
});

test('parseForecast: nearest hour to now, model age source, garbage → null', () => {
  const j = met([['2026-11-11T19:00:00Z', 2, 10], ['2026-11-11T20:00:00Z', 5, 270], ['2026-11-11T21:00:00Z', 9, 180]]);
  const f = wind.parseForecast(j, Date.parse('2026-11-11T20:20:00Z'));
  assert.equal(f.validTime, '2026-11-11T20:00:00Z');
  assert.equal(f.speed, 5);
  close(f.u, 5);
  assert.equal(f.updatedAt, '2026-11-11T19:50:45Z');
  assert.equal(wind.parseForecast({}, 0), null);
  assert.equal(wind.parseForecast(met([['2026-11-11T20:00:00Z', null, 1]]), Date.parse('2026-11-11T20:00:00Z')), null);
  assert.equal(wind.parseForecast(met([['2026-11-10T00:00:00Z', 5, 1]]), Date.parse('2026-11-11T20:00:00Z')), null, 'a forecast entry hours away is not "now"');
});

function uniformGrid(speed, fromDeg) {
  const g = wind.makeGrid();
  const { u, v } = wind.toUV(speed, fromDeg);
  g.u.fill(u); g.v.fill(v); g.ok = g.u.length; g.validTime = '2026-11-11T20:00:00Z';
  return g;
}

test('sampleGrid: bilinear, skips holes, null outside', () => {
  const g = uniformGrid(8, 270);
  const s = wind.sampleGrid(g, 46.2, 24.1);
  close(s.u, 8, 1e-5);
  /* Linear ramp in u along longitude is reproduced exactly. */
  for (let j = 0; j < wind.NLAT; j++) for (let i = 0; i < wind.NLNG; i++) { g.u[wind.idx(i, j)] = wind.cellLng(i); g.v[wind.idx(i, j)] = 0; }
  close(wind.sampleGrid(g, 45.37, 24.8).u, 45.37, 1e-4);
  g.u[wind.idx(8, 6)] = NaN;
  assert.ok(Number.isFinite(wind.sampleGrid(g, wind.cellLng(8) + 0.75, wind.cellLat(6) + 0.75).u));
  assert.equal(wind.sampleGrid(g, 10, 24), null);
  assert.equal(wind.sampleGrid(g, 46, 5), null);
});

test('streamlines: a 10 m/s westerly gives eastward lines ≈ 216 km long with an arrowhead', () => {
  const fc = wind.streamlines(uniformGrid(10, 270));
  assert.ok(fc.features.length > 150, `lines ${fc.features.length}`);
  for (const f of fc.features.slice(0, 40)) {
    const [main, head] = f.geometry.coordinates;
    const a = { lng: main[0][0], lat: main[0][1] };
    const b = { lng: main[main.length - 1][0], lat: main[main.length - 1][1] };
    assert.ok(b.lng > a.lng, 'moves east');
    assert.ok(Math.abs(b.lat - a.lat) < 0.05, 'stays on its latitude');
    const km = haversineKm(a, b);
    assert.ok(km > 195 && km < 235, `length ${km}`);
    assert.equal(head.length, 3);
    assert.deepEqual(head[1], main[main.length - 1], 'the head is at the tip');
    assert.ok(head[0][0] < head[1][0] && head[2][0] < head[1][0], 'barbs trail behind the tip');
    assert.equal(f.properties.speed_kmh, 36);
  }
});

test('streamlines: length follows speed; calm air draws nothing', () => {
  const len = (s) => {
    const f = wind.streamlines(uniformGrid(s, 270)).features.find((x) => x.geometry.coordinates[0][0][0] < 45);
    const m = f.geometry.coordinates[0];
    return haversineKm({ lng: m[0][0], lat: m[0][1] }, { lng: m[m.length - 1][0], lat: m[m.length - 1][1] });
  };
  assert.ok(Math.abs(len(5) * 2 - len(10)) < 8);
  assert.equal(wind.streamlines(uniformGrid(0.4, 90)).features.length, 0);
  /* From the north → lines run south. */
  const f = wind.streamlines(uniformGrid(6, 0)).features.find((x) => x.geometry.coordinates[0][0][1] > 22).geometry.coordinates[0];
  assert.ok(f[f.length - 1][1] < f[0][1]);
});

test('fromAr: eight points', () => {
  assert.equal(wind.fromAr(0), 'شمالية');
  assert.equal(wind.fromAr(315), 'شمالية غربية');
  assert.equal(wind.fromAr(359), 'شمالية');
  assert.equal(wind.fromAr(180), 'جنوبية');
});

test('HTTP: wind point + streamlines through a fake MET; polite request shape; honest labels', async () => {
  const nowMs = Date.parse('2026-11-11T20:20:00Z');
  const real = Date.now;
  Date.now = () => nowMs;
  wind._reset();
  const seen = [];
  fetcher.setFetch(async (url, opts) => {
    seen.push({ url, ua: opts && opts.headers && opts.headers['user-agent'] });
    const lat = Number(/lat=([-\d.]+)/.exec(url)[1]);
    /* West wind that strengthens northward: 3 m/s at 15°N … 9 m/s at 33°N. */
    const sp = 3 + (lat - 15) / 3;
    return { status: 200, type: 'application/json', body: Buffer.from(JSON.stringify(met([['2026-11-11T20:00:00Z', sp, 270], ['2026-11-11T21:00:00Z', sp, 270]]))) };
  });
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    let r = await fetch(`${base}/api/weather/wind?lat=0&lng=0`);
    assert.equal(r.status, 400);
    r = await fetch(`${base}/api/weather/wind?lat=24.5&lng=46.5`);
    assert.equal(r.status, 200);
    const j = await r.json();
    assert.equal(j.ok, true);
    assert.equal(j.from_deg, 270);
    assert.equal(j.toward_deg, 90);
    assert.equal(j.from_ar, 'غربية');
    close(j.speed_ms, 3 + 9.5 / 3, 0.1);
    assert.equal(j.forecast_model, true);
    assert.equal(j.model_age_min, 29, 'age from the model run time, not from our fetch');
    assert.equal(j.grid_step_deg, 1.5);
    assert.match(j.attribution, /MET Norway/);
    assert.match(j.caveats_ar, /مو قياس/);
    assert.equal(seen.length, wind.NLAT * wind.NLNG, 'one request per grid cell, once');
    for (const s of seen) {
      assert.match(s.ua, /SaryAlbarq-API.*github\.com\/farq-tech\/map/);
      assert.match(s.url, /lat=[-\d]+(\.\d{1,4})?&lon=[-\d]+(\.\d{1,4})?$/, 'coordinates truncated to ≤ 4 decimals');
    }
    r = await fetch(`${base}/api/weather/wind/streamlines`);
    assert.equal(r.status, 200);
    const s = await r.json();
    assert.equal(s.type, 'FeatureCollection');
    assert.ok(s.features.length > 150);
    assert.equal(seen.length, wind.NLAT * wind.NLNG, 'served from the cached grid');
    assert.equal(s.line_hours, 6);
  } finally {
    server.close();
    fetcher.setFetch(null);
    Date.now = real;
    wind._reset();
  }
});

test('HTTP: MET throttling or an outage → 503, never made-up wind', async () => {
  wind._reset();
  fetcher.setFetch(async () => ({ status: 429, type: 'text/plain', body: Buffer.from('slow down') }));
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  try {
    const r = await fetch(`http://127.0.0.1:${server.address().port}/api/weather/wind?lat=24.5&lng=46.5`);
    assert.equal(r.status, 503);
    assert.equal((await r.json()).ok, false);
  } finally {
    server.close();
    fetcher.setFetch(null);
    wind._reset();
  }
});
