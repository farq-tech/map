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
