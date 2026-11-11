'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const outdoor = require('./outdoor');

test('kindFromName only labels names that actually match the lexicon', () => {
  assert.equal(outdoor.kindFromName('روضة الخفس'), 'rawdah');
  assert.equal(outdoor.kindFromName('شعيب الثمامة'), 'shaib');
  assert.equal(outdoor.kindFromName('مطعم'), null);
});

test('queryFeatures never invents a coordinate and stays inside KSA', () => {
  const fc = outdoor.queryFeatures({ bbox: '45.2,24.2,47.6,25.8', zoom: 10, limit: 50 });
  assert.equal(fc.type, 'FeatureCollection');
  assert.equal(fc.source, 'osm');
  assert.ok(fc.count <= 50);
  for (const f of fc.features) {
    assert.ok(outdoor.validCoord(f.properties.lng, f.properties.lat));
    assert.equal(f.properties.source, 'osm');
    assert.ok(['public', 'unconfirmed'].includes(f.properties.evidence));
  }
});

test('around refuses an origin outside Saudi bounds', () => {
  const bad = outdoor.queryAround({ lng: 0, lat: 0 });
  assert.equal(bad.error, 'invalid_origin');
});

test('around around Riyadh uses only loaded OSM features', () => {
  const data = outdoor.queryAround({ lng: 46.6753, lat: 24.7136, radius: 20000 });
  assert.ok(data.summary);
  assert.equal(typeof data.summary.tracks, 'number');
  assert.equal(typeof data.summary.places, 'number');
  for (const f of data.features) {
    assert.ok(f.properties.distance_m <= 20000);
  }
});

test('search finds a real named well when the substring exists', () => {
  const wells = outdoor.queryFeatures({ types: 'well', limit: 5 });
  const named = wells.features.find((f) => f.properties.name);
  if (!named) {
    assert.ok(true, 'no named well in extract — nothing to invent');
    return;
  }
  const q = String(named.properties.name).slice(0, 4);
  const hit = outdoor.searchFeatures(q);
  assert.ok(hit.features.some((f) => f.properties.id === named.properties.id));
});

test('category intent returns only observed features of that type', () => {
  assert.deepEqual(outdoor.categoryIntent('وين نفود').kinds, ['nafud']);
  assert.equal(outdoor.categoryIntent('وين نفود').categoryOnly, true);
  assert.deepEqual(outdoor.categoryIntent('وين أقرب نفود؟').kinds, ['nafud']);
  const hits = outdoor.searchFeatures('وين نفود', 40);
  assert.ok(hits.count > 0, 'the OSM extract contains some explicitly named nafud features');
  assert.ok(hits.features.every((f) => f.properties.kind === 'nafud'));
  const named = outdoor.searchFeatures('نفود الغويطة', 40);
  assert.ok(named.features.every((f) => f.properties.kind === 'nafud' && /الغويطة/.test(f.properties.name || '')),
    'a specific desert name keeps the category constraint while narrowing by name');
});

test('search with a user location sorts nearest-first and returns measured distances', () => {
  const me = { lat: 24.7136, lng: 46.6753 };
  const hits = outdoor.searchFeatures('نفود', 40, me);
  assert.ok(hits.features.length > 1);
  const distances = hits.features.map((f) => f.properties.distance_m);
  assert.ok(distances.every(Number.isFinite));
  assert.deepEqual(distances, [...distances].sort((a, b) => a - b));
});

test('outdoor search route validates the optional user location', async () => {
  const express = require('express');
  const app = express();
  app.use('/api/outdoor', require('../routes/outdoor')());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}/api/outdoor/search`;
  try {
    const ok = await fetch(`${base}?q=${encodeURIComponent('نفود')}&near=24.7136,46.6753`);
    assert.equal(ok.status, 200);
    const body = await ok.json();
    assert.ok(body.features.length > 0);
    assert.ok(body.features.every((f) => f.properties.kind === 'nafud' && Number.isFinite(f.properties.distance_m)));
    const bad = await fetch(`${base}?q=${encodeURIComponent('نفود')}&near=0,0`);
    assert.equal(bad.status, 400);
  } finally {
    server.close();
  }
});

test('getFeature 404s on a made-up id', () => {
  assert.equal(outdoor.getFeature('well:not-a-real-osm-id'), null);
});

test('fuel stations load from fuel.geojson when present, as kind fuel (ODbL)', () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const { convert } = require('../scripts/build-outdoor-fuel');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sary-fuel-'));
  try {
    const fc = convert({
      elements: [
        { type: 'node', id: 1, lat: 25.21, lon: 46.62, tags: { amenity: 'fuel', name: 'محطة الثمامة', brand: 'ساسكو' } },
        { type: 'way', id: 2, center: { lat: 25.4, lon: 46.7 }, tags: { amenity: 'fuel' } },
        { type: 'node', id: 3, lat: 51.5, lon: -0.1, tags: { amenity: 'fuel', name: 'London' } },
        { type: 'node', id: 4, lat: 25.3, lon: 46.6, tags: { amenity: 'cafe' } },
      ],
    });
    assert.equal(fc.features.length, 2, 'outside KSA and non-fuel are dropped');
    assert.equal(fc.features[1].properties.name, null, 'an unnamed station stays unnamed');
    fs.writeFileSync(path.join(dir, 'fuel.geojson'), JSON.stringify(fc));
    outdoor.__reset({ dataDir: dir });
    const hits = outdoor.queryFeatures({ types: 'fuel' });
    assert.equal(hits.count, 2);
    const named = hits.features.find((f) => f.properties.name);
    assert.equal(named.properties.kind, 'fuel');
    assert.equal(named.properties.group, 'place');
    assert.equal(named.properties.brand, 'ساسكو');
    assert.equal(named.properties.license, 'ODbL');
    const around = outdoor.queryAround({ lng: 46.62, lat: 25.2, radius: 5000 });
    assert.equal(around.summary.nearest_fuel.properties.name, 'محطة الثمامة');
  } finally {
    outdoor.__reset();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('without fuel.geojson there are simply no fuel features', () => {
  outdoor.__reset();
  const fs = require('fs');
  const path = require('path');
  if (fs.existsSync(path.join(__dirname, '../data/outdoor/fuel.geojson'))) return;
  assert.equal(outdoor.queryFeatures({ types: 'fuel' }).count, 0);
});

test('a box over the cap keeps the features nearest its centre', () => {
  outdoor.__reset();
  const all = outdoor.queryFeatures({ bbox: '46.2,24.2,47.2,25.2', types: 'fuel,well,spring', limit: 1000 });
  if (!all.truncated) return; // no dense data loaded: nothing to cap
  assert.equal(all.count, 400);
  const c = { lng: 46.7, lat: 24.7 };
  const d = (f) => Math.hypot(f.properties.lng - c.lng, f.properties.lat - c.lat);
  const far = Math.max(...all.features.map(d));
  const inner = outdoor.queryFeatures({ bbox: '46.6,24.6,46.8,24.8', types: 'fuel,well,spring', limit: 1000 });
  for (const f of inner.features) if (d(f) < far * 0.9) assert.ok(all.features.some((g) => g.id === f.id), 'a near feature is never dropped for a far one');
});
