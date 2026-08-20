'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  aggregateAreas,
  getCityAreas,
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
  assert.match(f.properties.h3, /^88/); // res 8 cell index prefix
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

test('aggregateAreas counts per H3 cell and only names a cheapest app with enough comparisons', () => {
  const a = rowToFeature(ROW);
  const b = rowToFeature({ ...ROW, place_id: '2', gap: 40, dearest_price: 70, cheapest_price: 30, wins: { jahez: 6 }, comparisons: 6 });
  const far = rowToFeature({ ...ROW, place_id: '3', latitude: 24.9, longitude: 46.9, wins: { mrsool: 2 }, comparisons: 2 });
  const areas = aggregateAreas([a, b, far]);
  assert.equal(areas.length, 2);
  const big = areas[0];
  assert.equal(big.properties.opportunities, 2);
  assert.equal(big.properties.max_gap, 40);
  assert.equal(big.properties.top_place_id, '2');
  assert.equal(big.properties.comparisons, 10);
  assert.ok(big.properties.comparisons >= MIN_AREA_COMPARISONS);
  assert.equal(big.properties.cheapest_app, 'jahez');
  assert.equal(big.properties.cheapest_app_wins, 7);
  const small = areas[1];
  assert.equal(small.properties.enough_for_app_verdict, false);
  assert.equal(small.properties.cheapest_app, null, 'two comparisons do not make a verdict');
  assert.equal(big.geometry.type, 'Polygon');
  assert.equal(big.geometry.coordinates[0].length, 7, 'closed hexagon ring');
});

test('getCityAreas wraps the aggregate as a FeatureCollection', async () => {
  __resetCityCacheForTests();
  const __query = async (sql) => (/read_layer_meta/.test(sql) ? [] : [ROW]);
  const areas = await getCityAreas({ city: 'riyadh', __query });
  assert.equal(areas.body.type, 'FeatureCollection');
  assert.equal(areas.body.resolution, 8);
  assert.equal(areas.body.count, 1);
  assert.equal(areas.body.min_comparisons_for_app_verdict, 8);
});
