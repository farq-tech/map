'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  districtCities,
  districtOfPoint,
  findDistrictByName,
  interiorPoint,
  loadDistricts,
  nameKeys,
  __resetDistrictCacheForTests,
} = require('./city-districts');

/* Two أحياء side by side; A has a hole; C has no Arabic name and must be dropped. */
const FIXTURE = {
  type: 'FeatureCollection',
  source: 'fixture',
  features: [
    {
      type: 'Feature',
      properties: { district_id: 'A', name_ar: 'العليا', name_en: 'Al Olaya' },
      geometry: {
        type: 'Polygon',
        coordinates: [
          [[46.6, 24.6], [46.7, 24.6], [46.7, 24.7], [46.6, 24.7], [46.6, 24.6]],
          [[46.64, 24.64], [46.66, 24.64], [46.66, 24.66], [46.64, 24.66], [46.64, 24.64]],
        ],
      },
    },
    {
      type: 'Feature',
      properties: { district_id: 'B', name_ar: 'السليمانية', name_en: 'Al Sulaimaniyah' },
      geometry: {
        type: 'MultiPolygon',
        coordinates: [[[[46.7, 24.6], [46.8, 24.6], [46.8, 24.7], [46.7, 24.7], [46.7, 24.6]]]],
      },
    },
    {
      type: 'Feature',
      properties: { district_id: 'C', name_ar: '', name_en: 'Nameless' },
      geometry: { type: 'Polygon', coordinates: [[[46.8, 24.6], [46.9, 24.6], [46.9, 24.7], [46.8, 24.6]]] },
    },
  ],
};
const opts = { __fixture: FIXTURE };

test.beforeEach(() => __resetDistrictCacheForTests());

test('loads named districts only and keeps both names', () => {
  const loaded = loadDistricts('fixture', opts);
  assert.equal(loaded.count, 2);
  assert.deepEqual([...loaded.byId.keys()], ['A', 'B']);
  assert.equal(loaded.source, 'fixture');
  assert.equal(loadDistricts('', opts), null);
});

test('membership is geometric: inside, in a hole, in the neighbour, outside, garbage', () => {
  assert.equal(districtOfPoint('fixture', 46.62, 24.62, opts), 'A');
  assert.equal(districtOfPoint('fixture', 46.65, 24.65, opts), null, 'a point in the hole belongs nowhere');
  assert.equal(districtOfPoint('fixture', 46.75, 24.65, opts), 'B');
  assert.equal(districtOfPoint('fixture', 46.95, 24.95, opts), null);
  assert.equal(districtOfPoint('fixture', 'x', 24.65, opts), null);
});

test('a name is found with or without حي / ال / Al, across hamza and taa marbuta', () => {
  for (const q of ['العليا', 'حي العليا', 'عليا', 'Al Olaya', 'olaya', 'OLAYA']) {
    assert.equal(findDistrictByName('fixture', q, opts)?.district_id, 'A', q);
  }
  assert.equal(findDistrictByName('fixture', 'السليمانيه', opts)?.district_id, 'B');
  assert.equal(findDistrictByName('fixture', 'سليمان', opts)?.district_id, 'B', 'unique prefix');
  assert.equal(findDistrictByName('fixture', 'xyz', opts), null);
  assert.equal(findDistrictByName('fixture', '', opts), null);
  assert.deepEqual(nameKeys('حي النرجس'), ['حي النرجس', 'النرجس', 'نرجس']);
});

test('interiorPoint lands inside the polygon it names', () => {
  const pt = interiorPoint('fixture', 'A', opts);
  assert.ok(pt);
  assert.equal(districtOfPoint('fixture', pt[0], pt[1], opts), 'A');
  assert.equal(interiorPoint('fixture', 'Z', opts), null);
});

test('the committed Riyadh boundaries load: 187 أحياء, every one named with a readable id, and a city point resolves', () => {
  const riyadh = loadDistricts('riyadh');
  assert.ok(riyadh);
  assert.equal(riyadh.count, 187);
  assert.ok(riyadh.features.every((f) => f.properties.name_ar && f.properties.name_en && /^riyadh-[a-z0-9-]+$/.test(f.properties.district_id)));
  assert.ok(riyadh.prepared.every((d) => Array.isArray(d.label_point)), 'every حي has a label point');
  assert.equal(typeof districtOfPoint('riyadh', 46.6753, 24.7136), 'string');
  assert.equal(findDistrictByName('riyadh', 'حي النرجس')?.district_id, 'riyadh-al-narjas');
  /* The source splits العليا into three polygons; a person means one حي. */
  const olaya = riyadh.byId.get('riyadh-al-olaya');
  assert.equal(olaya.feature.geometry.type, 'MultiPolygon');
  assert.equal(olaya.feature.properties.source_codes.length, 3);
  assert.equal(olaya.polys.length, 3);
  assert.ok(districtCities().includes('riyadh'));
  assert.equal(loadDistricts('atlantis'), null);
});
