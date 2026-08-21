'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  getCityOpportunities,
  normalizeCity,
  rowToFeature,
  tierForGap,
  MIN_AREA_COMPARISONS,
  __resetCityCacheForTests,
} = require('./city-opportunities');

const ROW = {
  place_id: '5454',
  canonical_name_ar: 'توينا',
  canonical_name_en: 'Twina',
  latitude: 24.7264,
  longitude: 46.6427,
  provider_count: 4,
  rating: 4.2,
  item_id: '99',
  cheapest_provider: 'hungerstation',
  dearest_provider: 'jahez',
  cheapest_price: 28,
  dearest_price: 41,
  gap: 13,
  product_name: 'شاورما عربي',
  wins: { hungerstation: 3, jahez: 1 },
  comparisons: 4,
};

test('tierForGap follows the approved thresholds and never invents a tier', () => {
  assert.equal(tierForGap(36), 'hero');
  assert.equal(tierForGap(35), 'strong');
  assert.equal(tierForGap(15), 'strong');
  assert.equal(tierForGap(14), 'regular');
  assert.equal(tierForGap(5), 'regular');
  assert.equal(tierForGap(4), 'faint');
  assert.equal(tierForGap(0), null);
  assert.equal(tierForGap(null), null);
});

test('normalizeCity accepts known keys only', () => {
  assert.equal(normalizeCity('Riyadh'), 'riyadh');
  assert.equal(normalizeCity(' riyadh '), 'riyadh');
  assert.equal(normalizeCity('الرياض'), null);
  assert.equal(normalizeCity('atlantis'), null);
});

test('rowToFeature keeps observed fields, derives pct/tier/h3, drops invalid rows', () => {
  const f = rowToFeature(ROW);
  assert.equal(f.properties.place_id, '5454');
  assert.equal(f.properties.gap, 13);
  assert.equal(f.properties.pct, 32);
  assert.equal(f.properties.tier, 'regular');
  assert.equal(f.properties.cheapest_provider_id, 'hungerstation');
  assert.equal(f.properties.expensive_provider_id, 'jahez');
  assert.equal(f.properties.has_difference, true);
  assert.equal('observed_at' in f.properties, false, 'no per-place freshness exists in the source');
  assert.deepEqual(f.geometry.coordinates, [46.6427, 24.7264]);

  assert.equal(rowToFeature({ ...ROW, latitude: null }), null);
  assert.equal(rowToFeature({ ...ROW, place_id: 'FARQ-PLACE-1' }), null);
  assert.equal(rowToFeature({ ...ROW, latitude: 51.5, longitude: -0.1 }), null, 'outside KSA');
});

test('a restaurant without a gap is kept but says so — nothing is invented', () => {
  const f = rowToFeature({ ...ROW, gap: null, cheapest_provider: null, dearest_price: null, cheapest_price: null, product_name: null });
  assert.equal(f.properties.has_difference, false);
  assert.equal(f.properties.gap, null);
  assert.equal(f.properties.tier, null);
  assert.equal(f.properties.cheapest_provider_id, null);
  assert.equal(f.properties.product_name, null);
});

test('getCityOpportunities filters to opportunities by default and exposes include=all', async () => {
  __resetCityCacheForTests();
  const calls = [];
  const __query = async (sql, params) => {
    calls.push({ sql, params });
    if (/read_layer_meta/.test(sql)) return [{ generated_at: '2026-08-16T06:40:22.854Z' }];
    return [ROW, { ...ROW, place_id: '7', gap: null, cheapest_provider: null }];
  };
  const opp = await getCityOpportunities({ city: 'riyadh', __query });
  assert.equal(opp.body.count, 1);
  assert.equal(opp.body.features[0].properties.place_id, '5454');
  assert.equal(opp.body.generated_at, '2026-08-16T06:40:22.854Z');
  assert.equal(opp.body.freshness, 'read_layer');
  assert.equal(opp.body.consumer_price_cap_sar, 200);
  assert.match(opp.etag, /^W\//);
  const citySql = calls.find((c) => /discovery_cards/.test(c.sql));
  assert.deepEqual(citySql.params[0], ['riyadh', 'الرياض']);
  assert.equal(citySql.params[1], 200, 'consumer cap is bound, not interpolated');
  assert.match(citySql.sql, /dearest_price <= \$2/);

  const all = await getCityOpportunities({ city: 'riyadh', include: 'all', __query });
  assert.equal(all.body.count, 2);
  assert.notEqual(all.etag, opp.etag);
});

test('getCityOpportunities returns null for an unknown city', async () => {
  assert.equal(await getCityOpportunities({ city: 'gotham', __query: async () => [] }), null);
});

const { getCityDistricts } = require('./city-opportunities');
const { districtOfPoint } = require('./city-districts');

test('every city opportunity carries the حي its coordinates fall in, and the districts aggregate it', async () => {
  const __query = async (sql) => (/read_layer_meta/.test(sql) ? [] : [ROW]);
  const city = await getCityOpportunities({ city: 'riyadh', __query });
  const f = city.body.features[0];
  const expected = districtOfPoint('riyadh', ROW.longitude, ROW.latitude);
  assert.equal(typeof expected, 'string');
  assert.equal(f.properties.district_id, expected);
  assert.match(city.etag, /^W\/"v4-riyadh-/);

  const d = await getCityDistricts({ city: 'riyadh', __query });
  assert.equal(d.body.count, 187);
  assert.equal(d.body.source, 'momrah_administrative_districts');
  const hit = d.body.features.find((x) => x.properties.district_id === expected);
  assert.ok(hit.properties.name_ar && hit.properties.name_en);
  assert.ok(Array.isArray(hit.properties.label_point) && hit.properties.label_point.length === 2);
  assert.equal(districtOfPoint('riyadh', hit.properties.label_point[0], hit.properties.label_point[1]), expected, 'the label point is inside its own حي');
  assert.equal(hit.geometry.type === 'Polygon' || hit.geometry.type === 'MultiPolygon', true);
  assert.equal(hit.properties.places, 1);
  assert.equal(hit.properties.opportunities, 1);
  assert.equal(hit.properties.max_gap, 13);
  assert.equal(hit.properties.top_place_id, '5454');
  assert.equal(hit.properties.comparisons, 4);
  assert.equal(hit.properties.cheapest_app, null, 'four comparisons never name a winner');
  assert.equal(d.body.features[0].properties.district_id, expected, 'busiest حي first');
  const empty = d.body.features.find((x) => x.properties.district_id !== expected);
  assert.equal(empty.properties.opportunities, 0);
  assert.equal(empty.properties.max_gap, null);
  assert.equal(empty.properties.top_place_id, null);
});

test('a point outside every حي is counted nowhere, and an unknown city has no districts', async () => {
  const far = { ...ROW, place_id: '7', latitude: 25.9, longitude: 49.9 };
  const __query = async (sql) => (/read_layer_meta/.test(sql) ? [] : [far]);
  const city = await getCityOpportunities({ city: 'riyadh', __query });
  assert.equal(city.body.features[0].properties.district_id, null);
  const d = await getCityDistricts({ city: 'riyadh', __query });
  assert.equal(d.body.features.reduce((n, x) => n + x.properties.opportunities, 0), 0);
  assert.equal(await getCityDistricts({ city: 'atlantis', __query }), null);
});
