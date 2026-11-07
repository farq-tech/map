'use strict';

/* Weather layers: licence-aware cloud frames, GIBS colour decoding, rain sums, greenness rule,
 * desert search ranking and the HTTP contract. No network: GIBS / EUMETSAT are faked. */

process.env.WEATHER_WARM = '0';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');
const express = require('express');

const fetcher = require('./weather/fetcher');
const colormap = require('./weather/colormap');
const mercator = require('./weather/mercator');
const clouds = require('./weather/clouds');
const gibs = require('./weather/gibs');
const rain = require('./weather/rain');
const green = require('./weather/green');
const { Mosaic } = require('./weather/raster');
const desert = require('./weather/desert-search');

const H = 3600_000;

function solidPng(rgba, size = 256) {
  const p = new PNG({ width: size, height: size });
  for (let i = 0; i < p.data.length; i += 4) p.data.set(rgba, i);
  return PNG.sync.write(p);
}

function rgbOf(cmName, predicate) {
  const e = colormap.load(cmName).entries.find(predicate);
  return [...e.rgb, 255];
}

test('mercator: tile bbox and lon/lat round-trip', () => {
  const [minx, miny, maxx, maxy] = mercator.tileBbox3857(0, 0, 0);
  assert.ok(Math.abs(minx + 20037508.34) < 1 && Math.abs(maxy - 20037508.34) < 1 && maxx > 0 && miny < 0);
  const x = mercator.lngToX(46.7, 7);
  const y = mercator.latToY(24.7, 7);
  assert.ok(Math.abs(mercator.xToLng(x, 7) - 46.7) < 1e-9);
  assert.ok(Math.abs(mercator.yToLat(y, 7) - 24.7) < 1e-9);
  assert.equal(mercator.parseBbox('0,0,1,1'), null);
  assert.deepEqual(mercator.parseBbox('46,24,47,25'), { west: 46, south: 24, east: 47, north: 25 });
  assert.equal(mercator.parseNear('24.7,46.7').lng, 46.7);
  assert.equal(mercator.parseNear('0,0'), null);
  for (const [lng, lat] of [[46.68, 24.71], [39.17, 21.54], [50.1, 26.42], [36.57, 28.38], [44.2, 17.6], [43.97, 26.33]]) {
    assert.ok(mercator.inKsa(lng, lat), `inside ${lng},${lat}`);
  }
  for (const [lng, lat] of [[47.98, 29.37], [47.8, 30.5], [51.53, 25.29], [54.37, 24.45], [44.2, 15.35], [35.93, 31.95], [58.4, 23.6]]) {
    assert.ok(!mercator.inKsa(lng, lat), `outside ${lng},${lat}`);
  }
});

test('clouds: hourly frames are free live, 10-minute frames only once ≥ 1 h old', () => {
  const now = Date.UTC(2026, 10, 7, 11, 35);
  assert.equal(clouds.frameAllowed(Date.UTC(2026, 10, 7, 11, 0), now, false), true); // on the hour
  assert.equal(clouds.frameAllowed(Date.UTC(2026, 10, 7, 11, 10), now, false), false); // 25 min old
  assert.equal(clouds.frameAllowed(Date.UTC(2026, 10, 7, 10, 30), now, false), true); // 65 min old
  assert.equal(clouds.frameAllowed(Date.UTC(2026, 10, 7, 11, 10), now, true), true); // licensed
  const frames = clouds.planFrames(Date.UTC(2026, 10, 7, 11, 20), now, { licensed: false });
  const ids = frames.map((f) => f.id);
  assert.equal(ids[ids.length - 1], '20261107T1100Z');
  assert.ok(!ids.includes('20261107T1110Z') && !ids.includes('20261107T1120Z'));
  assert.ok(ids.includes('20261107T1030Z'));
  assert.equal(ids[0], '20261107T0920Z');
  assert.ok(frames.every((f) => f.licence !== 'recommended-realtime'));
  assert.equal(clouds.riyadhLabel(Date.UTC(2026, 10, 7, 11, 0)), '٢:٠٠ م');
  assert.equal(clouds.parseFrameId(clouds.frameId(Date.UTC(2026, 10, 7, 11, 0))), Date.UTC(2026, 10, 7, 11, 0));
  assert.equal(clouds.parseFrameId('2026-11-07'), null);
});

test('clouds: capabilities parsing and IR → transparent white overlay', () => {
  const xml = '<Dimension name="time" default="x">2024-09-23T00:00:00.000Z/2026-11-07T11:10:00.000Z/PT10M</Dimension>';
  assert.equal(clouds.latestFromCapabilities(xml), Date.UTC(2026, 10, 7, 11, 10));
  const px = Buffer.from([20, 20, 20, 255, 250, 250, 250, 255, 160, 160, 160, 255, 255, 255, 255, 0]);
  const o = clouds.irToOverlay(px);
  assert.equal(o[3], 0); // warm ground: transparent
  assert.ok(o[7] > 200); // cold cloud top: nearly opaque
  assert.ok(o[11] > 0 && o[11] < o[7]); // in between
  assert.equal(o[15], 0); // off-disk stays transparent
  assert.deepEqual([o[4], o[5], o[6]], [255, 255, 255]);
});

test('clouds: tile refuses a real-time 10-minute frame without the licence', async () => {
  const now = Date.UTC(2026, 10, 7, 11, 35);
  const r = await clouds.tile('20261107T1110Z', 5, 20, 13, now);
  assert.equal(r.status, 404);
  assert.equal((await clouds.tile('bad', 5, 20, 13, now)).status, 400);
});

test('clouds: tile fetches EUMETSAT WMS once and caches', async () => {
  let calls = 0;
  fetcher.setFetch(async (url) => {
    calls++;
    assert.match(url, /layers=mtg_fd%3Air105_hrfi/);
    assert.match(url, /time=2026-11-07T11%3A00%3A00Z/);
    return { status: 200, type: 'image/png', body: solidPng([240, 240, 240, 255], 256) };
  });
  try {
    const now = Date.UTC(2026, 10, 7, 11, 35);
    const a = await clouds.tile('20261107T1100Z', 5, 20, 13, now);
    const b = await clouds.tile('20261107T1100Z', 5, 20, 13, now);
    assert.equal(a.status, 200);
    assert.equal(b.body, a.body);
    assert.equal(calls, 1);
    const png = PNG.sync.read(a.body);
    assert.ok(png.data[3] > 200);
  } finally {
    fetcher.setFetch(null);
  }
});

test('colormap: GIBS XML parsing and value lookup', () => {
  const xml = `<ColorMap units="mm/hr"><ColorMapEntry rgb="191,191,191" transparent="true" value="[-INF,0.1)"/>
    <ColorMapEntry rgb="0,118,78" transparent="false" value="[0.1,0.2)"/>
    <ColorMapEntry rgb="58,3,48" transparent="false" value="[50,+INF)"/></ColorMap>`;
  const cm = colormap.parseColormapXml(xml);
  assert.equal(cm.units, 'mm/hr');
  assert.equal(cm.entries.length, 3);
  const lk = colormap.buildLookup(cm, { zeroTransparentBelow: 0.11 });
  assert.equal(lk.get((191 << 16) | (191 << 8) | 191), 0);
  assert.ok(Math.abs(lk.get((0 << 16) | (118 << 8) | 78) - 0.15) < 1e-9);
  assert.equal(lk.get((58 << 16) | (3 << 8) | 48), 50);
  const vendored = colormap.load('GPM_Precipitation_Rate');
  assert.equal(vendored.units, 'mm/hr');
  assert.ok(vendored.entries.length > 200);
  assert.equal(vendored.entries[vendored.entries.length - 1].hi, Infinity);
  assert.ok(colormap.load('MODIS_NDVI').entries.length > 100);
});

test('gibs: domains parsing and palette decoding', () => {
  assert.equal(gibs.latestFromDomains('<Domain>2026-11-01/2026-11-07T05:30:00Z/PT30M</Domain>'), Date.UTC(2026, 10, 7, 5, 30));
  assert.equal(gibs.latestFromDomains('<Domain>2026-01-11/2026-02-08/P1D,2026-02-10/2026-11-02/P1D</Domain>'), Date.UTC(2026, 10, 2));
  const lk = new Map([[(10 << 16) | (20 << 8) | 30, 2.5]]);
  const v = gibs.decodeValues(solidPng([10, 20, 30, 255], 2), lk);
  assert.deepEqual([...v], [2.5, 2.5, 2.5, 2.5]);
  const t = gibs.decodeValues(solidPng([0, 0, 0, 0], 1), lk, 0);
  assert.equal(t[0], 0);
});

test('rain: window frames, day labels, scores', () => {
  const latest = Date.UTC(2026, 10, 7, 5, 30);
  const f = rain.windowFrames(latest, 1);
  assert.equal(f.length, 48);
  assert.equal(f[f.length - 1], latest);
  assert.equal(rain.windowFrames(latest, 7).length, 336);
  assert.equal(rain.parseDays('3'), 3);
  assert.equal(rain.parseDays('2'), null);
  assert.equal(rain.agoAr(30), 'أمس');
  assert.equal(rain.agoAr(72), 'قبل ٣ أيام');
  assert.equal(rain.agoAr(5), 'قبل ساعات');
});

test('rain: sums half-hour IMERG tiles into mm and serves grid + tile', async () => {
  rain._reset();
  const latest = Date.UTC(2026, 10, 7, 5, 30);
  const twoMmH = rgbOf('GPM_Precipitation_Rate', (e) => !e.nodata && e.lo <= 2 && e.hi > 2);
  const rainFrom = latest - 6 * H; // it rained during the last 6 h of the window only
  let tileCalls = 0;
  fetcher.setFetch(async (url) => {
    if (url.endsWith('.xml')) return { status: 200, type: 'text/xml', body: Buffer.from('<Domain>2026-11-01/2026-11-07T05:30:00Z/PT30M</Domain>') };
    tileCalls++;
    const m = /IMERG_Precipitation_Rate_30min\/default\/([^/]+)\//.exec(url);
    const t = Date.parse(m[1]);
    return { status: 200, type: 'image/png', body: solidPng(t > rainFrom ? twoMmH : [0, 0, 0, 0]) };
  });
  try {
    const nowMs = latest + 5 * H;
    const r = await rain.recent({ days: 1, bbox: { west: 46, south: 24, east: 47, north: 25 }, nowMs, waitMs: 10_000 });
    assert.equal(r.ok, true);
    assert.equal(r.coverage.frames_ok, r.coverage.frames_expected);
    assert.equal(tileCalls, r.coverage.frames_ok * rain.TILES.length);
    /* 12 rainy half hours × ~2 mm/h × 0.5 h ≈ 12 mm */
    assert.ok(r.max_mm > 11 && r.max_mm < 13.5, `max ${r.max_mm}`);
    assert.ok(r.grid.cells.length > 0);
    const [lng, lat, mm, hours] = r.grid.cells[0];
    assert.ok(lng >= 46 && lng <= 47 && lat >= 24 && lat <= 25 && mm > 11);
    assert.ok(hours >= 4 && hours <= 12);
    assert.equal(r.tile_url, '/api/weather/rain/tile/1/{z}/{x}/{y}.png');
    assert.equal(r.legend.length, 5);
    const t = await rain.tile(1, 6, 40, 27, nowMs);
    assert.equal(t.status, 200);
    const png = PNG.sync.read(t.body);
    assert.ok(png.data[3] > 100, 'rain pixel drawn');
    assert.equal((await rain.tile(1, 2, 0, 0, nowMs)).status, 404);
  } finally {
    fetcher.setFetch(null);
    rain._reset();
  }
});

test('green: baseline date and greened rule', () => {
  assert.deepEqual(green.baselineDates('2026-11-05'), ['2026-06-20', '2026-07-20', '2026-08-25']);
  assert.equal(green.baselineDates('2027-02-10')[2], '2026-08-25');
  assert.ok(Math.abs(green.greenRise(0.3, 0.1) - 0.2) < 1e-9);
  assert.equal(green.greenRise(0.3, 0.28), 0); // farm green in August too
  assert.equal(green.greenRise(0.1, 0.0), 0); // too sparse
  const a = new Mosaic(green.Z);
  const b = new Mosaic(green.Z);
  const { x, y } = green.TILES[0];
  a.set(x, y, Float32Array.from([0.1, NaN, 0.3]));
  b.set(x, y, Float32Array.from([0.2, 0.4, NaN]));
  assert.deepEqual([...green.maxMosaic([a, b]).get(x, y)].map((v) => Math.round(v * 10) / 10), [0.2, 0.4, 0.3]);
  assert.ok(Number.isNaN(green.greenRise(NaN, 0.1)));
});

test('green: areas and tiles from faked VIIRS NDVI', async () => {
  green._reset();
  const ndvi = (v) => rgbOf('MODIS_NDVI', (e) => !e.nodata && e.lo <= v && e.hi > v);
  fetcher.setFetch(async (url) => {
    if (url.endsWith('.xml')) return { status: 200, type: 'text/xml', body: Buffer.from('<Domain>2026-10-01/2026-11-05/P1D</Domain>') };
    const isBase = /\/2026-0[678]-2\d\//.test(url);
    return { status: 200, type: 'image/png', body: solidPng(isBase ? ndvi(url.includes('-07-') ? 0.1 : 0.05) : ndvi(0.32)) };
  });
  try {
    const nowMs = Date.UTC(2026, 10, 7);
    const r = await green.areas({ bbox: { west: 46, south: 24, east: 46.2, north: 24.2 }, nowMs });
    assert.equal(r.ok, true);
    assert.equal(r.composite_date, '2026-11-05');
    assert.deepEqual(r.baseline_dates, ['2026-06-20', '2026-07-20', '2026-08-25']);
    assert.ok(r.grid.cells.length > 0);
    assert.ok(r.grid.cells[0][3] > 0.2);
    const t = await green.tile(8, 161, 110, nowMs);
    assert.equal(t.status, 200);
    assert.ok(PNG.sync.read(t.body).data[3] > 150);
  } finally {
    fetcher.setFetch(null);
    green._reset();
  }
});

function fakeRainSum(mm, lastBinMs) {
  const mosaic = new Mosaic(rain.Z);
  const last = new Mosaic(rain.Z);
  for (const { x, y } of rain.TILES) {
    mosaic.set(x, y, new Float32Array(65536).fill(0));
    last.set(x, y, new Float32Array(65536).fill(NaN));
  }
  /* Rain only around (24.5, 46.5). */
  const px = mercator.lngToX(46.5, rain.Z);
  const py = mercator.latToY(24.5, rain.Z);
  const tx = Math.floor(px / 256);
  const ty = Math.floor(py / 256);
  const i = Math.floor(py - ty * 256) * 256 + Math.floor(px - tx * 256);
  mosaic.get(tx, ty)[i] = mm;
  last.get(tx, ty)[i] = lastBinMs;
  return { mosaic, last, coverage: { frames_expected: 336, frames_ok: 336, frames_missing: 0 }, from: 0, to: lastBinMs };
}

test('desert search: intents, wording and ranking', async () => {
  assert.deepEqual(desert.parseIntents('مطر'), ['rain']);
  assert.deepEqual(desert.parseIntents('وين ربّع'), ['green']);
  assert.deepEqual(desert.parseIntents('مطر|ربيع'), ['rain', 'green']);
  assert.deepEqual(desert.parseIntents('بر'), ['rain', 'green']);
  assert.equal(desert.rainHeadline(12, 72), 'نزل مطر هنا قبل ٣ أيام (حوالي ١٢ ملم)');
  assert.equal(desert.greenHeadline(0.15), 'هنا خضّر');
  assert.ok(desert.rainScore(20, 24) > desert.rainScore(20, 140));
  assert.equal(desert.rainScore(0.5, 1), 0);

  const nowMs = Date.UTC(2026, 10, 7, 12);
  const places = [
    { id: 'places:1', kind: 'rawdah', name: 'روضة التنهات', lat: 24.5, lng: 46.5 },
    { id: 'places:2', kind: 'rawdah', name: 'روضة بعيدة', lat: 27.5, lng: 44.0 },
    { id: 'wells:3', kind: 'well', name: 'بئر', lat: 24.5, lng: 46.5 },
  ];
  const rainSum = fakeRainSum(18, nowMs - 3 * 24 * H - 1.5 * H);
  const r = await desert.search({ q: 'مطر', near: { lat: 24.7, lng: 46.7 }, radiusKm: 200, nowMs, deps: { places, rainSum, greenState: null } });
  assert.equal(r.ok, true);
  assert.deepEqual(r.intents, ['rain']);
  const top = r.results[0];
  assert.equal(top.name_ar, 'روضة التنهات');
  assert.equal(top.type, 'place');
  assert.equal(top.headline_ar, 'نزل مطر هنا قبل ٣ أيام (حوالي ١٨ ملم)');
  assert.equal(top.signals.rain_mm_7d, 18);
  assert.ok(top.distance_km > 20 && top.distance_km < 35);
  assert.ok(!r.results.some((x) => x.name_ar === 'روضة بعيدة'), 'outside radius');
  assert.ok(!r.results.some((x) => x.kind === 'well'), 'wells are not rain places');
  const area = r.results.find((x) => x.type === 'area');
  assert.ok(area && area.name_ar === 'منطقة قرب روضة التنهات');
  assert.ok(r.attribution.some((a) => /OpenStreetMap/.test(a)));
});

test('HTTP: weather + desert routes validate input', async () => {
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    let r = await fetch(`${base}/api/weather/rain/recent?days=2`);
    assert.equal(r.status, 400);
    assert.equal((await r.json()).error, 'bad_days');
    r = await fetch(`${base}/api/weather/rain/recent?days=1&bbox=0,0,1,1`);
    assert.equal(r.status, 400);
    r = await fetch(`${base}/api/desert/categories/search?q=مطر&near=0,0`);
    assert.equal(r.status, 400);
    r = await fetch(`${base}/api/weather/clouds/tile/bad/5/1/1.png`);
    assert.equal(r.status, 400);
  } finally {
    server.close();
  }
});
