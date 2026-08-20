'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const {
  queryVisibleOpportunities,
  parseViewportBbox,
  slimOpportunity,
  SLIM_OPPORTUNITY_KEYS,
  RIYADH_VIEW,
} = require('./comparison-map');

const RIYADH_ALL = { west: 46.45, south: 24.45, east: 47.05, north: 25.05 };
const VIEWPORT = '46.72,24.70,46.82,24.80';

describe('queryVisibleOpportunities — viewport + slim JSON', () => {
  it('queries the request viewport bbox, not all of Riyadh', async () => {
    const captured = [];
    const parsed = parseViewportBbox(VIEWPORT);
    const result = await queryVisibleOpportunities({
      bbox: VIEWPORT,
      __query: async (_sql, params) => {
        captured.push(params);
        return [];
      },
    });
    assert.ok(parsed);
    assert.notDeepEqual(result.queried_bbox, RIYADH_VIEW.bbox);
    assert.notDeepEqual(result.queried_bbox, RIYADH_ALL);
    assert.deepEqual(result.queried_bbox, parsed);
    assert.equal(captured.length, 1);
    assert.equal(captured[0][0], parsed.south);
    assert.equal(captured[0][1], parsed.north);
    assert.equal(captured[0][2], parsed.west);
    assert.equal(captured[0][3], parsed.east);
  });

  it('empty / invalid bbox does not fall back to Riyadh', async () => {
    let queried = false;
    const result = await queryVisibleOpportunities({
      bbox: '',
      __query: async () => {
        queried = true;
        return [];
      },
    });
    assert.equal(result.empty_reason, 'invalid_bbox');
    assert.equal(result.queried_bbox, null);
    assert.deepEqual(result.opportunities, []);
    assert.equal(result.requested_bbox, null);
    assert.notDeepEqual(result.requested_bbox, RIYADH_VIEW.bbox);
    assert.equal(queried, false);
  });

  it('slims to observed fields only — no raw FeatureCollection payload', () => {
    const slim = slimOpportunity({
      name: 'شاورما هوم',
      cheapest_provider: 'hungerstation',
      dearest_provider: 'jahez',
      cheapest_price: 18,
      dearest_price: 29,
      difference_amount: 11,
      lat: 24.71,
      lng: 46.67,
      restaurant_id: '123',
      image_url: 'https://example.test/x.jpg',
      product_name: 'وجبة',
      has_difference: true,
      provider_count: 3,
    });
    assert.deepEqual(Object.keys(slim).sort(), [...SLIM_OPPORTUNITY_KEYS].sort());
    assert.equal(slim.place, 'شاورما هوم');
    assert.equal(slim.highest_price, 29);
    assert.equal(slim.item, 'وجبة');
    assert.equal(slim.expensive_provider, 'jahez');
    assert.equal(slim.restaurant_id, undefined);
    assert.equal(slim.image_url, undefined);
    assert.equal(slim.features, undefined);
    assert.equal(slim.type, undefined);
  });
});

describe('querySourceOpportunities — Farq comparison source', () => {
  const { querySourceOpportunities } = require('./comparison-map');

  it('filters item_price_spread by burger terms and sorts cheapest first', async () => {
    const captured = [];
    const result = await querySourceOpportunities({
      bbox: '46.74,24.76,46.78,24.80',
      qTerms: ['برجر', 'burger'],
      sort: 'cheapest',
      __query: async (sql, params) => {
        captured.push({ sql, params });
        return [
          {
            restaurant_id: '42',
            canonical_name_ar: 'برجر ستيشن',
            latitude: 24.77,
            longitude: 46.76,
            cheapest_provider: 'hungerstation',
            dearest_provider: 'jahez',
            cheapest_price: 22,
            dearest_price: 31,
            difference_amount: 9,
            product_name: 'برجر كلاسيك',
          },
          {
            restaurant_id: '43',
            canonical_name_ar: 'برجر كنج',
            latitude: 24.771,
            longitude: 46.761,
            cheapest_provider: 'jahez',
            dearest_provider: 'hungerstation',
            cheapest_price: 18,
            dearest_price: 27,
            difference_amount: 9,
            product_name: 'Whopper',
          },
        ];
      },
    });
    assert.equal(captured.length, 1);
    assert.match(captured[0].sql, /item_price_spread/);
    assert.deepEqual(captured[0].params[8], ['برجر', 'burger']);
    assert.equal(result.opportunities[0].place, 'برجر كنج');
    assert.equal(result.opportunities[0].cheapest_price, 18);
    assert.equal(result.opportunities[0].item, 'Whopper');
    assert.equal(result.sort, 'cheapest');
  });
});
