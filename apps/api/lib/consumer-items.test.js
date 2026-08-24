'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  categoryCaseSql,
  categoryOfItem,
  deliveryAdjustedGap,
  demoteReason,
  displayItemName,
  representativeSpreadOrderSql,
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
  'وجبة بات آند جينو لشخصين',
  'بوكس كأس العالم لـ ٥',
  'كومبو سفرة مشاوي',
  'تريو كبير كومبو',
  'صينية كبسة',
  'Family Box',
  'Party Platter',
  'صندوق تجميع لفائف',
  'صندوق تجمع الأبطال',
  'كومبو اللمة',
  'عرض اللمة',
  'لمة السراة 5',
  'لمة الأصدقاء',
  'بكج اللمة',
  'بكج كاس العالم',
  'تجمع شواء النار',
  'عرض الجمعات',
  'جمعات جيلاتو ( لتر',
  'كومبو الثنائي الكبير',
  'وجبة صب واي الثلاثية',
  'كيسة الطلعة',
  'وجبة الهاتريك',
  'طاجن السعاده للمتزوجين',
  'وجبة جماعية',
  'عرض الرباعي الذهبي 8 مكس',
  'وجبة 2 طاجن',
  'مفطح شهبار',
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
  'وعاء ارز مع نوعين من البروتين',
  'نودلز صينية',
  'شوربة صينية',
  'Chinese Noodles',
  'كبة بالصينية',
  'والمة قهوة سعودية مختصة سريعة التحضير',
  'كباب الجمعة',
  'مقلوبة جمعة الدجاج',
  'بن بندت',
  'بون بون تشوكليت القهوة',
  'إفطار كلوب ساندويش (توست الحبوب',
  'إسبريسو شيكر',
  'ستيك شيكر',
  'Grouper Fillet',
  'بينتو اوفر',
  'Bento Lunch Offer',
  'عرض المونديال',
  'World Cup Offer',
  'وجبة ماد ماكس',
  'مجبوس لحم',
  'مياه معدنيه',
  'كوكا كولا بدون سكر',
  'مربى الخوخ',
  '8 ساندوتش جبنة مربى',
  'صحن فتة شامية بالمكسرات',
  'حمص باللحم والمكسرات',
  'اوزي بالمكسرات',
  'كرانشي البيكان واللوز مع الكراميل المملح',
  'مكرملة قشطية',
  'أصابع بقلاوة كاجو',
  'باستا كاجون روبيان ودجاج',
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
  /* A 250g steak is dinner. The gram weight alone used to call it a tub. */
  assert.equal(isRetailItem('رامب أسترالي 250 جرام'), false);
  assert.equal(demoteReason('رامب أسترالي 250 جرام'), null);
  assert.equal(demoteReason('ليفري كلوت مقاس كبير للسلس الغزير 32حبة'), 'retail');
  /* A bag of beans is a shelf SKU. A latte, بن بندت, and grain toast are dinner. */
  assert.equal(demoteReason('كيس قهوة فرنسية'), 'retail');
  assert.equal(demoteReason('كيس حبوب قهوة ٢٥٠ غرام'), 'retail');
  assert.equal(demoteReason('مزيج أرابيكا المطحون 250 جرام'), 'retail');
  assert.equal(demoteReason('Ethiopia Arabica 250g'), 'retail');
  assert.equal(demoteReason('قهوة لاتيه'), null);
  assert.equal(demoteReason('بون بون تشوكليت القهوة'), null);
  assert.equal(demoteReason('بن بندت'), null);
  assert.equal(demoteReason('بن كولومبي – 250 جرام'), null);
  assert.equal(demoteReason('إفطار كلوب ساندويش (توست الحبوب'), null);
  assert.equal(demoteReason('كيس مكسرات مشكل مملح عادي (٢٥٠جم'), 'retail');
  assert.equal(demoteReason('لابيرفا شيكر بلندر بوتل ستانلس ستيل, أسود'), 'retail');
  assert.equal(demoteReason('يوسيرين لوشن الأصلي العلاجي, 500 مل'), 'retail');
  assert.equal(demoteReason('إسبريسو شيكر'), null);
  assert.equal(demoteReason('ستيك شيكر'), null);
  assert.equal(demoteReason('لابيرفا سويتشيس محلى سكر غامق, 100 ظرف'), 'retail');
  assert.equal(demoteReason('بيو بروتيكشن عسل الأكاسيا, 400 جرام, تعزيز المناعة'), 'retail');
  assert.equal(demoteReason('لابيرفا بيرفكت ستيفيا, 300 جرام'), 'retail');
  assert.equal(demoteReason('علبة قهوة مميزة'), 'retail');
  assert.equal(demoteReason('علبة عصير'), null);
  /* A World Cup pasta promo is a named offer, not a proven table. */
  assert.equal(demoteReason('عرض المونديال'), null);
  assert.equal(demoteReason('World Cup Offer'), null);
  assert.equal(demoteReason('وجبة ماد ماكس'), null);
  assert.equal(demoteReason('مج معدني يحمل شعار تيم هورتنز ( مع غطاء'), 'retail');
  assert.equal(demoteReason('Metal Mug'), 'retail');
  assert.equal(demoteReason('مجبوس لحم'), null);
  assert.equal(demoteReason('مياه معدنيه'), null);
  assert.equal(demoteReason('بيستاشيو لاتيه حجم كبير'), null);
  assert.equal(demoteReason('مج يحمل شعار تيم هورتنز لون أسود'), 'retail');
  assert.equal(demoteReason('لابيرفا مربى بدون سكر مضاف, كرز أسود, 235 جرام'), 'retail');
  assert.equal(demoteReason('Laperva Strawberry Diet Jelly 170G'), 'retail');
  assert.equal(demoteReason('كوكا كولا بدون سكر'), null);
  assert.equal(demoteReason('Coca Cola Zero Sugar'), null);
  assert.equal(demoteReason('مربى الخوخ'), null);
  assert.equal(demoteReason('8 ساندوتش جبنة مربى'), null);
  assert.equal(demoteReason('بودي بيلدر شيكر أصفر شفاف - 700 مل'), 'retail');
  assert.equal(demoteReason('Body Builder Shaker Black & Yellow 700Ml'), 'retail');
  assert.equal(demoteReason('إسبريسو شيكر'), null);
  assert.equal(demoteReason('اوبتي تيكت هيلث بيرفكت نتس, 110 جرام'), 'retail');
  assert.equal(demoteReason('Opti Tect 100% Natural Perfect Nuts 110G'), 'retail');
  assert.equal(demoteReason('اوبتي تيكت دايت بقلاوة دايت, 40 جرام'), 'retail');
  assert.equal(demoteReason('صحن فتة شامية بالمكسرات'), null);
  assert.equal(demoteReason('حمص باللحم والمكسرات'), null);
  assert.equal(demoteReason('اوزي بالمكسرات'), null);
  assert.equal(demoteReason('لابيرفا ملح بوتاسيوم, 80 جرام'), 'retail');
  assert.equal(demoteReason('Laperva Potassium Salt 80G'), 'retail');
  assert.equal(demoteReason('لابيرفا ايزو تربيل زيرو فانل, 50 جرام'), 'retail');
  assert.equal(demoteReason('Laperva Iso Triple Zero Vanilla 50G'), 'retail');
  assert.equal(demoteReason('كرانشي البيكان واللوز مع الكراميل المملح'), null);
  assert.equal(demoteReason('وعاء ارز مع نوعين من البروتين'), null);
  assert.equal(demoteReason('كرات عالية البروتين بجوز الهند واللوز مع محلي, 63 جرام'), 'retail');
  assert.equal(demoteReason('Laperva Protein Coconut Balls 63G'), 'retail');
  assert.equal(demoteReason('لابيرفا دو بنكهة اللوز والكاجو بروتين بار, 1بار'), 'retail');
  assert.equal(demoteReason('مكسرات مكرملة مشكل كبير'), 'retail');
  assert.equal(demoteReason('Big Mixed Caramelized Nuts'), 'retail');
  assert.equal(demoteReason('مكسرات برازيلية'), 'retail');
  assert.equal(demoteReason('كاجو مقلى'), 'retail');
  assert.equal(demoteReason('مكرملة قشطية'), null);
  assert.equal(demoteReason('أصابع بقلاوة كاجو'), null);
  assert.equal(demoteReason('باستا كاجون روبيان ودجاج'), null);
});

test('«سعره N» is a calorie count, not a price — demoting it would have cost 18% of the data', () => {
  assert.equal(demoteReason('بون بون تشوكليت القهوة سعره 250'), null);
  /* Two tajines is a table; the calorie tail is not why. */
  assert.equal(demoteReason('وجبة 2 طاجن سعره 2272'), 'share');
  assert.equal(shareItemPattern().includes('سعره'), false);
  assert.equal(retailItemPattern().includes('سعره'), false);
});

test('half a kilo of knafeh is a dessert, not a party tray', () => {
  assert.equal(demoteReason('كنافة نابلسية خشنة ١/٢ كيلو'), null);
  assert.equal(demoteReason('كنافة نابلسية خشنة 1/2 كيلو'), null);
  assert.equal(demoteReason('نصف كيلو كنافة'), null);
  assert.equal(demoteReason('بسبوسة لوز نص كيلو'), null);
  assert.equal(demoteReason('Half A Kilo Of Almond Basbousa'), null);
  assert.equal(demoteReason('كيلو مشويات مشكل'), 'share');
  assert.equal(demoteReason('مشكل كبة Soma S Mix Grape Leaves Box'), 'share');
});

test('a meal for one is dinner, and for 69SR is a price, not a table', () => {
  assert.equal(demoteReason('وجبة شخص واحد Meal For 1'), null);
  assert.equal(demoteReason('كومبو النودلز لشخص واحد Noodles Combo For 1'), null);
  assert.equal(demoteReason('Meal For 2'), 'share');
  assert.equal(demoteReason('Any 2 Pizza + 1Ltr Drink for 69SR'), null);
  assert.equal(demoteReason('ثمن جالون'), null);
  assert.equal(demoteReason('بيتزا لثلاثة أشخاص'), 'share');
});

test('a gathering table is share; a sip of coffee is not', () => {
  assert.equal(demoteReason('كومبو اللمة'), 'share');
  assert.equal(demoteReason('عرض اللمة'), 'share');
  assert.equal(demoteReason('عرض اللمه'), 'share');
  assert.equal(demoteReason('لمة السراة 5'), 'share');
  assert.equal(demoteReason('لمة الأصدقاء'), 'share');
  assert.equal(demoteReason('سبيشل اللمة'), 'share');
  assert.equal(demoteReason('بكج اللمة'), 'share');
  assert.equal(demoteReason('بكج كاس العالم'), 'share');
  assert.equal(demoteReason('تجمع شواء النار'), 'share');
  assert.equal(demoteReason('عرض الجمعات'), 'share');
  assert.equal(demoteReason('جمعات جيلاتو ( لتر'), 'share');
  assert.equal(demoteReason('تراميسو كلاسيك للجمعات'), 'share');
  /* "والمة" is a pour. The letters لمه sit inside it; the article / boundary do not. */
  assert.equal(demoteReason('والمة قهوة سعودية مختصة سريعة التحضير'), null);
  assert.equal(demoteReason('قهوة لاتيه'), null);
  /* Friday is a weekday special, not a table. */
  assert.equal(demoteReason('كباب الجمعة'), null);
  assert.equal(demoteReason('مقلوبة جمعة الدجاج'), null);
  assert.equal(demoteReason('جمعة النورماني'), null);
  assert.equal(demoteReason('كومبو الثنائي الكبير'), 'share');
  assert.equal(demoteReason('وجبة الثنائي'), 'share');
  assert.equal(demoteReason('وجبة صب واي الثلاثية'), 'share');
  assert.equal(demoteReason('عرض الكريب الثلاثي'), 'share');
  assert.equal(demoteReason('كيسة الطلعة'), 'share');
  /* A bag of coffee or nuts is a shelf SKU, not this picnic pouch. */
  assert.equal(demoteReason('كيس قهوة فرنسية'), 'retail');
  assert.equal(demoteReason('كيس مكسرات مشكل مملح عادي (٢٥٠جم'), 'retail');
  assert.equal(demoteReason('وجبة الهاتريك'), 'share');
  assert.equal(demoteReason('هاتريك كومبو'), 'share');
  assert.equal(demoteReason('Hat-Trick Combo'), 'share');
  assert.equal(demoteReason('طاجن السعاده للمتزوجين'), 'share');
  assert.equal(demoteReason('وجبة جماعية'), 'share');
  assert.equal(demoteReason('Group Meal'), 'share');
  /* Bare "group" is the fish. */
  assert.equal(demoteReason('Grouper Fillet'), null);
  assert.equal(demoteReason('عرض الرباعي الذهبي 8 مكس'), 'share');
  assert.equal(demoteReason('عرض الكريب الرباعي'), 'share');
  assert.equal(demoteReason('Golden Quartet Offer 8 Mix'), 'share');
  assert.equal(demoteReason('وجبة 2 طاجن'), 'share');
  assert.equal(demoteReason('طاجن جمبري'), null);
  assert.equal(demoteReason('مفطح شهبار'), 'share');
  /* A Japanese bento is one lunch, not a tray. Gold Sushi 12752 is 99–168. */
  assert.equal(demoteReason('بينتو اوفر'), null);
  assert.equal(demoteReason('Bento Lunch Offer'), null);
});

test('a party single is one burger; a party box is still a tray', () => {
  assert.equal(demoteReason('فويل بارتي سنجل'), null);
  assert.equal(demoteReason('فويل بارتي سنجل Foil In Party Single'), null);
  assert.equal(demoteReason('بارتي بوكس 8 سبيشال'), 'share');
  assert.equal(demoteReason('Party Box 8 Special'), 'share');
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
  assert.equal(displayItemName('سمبوسة البطاطس (Cal: 236)'), 'سمبوسة البطاطس');
  assert.equal(displayItemName('معمول كحيله كبير 00608'), 'معمول كحيله كبير');
  assert.equal(displayItemName('معمول الاصيله صغير00751'), 'معمول الاصيله صغير');
  assert.equal(displayItemName('ترافل هنوفريان - ١٢٣٤٥٧'), 'ترافل هنوفريان');
  assert.equal(displayItemName('بديع بقلاوة بيكان كبير ١٠٧٠٠٢٤٣'), 'بديع بقلاوة بيكان كبير');
  assert.equal(displayItemName('\u200fوجبة برجر كريسبي'), 'وجبة برجر كريسبي');
  assert.equal(displayItemName('امبيريال كبير ٢٢حبة_١٠٧٠٠٢٢'), 'امبيريال كبير ٢٢حبة');
  assert.equal(displayItemName('عرض باسكوالي 79 ريال'), 'عرض باسكوالي 79 ريال');
  assert.equal(displayItemName('٢ بيتزا كبيرة بـ ٣٩ ريال'), '٢ بيتزا كبيرة بـ ٣٩ ريال');
  assert.equal(displayItemName('.فانيلا'), 'فانيلا');
  assert.equal(displayItemName('...'), '...');
});

test('pin and getPlace rank the same representative item', () => {
  const sql = representativeSpreadOrderSql();
  assert.match(sql, /shareItemPattern|بوكس|is_share/i);
  assert.match(sql, /cheapest_price ASC/);
  assert.match(sql, /canonical_item_id ASC/);
  assert.match(sql, /dearest_price - ips.cheapest_price/);
  assert.match(sql, /dearest_price - ips.cheapest_price\) >= 1/);
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

test('SQL translate maps taa marbuta like JS, and صينية is a tray only with a following word', () => {
  const sql = normalizedNameSql('n');
  assert.match(sql, /'ااااهي'/);
  assert.equal(sql.includes("'اااهي'"), false);
  assert.equal(demoteReason('صينية النخبة'), 'share');
  assert.equal(demoteReason('سفرة المطانيخ'), 'share');
  assert.equal(demoteReason('وليمة بوكيس'), 'share');
  assert.equal(demoteReason('ضيافة كاس العالم'), 'share');
  assert.equal(demoteReason('عرض العزيمة مندي'), 'share');
  assert.equal(demoteReason('نودلز صينية'), null);
  assert.equal(demoteReason('نودلز صينية Chinese Noodles'), null);
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
