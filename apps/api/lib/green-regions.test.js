'use strict';

/* «أقرب ربيع»: greened cells clustered into regions, named by the nearest OSM روضة/فيضة, and the
 * HTTP contract. No network: the VIIRS state is faked. */

process.env.WEATHER_WARM = '0';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');

const gr = require('./weather/green-regions');
const green = require('./weather/green');
const { Mosaic } = require('./weather/raster');
const mercator = require('./weather/mercator');

const S = gr.STEP;
/** A w×h block of cells (rise r) whose lower-left cell is (lng, lat), on the 0.01° grid. */
function block(lng, lat, w, h, r = 0.15) {
  const out = [];
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) out.push([+(lng + i * S).toFixed(2), +(lat + j * S).toFixed(2), r]);
  return out;
}

test('green regions: two blobs give two regions, a lone pixel is dropped', () => {
  const cells = [...block(46.0, 25.0, 3, 3), ...block(46.5, 25.0, 4, 2, 0.25), [47.0, 25.5, 0.3]];
  const regions = gr.clusterRegions(cells);
  assert.equal(regions.length, 2);
  assert.deepEqual(regions.map((r) => r.cells).sort(), [8, 9]);
  for (const r of regions) {
    assert.match(r.id, /^gr_[0-9a-f]{10}$/);
    assert.ok(r.points.length > 0 && r.points.length <= gr.MAX_POINTS);
    assert.equal(r.bbox.length, 4);
    assert.ok(r.bbox[0] < r.centroid[0] && r.centroid[0] < r.bbox[2]);
    assert.ok(!('_members' in JSON.parse(JSON.stringify(r))));
  }
  const nine = regions.find((r) => r.cells === 9);
  assert.deepEqual(nine.centroid, [46.01, 25.01]);
  assert.deepEqual(nine.bbox, [45.995, 24.995, 46.025, 25.025]);
  /* Below-threshold cells never join. */
  assert.equal(gr.clusterRegions(block(46, 25, 5, 5, 0.05)).length, 0);
  /* Stable id: same centroid, same id. */
  assert.equal(gr.clusterRegions(block(46.0, 25.0, 3, 3))[0].id, nine.id);
});

test('green regions: diagonal neighbours join (8-connectivity)', () => {
  const diag = [[46.0, 25.0, 0.1], [46.01, 25.01, 0.1], [46.02, 25.02, 0.1], [46.03, 25.03, 0.1]];
  const regions = gr.clusterRegions(diag);
  assert.equal(regions.length, 1);
  assert.equal(regions[0].cells, 4);
  /* A one-cell gap splits them, and each half is too small. */
  assert.equal(gr.clusterRegions([[46.0, 25.0, 0.1], [46.01, 25.01, 0.1], [46.03, 25.03, 0.1], [46.04, 25.04, 0.1]]).length, 0);
});

test('green regions: area maths at lat 25 and the minimum area', () => {
  const a = gr.cellAreaKm2(25);
  /* 0.01° ≈ 1.112 km; × cos 25° ≈ 0.906 → ≈ 1.121 km². */
  assert.ok(Math.abs(a - 1.1206) < 0.002, `cell area ${a}`);
  assert.ok(gr.cellAreaKm2(30) < a && gr.cellAreaKm2(20) > a);
  const [r] = gr.clusterRegions(block(46, 25, 10, 10));
  assert.ok(Math.abs(r.area_km2 - 112.1) <= 0.3, `area ${r.area_km2}`);
  /* 2 cells ≈ 2.24 km² < 3 km² dropped; 3 cells ≈ 3.36 km² kept. */
  assert.equal(gr.clusterRegions(block(46, 25, 2, 1)).length, 0);
  assert.equal(gr.clusterRegions(block(46, 25, 3, 1)).length, 1);
  assert.equal(gr.clusterRegions(block(46, 25, 2, 1), { minAreaKm2: 2 }).length, 1);
});

test('green regions: level labels from mean rise', () => {
  assert.deepEqual(gr.levelOf(0.06), { level: 'start', label_ar: 'بداية خضرة' });
  assert.deepEqual(gr.levelOf(0.119), { level: 'start', label_ar: 'بداية خضرة' });
  assert.deepEqual(gr.levelOf(0.12), { level: 'clear', label_ar: 'ربيع واضح' });
  assert.deepEqual(gr.levelOf(0.25), { level: 'dense', label_ar: 'ربيع كثيف' });
  assert.equal(gr.levelOf(0.05), null);
  const [r] = gr.clusterRegions([...block(46, 25, 2, 2, 0.1), ...block(46.02, 25, 2, 2, 0.2)]);
  assert.equal(r.mean_rise, 0.15);
  assert.equal(r.max_rise, 0.2);
  assert.equal(r.level, 'clear');
  assert.equal(r.label_ar, 'ربيع واضح');
});

test('green regions: points are capped and edge-first', () => {
  const [r] = gr.clusterRegions(block(46, 25, 30, 30));
  assert.equal(r.points.length, gr.MAX_POINTS);
  const [small] = gr.clusterRegions(block(46, 25, 3, 3));
  assert.equal(small.points.length, 9);
  assert.deepEqual(small.points.slice(-1), [[46.01, 25.01]], 'the interior cell comes after the edge');
});

test('green regions: place attaches only within 5 km and never from gm: rows', () => {
  const [region] = gr.clusterRegions(block(46, 25, 4, 4));
  const kmLng = 111.195 * Math.cos((25 * Math.PI) / 180);
  const east = (km) => +(46.03 + km / kmLng).toFixed(5);
  const places = [
    { id: 'gm:abc', kind: 'rawdah', name: 'روضة من قوقل', lng: 46.015, lat: 25.015, phone: '0500000000' },
    { id: 'places:2', kind: 'well', name: 'بئر', lng: 46.02, lat: 25.02 },
    { id: 'places:3', kind: 'fayad', name: 'فيضة بعيدة', lng: east(6), lat: 25.015 },
    { id: 'places:4', kind: 'rawdah', name: 'روضة خريم', lng: east(4), lat: 25.015 },
  ];
  const p = gr.nearestPlace(region, places);
  assert.deepEqual(Object.keys(p).sort(), ['distance_km', 'kind', 'name']);
  assert.equal(p.name, 'روضة خريم');
  assert.equal(p.kind, 'rawdah');
  assert.ok(Math.abs(p.distance_km - 4) <= 0.1, `distance from the nearest cell, not the centroid: ${p.distance_km}`);
  assert.equal(gr.nearestPlace(region, places.filter((x) => x.id !== 'places:4')), null, 'gm: skipped, 6 km too far');
  assert.equal(gr.usablePlace({ id: 'x', key: 'gm:1', kind: 'rawdah', name: 'r', lng: 46, lat: 25 }), false);
  /* Inside the region: distance 0. */
  const inside = gr.nearestPlace(region, [{ id: 'places:5', kind: 'rawdah', name: 'روضة', lng: 46.02, lat: 25.02 }]);
  assert.equal(inside.distance_km, 0);
});

test('green regions: ranking favours big, green and named; capped at 40', () => {
  const big = block(46, 25, 6, 6, 0.1); // ≈ 40 km² × 0.1
  const small = block(46.5, 25, 4, 4, 0.1); // ≈ 18 km² × 0.1, × 1.5 named → still below
  const named = block(47, 25, 5, 5, 0.1); // ≈ 28 km² × 0.1 × 1.5 = 4.2 > 4.0
  const places = [{ id: 'places:1', kind: 'rawdah', name: 'روضة نورة', lng: 47.02, lat: 25.02 }];
  const r = gr.rankRegions([...small, ...big, ...named], places);
  assert.deepEqual(r.map((x) => x.cells), [25, 36, 16]);
  assert.equal(r[0].place.name, 'روضة نورة');
  assert.equal(r[1].place, null);
  const many = [];
  for (let k = 0; k < 50; k++) many.push(...block(40 + k * 0.1, 25, 2, 2));
  assert.equal(gr.rankRegions(many, []).length, gr.MAX_REGIONS);
});

function fakeState() {
  /* Current NDVI 0.4 on a 6×6-pixel patch near (25.0, 46.0), baseline 0.1 everywhere. */
  const cur = new Mosaic(green.Z);
  const bas = new Mosaic(green.Z);
  for (const { x, y } of green.TILES) {
    cur.set(x, y, new Float32Array(65536).fill(0.1));
    bas.set(x, y, new Float32Array(65536).fill(0.1));
  }
  const px0 = Math.floor(mercator.lngToX(46.0, green.Z));
  const py0 = Math.floor(mercator.latToY(25.0, green.Z));
  for (let dy = 0; dy < 6; dy++) {
    for (let dx = 0; dx < 6; dx++) {
      const px = px0 + dx;
      const py = py0 + dy;
      const tx = Math.floor(px / 256);
      const ty = Math.floor(py / 256);
      cur.get(tx, ty)[(py - ty * 256) * 256 + (px - tx * 256)] = 0.4;
    }
  }
  return { ymd: '2026-11-05', base: '2026-06-20,2026-07-20,2026-08-25', cur, bas };
}

test('green regions: regions() envelope from a faked VIIRS state', async () => {
  const places = [
    { id: 'places:9', kind: 'rawdah', name: 'روضة التنهات', lng: 46.03, lat: 24.98 },
    { id: 'gm:9', kind: 'rawdah', name: 'Google', lng: 46.03, lat: 24.98 },
  ];
  const r = await gr.regions({ bbox: { west: 45.8, south: 24.8, east: 46.3, north: 25.2 }, deps: { state: fakeState(), places }, nowMs: Date.UTC(2026, 10, 7) });
  assert.equal(r.ok, true);
  assert.equal(r.composite_date, '2026-11-05');
  assert.equal(r.attribution, green.ATTRIBUTION);
  for (const k of ['licence', 'note_ar', 'generated_at']) assert.ok(r[k], k);
  assert.equal(r.regions.length, 1);
  const g = r.regions[0];
  assert.ok(g.area_km2 >= 30 && g.area_km2 <= 50, `area ${g.area_km2}`);
  assert.equal(g.level, 'dense');
  assert.equal(g.place.name, 'روضة التنهات');
  assert.ok(!JSON.stringify(r).includes('Google'));

  const warming = await gr.regions({ bbox: { west: 46, south: 25, east: 46.1, north: 25.1 }, deps: { state: null } });
  assert.deepEqual([warming.ok, warming.error], [false, 'warming']);
});

test('HTTP: /weather/green/regions rejects a bad or too-large bbox', async () => {
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const q of ['', '?bbox=abc', '?bbox=0,0,1,1', '?bbox=46,25,46,26']) {
      const r = await fetch(`${base}/api/weather/green/regions${q}`);
      assert.equal(r.status, 400, q);
      const body = await r.json();
      assert.equal(body.error, 'bad_bbox', q);
      assert.ok(body.message_ar);
    }
    const r = await fetch(`${base}/api/weather/green/regions?bbox=44,24,47.5,26`);
    assert.equal(r.status, 400);
    const body = await r.json();
    assert.equal(body.error, 'bbox_too_large');
    assert.ok(body.message_ar);
  } finally {
    server.close();
  }
});
