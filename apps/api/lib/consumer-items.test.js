'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  categoryCaseSql,
  categoryOfItem,
  deliveryAdjustedGap,
  demoteReason,
  displayItemName,
  isRetailItem,
  isShareItem,
  normalizedNameSql,
  retailItemPattern,
  shareItemPattern,
} = require('./consumer-items');

/* Real names taken from the Riyadh read layer on 2026-08-20. */
const SHARE = [
  'ميكس بوكس',
  'بوكس المشاركة كوكيز حساوي',
  '24 قطعة ميني كوكيز مع جالون قهوة 1 لتر',
  'بوكس ١٢ عبوة عصير',
  'اوبتي تيكت شاي ميجا العضوي, 30 كيس',
  'بيتزا لثلاثة أشخاص',
  'بوكس كأس العالم لـ ٥',
  'كومبو سفرة مشاوي',
  'تريو كبير كومبو',
  'صينية كبسة',
  'Family Box',
  'Party Platter',
];

const PERSONAL = [
  'برجر دبل تشيز',
  'شاورما عربي',
  'كيكة المانجو',
  'سمك سالمون',
  'روبيان ملكي مشوي',
  'قهوة لاتيه',
  'علبة عصير',
  'بيتزا مارجريتا',
  'موس كيك بندق',
  'دجاج بروستد',
  'مشكل بقلاوة فستق',
  'وجبة 2 طاجن سعره 2272',
  'وعاء ارز مع نوعين من البروتين',
];

test('a share box is recognised however it is spelled', () => {
  for (const name of SHARE) assert.equal(isShareItem(name), true, name);
});

test('what one person orders is left alone — including the names that nearly fooled the lexicon', () => {
  for (const name of PERSONAL) {
    assert.equal(demoteReason(name), null, name);
  }
});

test('packaged retail is demoted, but only on measured evidence', () => {
  assert.equal(isRetailItem('لابيرفا الترا كرياتين, 300 جرام, 5000 ملجم'), true);
  assert.equal(isRetailItem('لابيرفا تريبل زنك مع فيتامين سي, 60 قرص'), true);
  assert.equal(isRetailItem('Laperva Whey Protein'), true);
  /* Measured on the live read layer: a bare `mg` matches "MG shrimp bowl", and
   * a bare `بروتين` matches a rice bowl. Both must stay food. */
  assert.equal(isRetailItem('ام جي صحن شريمب mg shrimp bowl'), false);
  assert.equal(isRetailItem('وعاء ارز مع نوعين من البروتين'), false);
});

test('«سعره N» is a calorie count, not a price — demoting it would have cost 18% of the data', () => {
  assert.equal(demoteReason('بون بون تشوكليت القهوة سعره 250'), null);
  assert.equal(demoteReason('وجبة 2 طاجن سعره 2272'), null);
  assert.equal(shareItemPattern().includes('سعره'), false);
  assert.equal(retailItemPattern().includes('سعره'), false);
});

test('the reason travels with the item so the interface can name it', () => {
  assert.equal(demoteReason('بوكس المشاركة'), 'share');
  assert.equal(demoteReason('Laperva Ultra Creatine 300 جرام'), 'retail');
  assert.equal(demoteReason('برجر دبل تشيز'), null);
  assert.equal(demoteReason(''), null);
  assert.equal(demoteReason(null), null);
});

test('display trims the scraper residue and never returns nothing', () => {
  assert.equal(displayItemName('بون بون تشوكليت القهوة  سعره 250 '), 'بون بون تشوكليت القهوة');
  assert.equal(displayItemName('لؤلؤ مالح 03003641'), 'لؤلؤ مالح');
  assert.equal(displayItemName('Bonbon Coffee Chocolate cal 250'), 'Bonbon Coffee Chocolate');
  assert.equal(displayItemName('شاورما عربي'), 'شاورما عربي');
  /* A name that is only residue keeps its original rather than becoming blank. */
  assert.equal(displayItemName('03003641'), '03003641');
  assert.equal(displayItemName(null), '');
});

test('a category means the same thing everywhere it is asked for', () => {
  assert.equal(categoryOfItem('برجر دبل تشيز'), 'burgers');
  assert.equal(categoryOfItem('برغر لحم'), 'burgers');
  assert.equal(categoryOfItem('بيتزا مارجريتا'), 'pizza');
  assert.equal(categoryOfItem('قهوة لاتيه'), 'coffee');
  assert.equal(categoryOfItem('كيكة المانجو'), 'desserts');
  assert.equal(categoryOfItem('سمك سالمون'), 'seafood');
  assert.equal(categoryOfItem('صحن سلطة'), null, 'no category is better than a wrong one');
});

test('an unobserved delivery fee is missing, never zero', () => {
  assert.equal(deliveryAdjustedGap({ cheapestPrice: 40, dearestPrice: 70, cheapestFee: 12, dearestFee: 5 }), 23);
  for (const missing of [null, undefined, '']) {
    assert.equal(
      deliveryAdjustedGap({ cheapestPrice: 40, dearestPrice: 70, cheapestFee: 12, dearestFee: missing }),
      null,
      String(missing),
    );
  }
  assert.equal(deliveryAdjustedGap({}), null);
  assert.equal(deliveryAdjustedGap({ cheapestPrice: 40, dearestPrice: 70, cheapestFee: -1, dearestFee: 5 }), null);
});

test('the SQL fragments carry the same rules as the JS, and quote safely', () => {
  const expr = "coalesce(name_ar,'')";
  assert.match(normalizedNameSql(expr), /^translate\(translate\(lower\(/);
  const cases = categoryCaseSql(expr);
  assert.match(cases, /^CASE WHEN /);
  assert.match(cases, /THEN 'burgers'/);
  assert.match(cases, /ELSE NULL END$/);
  /* A stray apostrophe in a term must never break out of the SQL literal. */
  assert.equal(/'[^']*'[^']*'[^']*THEN/.test("WHEN x ~ 'it''s' THEN"), true);
});
