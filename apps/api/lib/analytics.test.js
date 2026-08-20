'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  ALLOWED_EVENT_TYPES,
  MAX_EVENTS_PER_REQUEST,
  RATE_LIMIT_PER_MINUTE,
  buildInsert,
  ingestEvents,
  sanitizeMeta,
  sanitizePath,
  sanitizeSessionId,
  __resetRateLimitForTests,
} = require('./analytics');

const ON = { ANALYTICS_WRITE_ENABLED: '1' };

/** A fake query: records calls, never touches a database. */
function fakeQuery(impl) {
  const calls = [];
  const fn = async (text, values) => {
    calls.push({ text, values });
    if (impl) return impl(text, values);
    return [];
  };
  fn.calls = calls;
  return fn;
}

function evt(over = {}) {
  return { type: 'map_view', session_id: 'a'.repeat(24), path: '/map', ...over };
}

/**
 * The client keeps the same list in apps/web/src/lib/farqAnalytics.ts and the
 * workspaces cannot import each other, so drift is caught here twice: against
 * a copy written out below, and against the web file itself when it is on disk.
 */
const EVENTS_COPY = [
  'map_view',
  'district_select',
  'district_clear',
  'place_select',
  'list_open',
  'map_open',
  'sort_change',
  'search_submit',
  'search_here',
  'copilot_ask',
  'copilot_action',
  'legend_open',
  'locate_click',
  'open_menu_click',
  'lens_change',
];

test('the server allowlist matches the copy checked in here', () => {
  assert.deepEqual([...ALLOWED_EVENT_TYPES], EVENTS_COPY);
});

test('the web client list has not drifted from the server allowlist', () => {
  const webLib = path.join(__dirname, '../../web/src/lib/farqAnalytics.ts');
  if (!fs.existsSync(webLib)) return; // web workspace not checked out — nothing to compare
  const src = fs.readFileSync(webLib, 'utf8');
  const block = src.match(/ANALYTICS_EVENTS\s*=\s*\[([\s\S]*?)\]\s*as const/);
  assert.ok(block, 'ANALYTICS_EVENTS not found in the web lib');
  const fromWeb = [...block[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]);
  assert.deepEqual(fromWeb, [...ALLOWED_EVENT_TYPES]);
});

test('a disallowed event type is rejected and nothing is inserted', async () => {
  __resetRateLimitForTests();
  const query = fakeQuery();
  const res = await ingestEvents({
    body: { events: [evt(), evt({ type: 'keystroke' })] },
    query,
    env: ON,
  });
  assert.equal(res.status, 400);
  assert.equal(res.error, 'invalid_event_type');
  assert.equal(query.calls.length, 0, 'a rejected batch never reaches the DB');
});

test('meta keys outside the per-event allowlist are dropped, free text never survives', () => {
  const meta = sanitizeMeta(
    {
      has_query: true,
      result_count: 12,
      q: 'شاورما عربي',
      email: 'someone@example.com',
      user_id: 'u_123',
      intent: 'cheapest shawarma please',
      nested: { a: 1 },
      source: 'sheet',
    },
    'search_submit',
  );
  assert.deepEqual(meta, { has_query: true, result_count: 12, source: 'sheet' });
  assert.equal('q' in meta, false);
  assert.equal('email' in meta, false);
  assert.equal('intent' in meta, false, 'intent is not a key search_submit may carry');
});

test('meta scalars are capped and coordinates can never arrive at street precision', () => {
  const meta = sanitizeMeta({ zoom: 14.123456789, lens: 'x'.repeat(90), result_count: 3 }, 'map_view');
  assert.equal(meta.zoom, 14.123);
  assert.equal(meta.lens.length, 64);
  assert.equal(meta.result_count, 3);
  assert.equal(sanitizeMeta({ zoom: 'شاورما' }, 'map_view'), null, 'non-slug strings are dropped');
});

test('a path keeps the route and loses the query string', () => {
  assert.equal(sanitizePath('/map?q=%D8%B4%D8%A7%D9%88%D8%B1%D9%85%D8%A7#x'), '/map');
  assert.equal(sanitizePath('/merchant/rest/5454'), '/merchant/rest/5454');
  assert.equal(sanitizePath('/بحث'), null, 'a typed segment is not a route');
  assert.equal(sanitizePath('map'), null);
});

test('a 21-event batch is rejected outright', async () => {
  __resetRateLimitForTests();
  const query = fakeQuery();
  const events = Array.from({ length: MAX_EVENTS_PER_REQUEST + 1 }, () => evt());
  const res = await ingestEvents({ body: { events }, query, env: ON });
  assert.equal(res.status, 400);
  assert.equal(res.error, 'too_many_events');
  assert.equal(query.calls.length, 0);
});

test('a bad session id becomes null instead of being stored', async () => {
  __resetRateLimitForTests();
  assert.equal(sanitizeSessionId('short'), null);
  assert.equal(sanitizeSessionId('someone@example.com'), null);
  assert.equal(sanitizeSessionId('x'.repeat(65)), null);
  assert.equal(sanitizeSessionId('a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'), 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d');

  const query = fakeQuery();
  await ingestEvents({ body: { events: [evt({ session_id: 'nope' })] }, query, env: ON });
  assert.equal(query.calls[0].values[1], null);
});

test('the insert is one parameterised multi-row statement', async () => {
  __resetRateLimitForTests();
  const { text, values } = buildInsert([
    { event_type: 'map_view', session_id: 's'.repeat(10), path: '/map', language: 'ar', device: 'mobile', meta: { zoom: 12 } },
    { event_type: 'list_open', session_id: null, path: null, language: null, device: null, meta: null },
  ]);
  assert.match(text, /^INSERT INTO public\.analytics_events \(event_type, session_id, path, language, device, meta\) VALUES /);
  assert.equal(text.includes('map_view'), false, 'values are never concatenated into SQL');
  assert.match(text, /\$1, \$2, \$3, \$4, \$5, \$6::jsonb\), \(\$7/);
  assert.equal(values.length, 12);
  assert.equal(values[5], '{"zoom":12}');
  assert.equal(values[11], null);
});

test('a DB error still answers 204 and never leaks', async () => {
  __resetRateLimitForTests();
  const query = fakeQuery(() => {
    throw new Error('connection terminated unexpectedly');
  });
  const res = await ingestEvents({ body: { events: [evt()] }, query, env: ON });
  assert.equal(res.status, 204);
  assert.equal(res.skipped, 'db_error');
});

test('the env flag off accepts the batch and writes nothing', async () => {
  __resetRateLimitForTests();
  const query = fakeQuery();
  const res = await ingestEvents({ body: { events: [evt()] }, query, env: {} });
  assert.equal(res.status, 204);
  assert.equal(res.skipped, 'disabled');
  assert.equal(query.calls.length, 0);
});

test('a session that floods is dropped, quietly', async () => {
  __resetRateLimitForTests();
  const query = fakeQuery();
  const session = 'f'.repeat(20);
  const batch = { events: Array.from({ length: MAX_EVENTS_PER_REQUEST }, () => evt({ session_id: session })) };
  const rounds = Math.ceil(RATE_LIMIT_PER_MINUTE / MAX_EVENTS_PER_REQUEST);
  let last;
  for (let i = 0; i <= rounds; i += 1) {
    last = await ingestEvents({ body: batch, query, now: 1_700_000_000_000, env: ON });
  }
  assert.equal(last.status, 204);
  assert.equal(last.skipped, 'rate_limited');
  assert.ok(query.calls.length <= rounds);
});

test('an empty or malformed body is a 400, not a crash', async () => {
  __resetRateLimitForTests();
  const query = fakeQuery();
  assert.equal((await ingestEvents({ body: {}, query, env: ON })).error, 'events_required');
  assert.equal((await ingestEvents({ body: null, query, env: ON })).error, 'events_required');
  assert.equal((await ingestEvents({ body: { events: ['map_view'] }, query, env: ON })).error, 'invalid_event');
  assert.equal((await ingestEvents({ body: { events: [] }, query, env: ON })).status, 204);
  assert.equal(query.calls.length, 0);
});
