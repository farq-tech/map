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
  observedGapRiyals,
  rowToPlaceItem,
  rowToPlaceProvider,
  sortPlaceItems,
  classifyDupeNames,
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

test('the proof table leads with the pin dish and parks over-cap rows', () => {
  const { rowToPlaceItem, sortPlaceItems } = require('./comparison-map');
  const snack = rowToPlaceItem({
    item_id: '15101',
    name_ar: 'سناكات فيفا 26',
    prices: { jahez: 64, hungerstation: 65 },
  });
  const cake = rowToPlaceItem({
    item_id: '15102',
    name_ar: 'برونو',
    prices: { jahez: 96.8, hungerstation: 121 },
  });
  const overCap = rowToPlaceItem({
    item_id: '136421',
    name_ar: 'ميني سميد',
    prices: { jahez: 87.5, hungerstation: 250 },
  });
  const pinItem = rowToPlaceItem({
    item_id: '136422',
    name_ar: 'سجنتشر 30قطعة',
    prices: { jahez: 90, hungerstation: 150 },
  });
  assert.equal(snack.over_cap, false);
  assert.equal(overCap.over_cap, true);
  assert.deepEqual(
    sortPlaceItems([cake, snack], 'سناكات فيفا 26').map((i) => i.item_id),
    ['15101', '15102'],
  );
  assert.deepEqual(
    sortPlaceItems([overCap, pinItem], 'سجنتشر 30قطعة').map((i) => i.item_id),
    ['136422', '136421'],
  );
});

test('duplicate coordinates are labelled, never merged', () => {
  assert.equal(classifyDupeNames(['ماكدونالدز', 'ماكدونالدز']), 'same_name');
  assert.equal(classifyDupeNames(['ماكدونالدز', 'ستاربكس']), 'distinct_names');
});

test('getPlace memo keeps an observed payload for five minutes and drops it after', () => {
  const {
    readPlaceCache,
    writePlaceCache,
    resetPlaceCache,
    PLACE_CACHE_TTL_MS,
  } = require('./comparison-map');
  resetPlaceCache();
  const body = { place_id: '1381', lat: 24.4855703069545, lng: 46.6215488247467 };
  writePlaceCache('1381', body);
  assert.equal(readPlaceCache('1381'), body);
  assert.equal(readPlaceCache('1381', Date.now() + PLACE_CACHE_TTL_MS + 1), undefined);
  writePlaceCache('999', null);
  assert.equal(readPlaceCache('999'), null);
  resetPlaceCache();
});

test('rowToPlaceItem trims سعره N so 81 riyals is not read as 250', () => {
  const item = rowToPlaceItem({
    item_id: '1',
    name_ar: 'بون بون تشوكليت القهوة  سعره 250 ',
    name_en: null,
    prices: { hungerstation: 109, jahez: 190 },
  });
  assert.equal(item.name, 'بون بون تشوكليت القهوة');
  assert.equal(item.gap, 81);
});

test('lean gap is the rounded observed difference — city pins and getPlace share it', () => {
  assert.equal(
    observedGapRiyals({ difference_amount: 81, cheapest_provider_id: 'hungerstation' }),
    81,
  );
  assert.equal(observedGapRiyals({ difference_amount: 1 }), 1);
  assert.equal(observedGapRiyals(null), null);
});
