'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const {
  BIGGEST_SAVINGS_MIN_GAP,
  BIGGEST_SAVINGS_MIN_PRICE,
  isBiggestSavings,
  matchesFilter,
  matchesSector,
  resolveSector,
} = require('./map-filters');

describe('map filters — biggest-savings floors', () => {
  it('reuses the comparison-read floors', () => {
    assert.equal(BIGGEST_SAVINGS_MIN_GAP, 10);
    assert.equal(BIGGEST_SAVINGS_MIN_PRICE, 15);
  });

  it('rejects a cheap item under the price floor even when the gap is large', () => {
    assert.equal(
      isBiggestSavings({
        difference_amount: 12,
        cheapest_price: 9,
        cheapest_provider: 'jahez',
      }),
      false,
    );
    assert.equal(
      isBiggestSavings({
        difference_amount: 18,
        cheapest_price: 39,
        cheapest_provider: 'jahez',
      }),
      true,
    );
  });

  it('cuts 3+ apps at provider_count, never by proximity', () => {
    assert.equal(matchesFilter({ provider_count: 2 }, 'multi'), false);
    assert.equal(matchesFilter({ provider_count: 3 }, 'multi'), true);
  });

  it('ANDs worthwhile and 3+ apps when both are on', () => {
    const worth = {
      difference_amount: 18,
      cheapest_price: 39,
      cheapest_provider: 'jahez',
      provider_count: 3,
    };
    assert.equal(matchesFilter(worth, 'biggest,multi'), true);
    assert.equal(matchesFilter({ ...worth, provider_count: 2 }, 'biggest+multi'), false);
  });
});

describe('map filters — grocery sector is identity, not a pin mint', () => {
  it('resolves grocery from sector or category', () => {
    assert.equal(resolveSector('grocery'), 'grocery');
    assert.equal(resolveSector('', 'grocery'), 'grocery');
    assert.equal(resolveSector('restaurant'), 'restaurant');
  });

  it('keeps grocery only when the name has grocery identity', () => {
    assert.equal(
      matchesSector({ name: 'تموينات الندى' }, 'grocery'),
      true,
    );
    assert.equal(
      matchesSector({ name: 'شاورما البيت' }, 'grocery'),
      false,
    );
  });
});
