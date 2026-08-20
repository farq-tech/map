'use strict';

/**
 * حارس التطابق — مخرجات normalizeArabic مثبَّتة حرفياً هنا.
 *
 * نسخة الويب normalizeSearchText في apps/web/src/lib/farqTextSearch.ts لازم
 * تعطي نفس هذه المخرجات بالضبط (نفس الحالات مثبَّتة في اختبارها). أي تعديل على
 * المطبِّع هنا يكسر هذا الاختبار بصوت عالٍ — عدّل الجهتين معاً، لا وحدة.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { CATEGORY_GROUPS, normalizeArabic } = require('./copilot-intent');

/* [input, expected] — kept identical in apps/web/src/lib/farqTextSearch.test.ts */
const PINNED = [
  ['أبي ٥ فرصٍ فوق ٢٠؟', 'ابي 5 فرص فوق 20'],
  ['قهوة إسبريسو، مَعَ تطويــل', 'قهوه اسبريسو مع تطويل'],
  ['هنقرستيشن ولا جاهز؟', 'هنقرستيشن ولا جاهز'],
  ['  Al-Olaya  ', 'al-olaya'],
  ['', ''],
  /* همزة الواو والياء ما تُطبَّع هنا — الويب يطويها للبحث وحده، فوق هذا المطبِّع */
  ['لؤلؤ', 'لؤلؤ'],
];

test('normalizeArabic output is pinned — the web copy must produce the same strings', () => {
  for (const [input, expected] of PINNED) {
    assert.equal(normalizeArabic(input), expected, JSON.stringify(input));
  }
});

/* التطبيع مستقر: تطبيع المطبَّع يعطي نفسه — عليه يعتمد بناء مفاتيح المرادفات في الويب. */
test('normalizeArabic is idempotent over every CATEGORY_GROUPS term', () => {
  for (const group of CATEGORY_GROUPS) {
    assert.ok(group.terms.length > 0, group.id);
    for (const term of group.terms) {
      const once = normalizeArabic(term);
      assert.ok(once, `${group.id}: ${term}`);
      assert.equal(normalizeArabic(once), once, `${group.id}: ${term}`);
    }
  }
});
