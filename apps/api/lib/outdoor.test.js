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
