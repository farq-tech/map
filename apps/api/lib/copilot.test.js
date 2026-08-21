'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { classifyIntent, normalizeArabic, providersIn } = require('./copilot-intent');
const { handleCopilot, validateAction, __resetSessionsForTests } = require('./copilot');
const { __resetCityCacheForTests } = require('./city-opportunities');

/* A tiny synthetic Riyadh: three restaurants with observed gaps, one without. */
const ROWS = [
  { place_id: '1', canonical_name_ar: 'برجر الحي', canonical_name_en: 'Hood Burger', latitude: 24.71, longitude: 46.68, provider_count: 3, item_id: '11', cheapest_provider: 'mrsool', dearest_provider: 'hungerstation', cheapest_price: 24, dearest_price: 42, gap: 18, product_name: 'برجر دبل تشيز', wins: { mrsool: 6, jahez: 1 }, comparisons: 7 },
  { place_id: '2', canonical_name_ar: 'شاورما عربي', canonical_name_en: 'Arabi Shawarma', latitude: 24.712, longitude: 46.682, provider_count: 2, item_id: '22', cheapest_provider: 'jahez', dearest_provider: 'hungerstation', cheapest_price: 12, dearest_price: 41, gap: 29, product_name: 'شاورما عربي', wins: { jahez: 4 }, comparisons: 4 },
  { place_id: '3', canonical_name_ar: 'بيتزا بعيدة', canonical_name_en: 'Far Pizza', latitude: 24.9, longitude: 46.9, provider_count: 4, item_id: '33', cheapest_provider: 'ninja', dearest_provider: 'jahez', cheapest_price: 30, dearest_price: 70, gap: 40, product_name: 'بيتزا مارجريتا', wins: { ninja: 9 }, comparisons: 9 },
  { place_id: '4', canonical_name_ar: 'مطعم بلا فرق', canonical_name_en: 'No Gap', latitude: 24.711, longitude: 46.681, provider_count: 2, gap: null, wins: null, comparisons: null },
];
const __query = async (sql) => (/read_layer_meta/.test(sql) ? [{ generated_at: '2026-08-16T06:40:22Z' }] : ROWS);
const deps = { __query, disableModel: true };
const NEAR = { bbox: '46.67,24.70,46.69,24.72', zoom: 14, userLat: 24.711, userLng: 46.681 };

test.beforeEach(() => {
  __resetSessionsForTests();
  __resetCityCacheForTests();
});

test('normalizeArabic: digits, hamza, taa marbuta, punctuation', () => {
  assert.equal(normalizeArabic('أبي ٥ فرصٍ فوق ٢٠؟'), 'ابي 5 فرص فوق 20');
  assert.equal(normalizeArabic('قهوة إسبريسو، مَعَ تطويــل'), 'قهوه اسبريسو مع تطويل');
  assert.deepEqual(providersIn(normalizeArabic('هنقرستيشن ولا جاهز؟')), ['hungerstation', 'jahez']);
});

test('intents for the product contract prompts', () => {
  const ctx = { hasSession: true, hasSelected: true, hasUser: true, hasViewport: true };
  const cases = [
    ['وين أكبر فرق حولي؟', 'BIGGEST_GAP', 'near'],
    ['وش الأرخص؟', 'FOLLOWUP_CHEAPEST', null],
    ['أبي برجر', 'SET_CATEGORY', null],
    ['وش حول هذا المكان؟', 'AROUND_POINT', null],
    ['ليش هذا أغلى؟', 'EXPLAIN_SELECTED', null],
    ['خذني له', 'GOTO_REFERENT', null],
    ['ورني أفضل 5', 'TOP_N', null],
    ['أي تطبيق أرخص حولي الليلة؟', 'APP_CHOICE', 'near'],
    ['كم الفرق بين جاهز وهنقرستيشن؟', 'APP_PAIR', null],
    ['وش فيه في النرجس؟', 'PLACE_SCOPE', 'place'],
    ['ورني اللي فرقها فوق 20', 'SET_MIN_GAP', null],
    ['قارن هذا بالمطعم اللي جنبه', 'COMPARE_NEAREST', null],
    ['وش أقدر أوفر الليلة؟', 'VAGUE_SAVE', null],
    ['السعر بيرخص بكرة؟', 'FORECAST', null],
    ['رجّعني لموقعي', 'RETURN_TO_USER', null],
    ['أرخص برجر حولي', 'CHEAPEST_IN_CATEGORY', 'near'],
  ];
  for (const [q, intent, scope] of cases) {
    const r = classifyIntent(q, ctx);
    assert.equal(r.intent, intent, `${q} → ${r.intent}`);
    if (scope) assert.equal(r.slots.scope, scope, `${q} scope`);
  }
  assert.equal(classifyIntent('ورني أفضل 5', ctx).slots.topN, 5);
  assert.equal(classifyIntent('فوق ٢٠', ctx).slots.minGap, 20);
  assert.equal(classifyIntent('وش فيه في حي النرجس', ctx).slots.placeText, 'النرجس');
  assert.equal(classifyIntent('وش الأرخص؟', { hasSession: false }).intent, 'BIGGEST_GAP', 'no session → no follow-up');
});

test('biggest gap near me: answer from rows, FOCUS_PLACE on a real id, far places excluded', async () => {
  const r = await handleCopilot({ message: 'وين أكبر فرق حولي؟', context: NEAR }, deps);
  assert.equal(r.ok, true);
  assert.equal(r.intent, 'BIGGEST_GAP');
  assert.equal(r.action.type, 'FOCUS_PLACE');
  assert.equal(r.action.place_id, '2', 'شاورما (29) beats برجر (18); بيتزا (40) is 25 km away');
  assert.match(r.answer, /29 ر\.س/);
  assert.match(r.answer, /جاهز/);
  assert.ok(r.results.every((row) => row.place_id !== '3'));
  assert.equal(r.model, 'template');
});

test('follow-ups resolve against the session: الأرخص؟ then ليش؟ then خذني له', async () => {
  const first = await handleCopilot({ message: 'وين أكبر فرق حولي؟', context: NEAR }, deps);
  const sid = first.session_id;
  const cheap = await handleCopilot({ message: 'وش الأرخص؟', sessionId: sid, context: NEAR }, deps);
  assert.equal(cheap.intent, 'FOLLOWUP_CHEAPEST');
  assert.equal(cheap.action.place_id, '2', 'cheapest price among the same results is 12 SAR');
  const why = await handleCopilot({ message: 'ليش؟', sessionId: sid, context: NEAR }, deps);
  assert.equal(why.intent, 'EXPLAIN_SELECTED');
  assert.match(why.answer, /12 ر\.س في جاهز/);
  assert.match(why.answer, /41 في هنقرستيشن/);
  assert.equal(why.action.type, 'NOOP');
  const go = await handleCopilot({ message: 'خذني له', sessionId: sid, context: NEAR }, deps);
  assert.equal(go.action.type, 'FOCUS_PLACE');
  assert.equal(go.action.place_id, '2');
});

test('the selected place on the map wins over the session for ليش', async () => {
  const r = await handleCopilot({ message: 'ليش هذا أغلى؟', context: { ...NEAR, selectedPlaceId: '1' } }, deps);
  assert.match(r.answer, /برجر دبل تشيز/);
  assert.match(r.answer, /18 ر\.س/);
});

test('top N returns SHOW_RESULTS with only real ids and a bbox', async () => {
  const r = await handleCopilot({ message: 'ورني أفضل 5', context: NEAR }, deps);
  assert.equal(r.action.type, 'SHOW_RESULTS');
  assert.deepEqual(r.action.place_ids, ['2', '1']);
  assert.equal(r.action.bbox.length, 4);
});

test('min gap filter becomes SET_FILTER and counts honestly', async () => {
  const r = await handleCopilot({ message: 'ورني اللي فرقها فوق 20', context: NEAR }, deps);
  assert.equal(r.action.type, 'SET_FILTER');
  assert.equal(r.action.min_gap, 20);
  assert.equal(r.total, 1);
});

test('category question sets the category and lists matches', async () => {
  const r = await handleCopilot({ message: 'أبي برجر', context: NEAR }, deps);
  assert.equal(r.intent, 'SET_CATEGORY');
  assert.equal(r.action.type, 'SET_CATEGORY');
  assert.equal(r.action.category, 'burgers');
  assert.equal(r.results[0].place_id, '1');
});

test('app verdict needs enough comparisons and always states its sample', async () => {
  const near = await handleCopilot({ message: 'أي تطبيق أرخص حولي؟', context: NEAR }, deps);
  assert.equal(near.intent, 'APP_CHOICE');
  assert.match(near.answer, /مرسول أرخص في 6 من 11 مقارنة/);
  const tiny = await handleCopilot({ message: 'أي تطبيق أرخص؟', context: { bbox: '46.675,24.7115,46.69,24.72', zoom: 15 } }, deps);
  assert.match(tiny.answer, /غير كافية/);
  assert.equal(tiny.action.type, 'NOOP');
});

test('a named place that cannot be geocoded is refused, never invented', async () => {
  const r = await handleCopilot({ message: 'وش فيه في أتلانتس؟', context: NEAR }, { ...deps, geocodePlace: async () => ({ ok: false, reason: 'place_not_found', bbox: null }) });
  assert.equal(r.refused, 'place_not_found');
  assert.equal(r.action.type, 'NOOP');
  assert.match(r.answer, /أتلانتس/);
});

test('a named place that is not a حي is geocoded, scopes the search and shows the results', async () => {
  const r = await handleCopilot({ message: 'وش فيه في بوليفارد؟', context: NEAR }, { ...deps, geocodePlace: async () => ({ ok: true, bbox: [46.85, 24.85, 46.95, 24.95], label: 'بوليفارد' }) });
  assert.equal(r.intent, 'PLACE_SCOPE');
  assert.equal(r.scope.kind, 'place');
  assert.equal(r.action.type, 'SHOW_RESULTS');
  assert.deepEqual(r.action.place_ids, ['3']);
  assert.match(r.answer, /في بوليفارد/);
});

test('a named حي scopes the answer to its own polygon — no geocoder, no radius', async () => {
  const { interiorPoint, loadDistricts } = require('./city-districts');
  const narjas = loadDistricts('riyadh').prepared.find((d) => d.name_ar === 'النرجس');
  assert.ok(narjas, 'the committed Riyadh boundaries know النرجس');
  const [lng, lat] = interiorPoint('riyadh', narjas.id);
  const rows = [{ ...ROWS[0], place_id: '10', latitude: lat, longitude: lng }, ROWS[2]];
  const q = async (sql) => (/read_layer_meta/.test(sql) ? [] : rows);
  const r = await handleCopilot(
    { message: 'وش فيه في حي النرجس؟', context: NEAR },
    { __query: q, disableModel: true, geocodePlace: async () => { throw new Error('the geocoder must not be asked about a known حي'); } },
  );
  assert.equal(r.intent, 'PLACE_SCOPE');
  assert.equal(r.scope.kind, 'district');
  assert.equal(r.scope.district_id, narjas.id);
  assert.deepEqual(r.results.map((x) => x.place_id), ['10'], 'only the place inside the polygon');
  assert.equal(r.action.type, 'SHOW_RESULTS');
  assert.match(r.answer, /في حي النرجس/);
  /* Place extraction is Arabic-first; the English reply still names the حي by its official English name. */
  const en = await handleCopilot({ message: 'وش فيه في حي النرجس؟', language: 'en', context: NEAR }, { __query: q, disableModel: true });
  assert.equal(en.scope.district_id, narjas.id);
  assert.match(en.answer, /in Al Narjas/);
});

test('forecasts are refused and the map is left alone', async () => {
  const r = await handleCopilot({ message: 'السعر بيرخص بكرة؟', context: NEAR }, deps);
  assert.equal(r.refused, 'forecast');
  assert.equal(r.action.type, 'NOOP');
});

test('empty scope answers honestly with no action', async () => {
  const r = await handleCopilot({ message: 'وين أكبر فرق؟', context: { bbox: '40.0,20.0,40.1,20.1', zoom: 14 } }, deps);
  assert.equal(r.action.type, 'NOOP');
  assert.match(r.answer, /ما عندنا مقارنة مرصودة/);
});

test('validateAction never lets an unknown id or type through', () => {
  const rows = [{ place_id: '9', lat: 24.7, lng: 46.7 }];
  assert.deepEqual(validateAction({ type: 'FOCUS_PLACE', place_id: '404' }, rows), { type: 'NOOP' });
  assert.deepEqual(validateAction({ type: 'DELETE_EVERYTHING' }, rows), { type: 'NOOP' });
  assert.equal(validateAction({ type: 'SHOW_RESULTS', place_ids: ['9', '404'] }, rows).place_ids.length, 1);
  assert.equal(validateAction({ type: 'FIT_BOUNDS', bbox: 'x' }, rows).type, 'NOOP');
});

test('english questions get english answers', async () => {
  const r = await handleCopilot({ message: 'biggest gap near me', language: 'en', context: NEAR }, deps);
  assert.match(r.answer, /Biggest observed gap around you/);
  assert.match(r.answer, /SAR on Jahez/);
});

/* ---------- model failover: measured against the live API on 2026-08-21 ---------- */

const { phraseWithGemini } = require('./copilot');

function geminiReply(answer) {
  return {
    ok: true,
    status: 200,
    json: async () => ({ candidates: [{ content: { parts: [{ text: JSON.stringify({ answer }) }] } }] }),
  };
}
const ROWS_FOR_PHRASE = [
  { id: 'r1', name: 'حلويات ابو انس', product_name: 'مشكل بقلاوة فستق', cheapest_provider_id: 'hungerstation', cheapest_price: 75, expensive_provider_id: 'mrsool', expensive_price: 138, gap: 63, pct: 46 },
];
const phraseArgs = { question: 'وين أكبر فرق؟', rows: ROWS_FOR_PHRASE, intent: 'BIGGEST_GAP', lang: 'ar', draft: 'أكبر فرق مرصود: 75 مقابل 138 — فرق 63.' };

test('a retired model does not end rephrasing — the next one answers', async (t) => {
  process.env.GEMINI_API_KEY = 'test-key';
  t.after(() => { delete process.env.GEMINI_API_KEY; });
  const tried = [];
  const fetchStub = async (url) => {
    tried.push(String(url).match(/models\/([^:]+):/)[1]);
    /* Exactly what the live API returns for gemini-2.5-flash today. */
    if (tried.length === 1) return { ok: false, status: 404, json: async () => ({ error: { message: 'no longer available to new users' } }) };
    return geminiReply('أكبر فرق مرصود: 75 مقابل 138 — فرق 63 ر.س.');
  };
  const out = await phraseWithGemini(phraseArgs, { fetch: fetchStub });
  assert.equal(tried.length, 2, 'it tried the next model');
  assert.match(out.answer, /63/);
});

test('an overloaded model (503) and an empty reply both fall through', async (t) => {
  process.env.GEMINI_API_KEY = 'test-key';
  t.after(() => { delete process.env.GEMINI_API_KEY; });
  for (const first of [
    { ok: false, status: 503, json: async () => ({ error: { message: 'high demand' } }) },
    /* A reasoning model can burn the whole token budget before writing a word. */
    geminiReply('   '),
  ]) {
    let n = 0;
    const out = await phraseWithGemini(phraseArgs, {
      fetch: async () => { n += 1; return n === 1 ? first : geminiReply('فرق 63 ر.س مرصود بين 75 و138.'); },
    });
    assert.equal(n, 2);
    assert.match(out.answer, /63/);
  }
});

test('failing over never doubles the wait — one budget for the whole step', async (t) => {
  process.env.GEMINI_API_KEY = 'test-key';
  t.after(() => { delete process.env.GEMINI_API_KEY; });
  let clock = 1_000_000;
  let calls = 0;
  const out = await phraseWithGemini(phraseArgs, {
    now: () => clock,
    fetch: async () => {
      calls += 1;
      clock += 5500; // the first model eats almost the entire budget
      throw new Error('TimeoutError');
    },
  });
  assert.equal(calls, 1, 'the second model is not started with no time left');
  assert.equal(out, null, 'the caller falls back to the template answer');
});

test('a model that invents a number is refused, not retried', async (t) => {
  process.env.GEMINI_API_KEY = 'test-key';
  t.after(() => { delete process.env.GEMINI_API_KEY; });
  let calls = 0;
  const out = await phraseWithGemini(phraseArgs, {
    fetch: async () => { calls += 1; return geminiReply('وفر 999 ر.س الليلة!'); },
  });
  assert.equal(out, null);
  assert.equal(calls, 1, 'the next model is no more trustworthy about the same rows');
});
