'use strict';

/**
 * The proof table behind a pin. These tests never touch Postgres: the row
 * mapper is pure, and getPlaceItems takes an injected `__query`, so what is
 * asserted here is the honesty contract — an app we never observed pricing an
 * item is absent from that item's prices, not null and not zero.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  PLACE_ITEMS_CAP,
  getPlaceItems,
  rowToPlaceItem,
  rowToPlaceProvider,
  sortPlaceItems,
} = require('./comparison-map');

const HEAD = {
  place_id: '45537',
  canonical_name_ar: 'ايتوال',
  canonical_name_en: 'Etoile',
  city: 'riyadh',
  provider_count: 4,
};

const ITEM_ROW = {
  item_id: '492777',
  name_ar: 'علبة ميتال كبيره اورجينال',
  name_en: 'Original Large Metal Box',
  provider_count: 3,
  cheapest_price: '105.00',
  dearest_price: '195.00',
  typical_price: '180',
  prices: { jahez: 195, ninja: 105, toyou: 180 },
};

const SAME_PRICE_ROW = {
  item_id: '492822',
  name_ar: 'اكلير روشيه اوريجنال',
  name_en: 'Eclair Rocher',
  provider_count: 2,
  cheapest_price: '13.00',
  dearest_price: '13.00',
  typical_price: null,
  prices: { ninja: 13, toyou: 13 },
};

function fakeQuery({ head = [HEAD], providers = [], items = [], calls } = {}) {
  return async (sql, params) => {
    if (calls) calls.push({ sql, params });
    if (/read_layer_meta/.test(sql)) return [{ generated_at: '2026-08-16T06:40:22.854Z' }];
    if (/restaurant_providers/.test(sql)) return providers;
    if (/menu_item_offers/.test(sql)) return items;
    return head;
  };
}

test('rowToPlaceItem derives gap and pct from the observed cheapest and dearest', () => {
  const item = rowToPlaceItem(ITEM_ROW);
  assert.equal(item.item_id, '492777');
  assert.equal(item.cheapest_price, 105);
  assert.equal(item.expensive_price, 195);
  assert.equal(item.gap, 90);
  assert.equal(item.pct, 46); // (195 - 105) / 195
  assert.equal(item.cheapest_provider_id, 'ninja');
  assert.equal(item.expensive_provider_id, 'jahez');
  assert.equal(item.typical_price, 180);
  assert.equal(item.name, 'علبة ميتال كبيره اورجينال', 'Arabic name leads');
});

test('halalas survive; a price we never observed stays null instead of becoming zero', () => {
  const item = rowToPlaceItem({
    ...ITEM_ROW,
    typical_price: null,
    prices: { ninja: '10.50', toyou: '18.00' },
  });
  assert.equal(item.cheapest_price, 10.5);
  assert.equal(item.gap, 7.5);
  assert.equal(item.typical_price, null, 'no spread row means no typical price, not 0');
  assert.equal(rowToPlaceProvider({ provider_code: 'ninja' }).delivery_fee, null);
});

test('a tie at the top or the bottom names no app', () => {
  const same = rowToPlaceItem(SAME_PRICE_ROW);
  assert.equal(same.gap, 0);
  assert.equal(same.cheapest_provider_id, null);
  assert.equal(same.expensive_provider_id, null);
  const tied = rowToPlaceItem({ ...ITEM_ROW, prices: { jahez: 195, ninja: 105, toyou: 105 } });
  assert.equal(tied.cheapest_provider_id, null, 'two apps share the cheapest price');
  assert.equal(tied.cheapest_price, 105);
  assert.equal(tied.expensive_provider_id, 'jahez');
});

test('rowToPlaceItem drops rows that are not a comparison and rows without a name', () => {
  assert.equal(rowToPlaceItem({ ...ITEM_ROW, prices: { ninja: 105 } }), null, 'one app is not a comparison');
  assert.equal(rowToPlaceItem({ ...ITEM_ROW, prices: {} }), null);
  assert.equal(rowToPlaceItem({ ...ITEM_ROW, item_id: 'FARQ-ITEM-1' }), null);
  assert.equal(rowToPlaceItem({ ...ITEM_ROW, name_ar: null, name_en: '  ' }), null);
});

test('sortPlaceItems puts the biggest observed gap first and the same-price items last', () => {
  const rows = [SAME_PRICE_ROW, { ...ITEM_ROW, item_id: '2', prices: { ninja: 10, toyou: 12 } }, ITEM_ROW].map(
    rowToPlaceItem,
  );
  const sorted = sortPlaceItems(rows);
  assert.deepEqual(
    sorted.map((i) => i.gap),
    [90, 2, 0],
  );
  assert.equal(sorted[2].item_id, SAME_PRICE_ROW.item_id, 'zero gap is evidence, but it goes last');
});

test('an app with no offer row for an item is absent from that item — never null, never 0', async () => {
  const body = await getPlaceItems('45537', {
    __query: fakeQuery({
      providers: [
        { provider_code: 'ninja', delivery_fee: null, min_order: null, rating: null, eta: null },
        { provider_code: 'jahez', delivery_fee: '9.5', min_order: null, rating: '4.4', eta: '30-40' },
        { provider_code: 'mrsool', delivery_fee: null, min_order: null, rating: null, eta: null },
      ],
      items: [{ ...ITEM_ROW, prices: { ninja: 105, jahez: 195 } }],
    }),
  });
  const prices = body.items[0].prices;
  assert.deepEqual(Object.keys(prices).sort(), ['jahez', 'ninja']);
  assert.equal('mrsool' in prices, false, 'mrsool lists the restaurant but never this item');
  assert.equal(body.providers.length, 3, 'the app is still an observed provider of the restaurant');
  assert.equal(body.providers[1].delivery_fee, 9.5);
  assert.equal(body.providers[1].eta, '30-40');
  assert.equal(body.providers[0].delivery_fee, null, 'delivery_fee is optional evidence');
});

test('getPlaceItems returns the restaurant head, the item count and the read-layer timestamp', async () => {
  const calls = [];
  const body = await getPlaceItems('45537', {
    __query: fakeQuery({ items: [ITEM_ROW, SAME_PRICE_ROW], calls }),
  });
  assert.equal(body.place_id, '45537');
  assert.equal(body.name, 'ايتوال');
  assert.equal(body.name_en, 'Etoile');
  assert.equal(body.city, 'riyadh');
  assert.equal(body.provider_count, 4);
  assert.equal(body.count, 2);
  assert.equal(body.items.length, 2);
  assert.equal(body.generated_at, '2026-08-16T06:40:22.854Z');
  assert.equal('observed_at' in body, false, 'the source carries no per-item observation time');

  const itemsCall = calls.find((c) => /menu_item_offers/.test(c.sql));
  assert.deepEqual(itemsCall.params, ['45537', PLACE_ITEMS_CAP], 'id and cap are bound, not interpolated');
  assert.equal(PLACE_ITEMS_CAP, 200);
  assert.match(itemsCall.sql, /HAVING count\(\*\) >= 2/, 'only items priced on more than one app');
});

test('an unknown or minted id is a 404, never an empty table pretending to be complete', async () => {
  const q = fakeQuery({ items: [ITEM_ROW] });
  assert.equal(await getPlaceItems('FARQ-PLACE-1', { __query: q }), null);
  assert.equal(await getPlaceItems('', { __query: q }), null);
  assert.equal(await getPlaceItems('12a', { __query: q }), null);
  assert.equal(await getPlaceItems('999999999', { __query: fakeQuery({ head: [] }) }), null);
});

test('a restaurant with nothing compared answers honestly with zero items', async () => {
  const body = await getPlaceItems('45537', { __query: fakeQuery({ items: [] }) });
  assert.equal(body.count, 0);
  assert.deepEqual(body.items, []);
});

test('a spread the ranking layer rejects is marked, kept, and ranked below the trusted ones', () => {
  const { rowToPlaceItem, sortPlaceItems } = require('./comparison-map');
  const suspect = rowToPlaceItem({
    item_id: '1',
    name_ar: 'عش البلبل بالفستق',
    prices: { mrsool: 149.5, jahez: 50, hungerstation: 50 },
  });
  const trusted = rowToPlaceItem({
    item_id: '2',
    name_ar: 'مشكل بقلاوة فستق',
    prices: { hungerstation: 75, mrsool: 138 },
  });
  /* item_price_spread tops out at a 1.9 ratio across all 56,245 rows — 149.50
   * against 50 is 2.99, exactly the kind of row the headline never counted. */
  assert.equal(suspect.price_outlier, true);
  assert.equal(trusted.price_outlier, false, '138/75 is 1.84 — inside what the source trusts');
  assert.equal(suspect.gap, 99.5, 'the number is still reported, not hidden');
  assert.deepEqual(
    sortPlaceItems([suspect, trusted]).map((i) => i.item_id),
    ['2', '1'],
    'the trusted gap leads, the suspect one follows',
  );
});
