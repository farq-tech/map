'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const http = require('http');
const express = require('express');
const { sanitizeDiagnostics, outingRef, stringLeaves, SCHEMA } = require('./outings/diagnostics');
const createOutingsRouter = require('../routes/outings');
const { OutingError } = require('./outings/service');

const SAMPLE = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../../../docs/field-test/sample-diagnostics.json'), 'utf8'),
);

test('the shared sample survives sanitising unchanged', () => {
  const r = sanitizeDiagnostics(SAMPLE);
  assert.equal(r.ok, true);
  assert.deepEqual(r.report, SAMPLE);
});

test('coordinates, names, tokens and unknown keys are dropped', () => {
  const dirty = JSON.parse(JSON.stringify(SAMPLE));
  dirty.lat = 24.7136;
  dirty.lng = 46.6753;
  dirty.display_name = 'أبو فهد';
  dirty.token = 'A'.repeat(43);
  dirty.started_at = '2026-11-03T05:00:00Z';
  dirty.app.platform = 'ios';
  dirty.app.device_name = 'iPhone of Fahad';
  dirty.sends.last_fix = { lat: 24.7, lng: 46.6 };
  dirty.sends.refused_by_reason = { stale_fix: 2, 'Fahad 24.71': 1, rate_limited: -1, ok: 'x' };
  dirty.peers.names = ['سعد'];
  const r = sanitizeDiagnostics(dirty);
  assert.equal(r.ok, true);
  const json = JSON.stringify(r.report);
  for (const leak of ['24.7', '46.6', 'فهد', 'Fahad', 'AAAA', '2026', 'سعد', 'device_name', 'last_fix', 'names']) {
    assert.ok(!json.includes(leak), `leaked ${leak}`);
  }
  assert.deepEqual(r.report.sends.refused_by_reason, { stale_fix: 2 });
  assert.equal(r.report.app.platform, 'ios');
  assert.deepEqual(
    [...new Set(stringLeaves(r.report))].sort(),
    [SCHEMA, 'balanced', 'chrome', 'ios'].sort(),
    'only the schema and enum buckets are strings',
  );
});

test('strings that are not an allowed bucket become "other"; bad numbers become null', () => {
  const r = sanitizeDiagnostics({
    ...SAMPLE,
    app: { platform: 'Riyadh', browser: 'chrome', standalone: 'yes' },
    mode: 'turbo',
    ack_latency_ms: { ...SAMPLE.ack_latency_ms, p95: -5, p99: Infinity, max: '900', mean: 1e12 },
  });
  assert.equal(r.ok, true);
  assert.equal(r.report.app.platform, 'other');
  assert.equal(r.report.app.standalone, null);
  assert.equal(r.report.mode, null);
  assert.equal(r.report.ack_latency_ms.p95, null);
  assert.equal(r.report.ack_latency_ms.p99, null);
  assert.equal(r.report.ack_latency_ms.max, null);
  assert.equal(r.report.ack_latency_ms.mean, null);
});

test('refuses what is not a report', () => {
  assert.equal(sanitizeDiagnostics(null).error, 'invalid_report');
  assert.equal(sanitizeDiagnostics([SAMPLE]).error, 'invalid_report');
  assert.equal(sanitizeDiagnostics({ ...SAMPLE, schema: 'v0' }).error, 'unsupported_schema');
  assert.equal(sanitizeDiagnostics({ schema: SCHEMA }).error, 'invalid_report');
});

test('the outing group key is one-way, stable and 24 hex chars', () => {
  const id = '6f1c2a4e-1111-4222-8333-944455556666';
  assert.match(outingRef(id), /^[0-9a-f]{24}$/);
  assert.equal(outingRef(id), outingRef(id));
  assert.notEqual(outingRef(id), outingRef(id.replace('6f', '7f')));
  assert.ok(!outingRef(id).includes('6f1c2a4e'));
});

test('POST /:id/diagnostics — auth, membership, validation, rate limit', async (t) => {
  const calls = [];
  const service = {
    authenticate: async (token) => (token === 'good' ? { id: 'u1' } : null),
    recordDiagnostics: async (user, outingId, raw) => {
      if (outingId !== 'o1') throw new OutingError('not_a_member', 404);
      const r = sanitizeDiagnostics(raw);
      if (!r.ok) throw new OutingError(r.error, 400);
      calls.push({ user: user.id, outingId, report: r.report });
      return { ok: true };
    },
  };
  const app = express();
  app.use('/api/outings', createOutingsRouter({ service, hub: null, limits: { diagnosticsPerHour: 3 } }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const base = `http://127.0.0.1:${server.address().port}/api/outings`;
  const post = (id, token, body) =>
    fetch(`${base}/${id}/diagnostics`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body),
    }).then(async (res) => ({ status: res.status, body: await res.json() }));

  assert.equal((await post('o1', null, { report: SAMPLE })).status, 401);
  assert.equal((await post('o2', 'good', { report: SAMPLE })).status, 404);
  const bad = await post('o1', 'good', { report: { schema: 'nope' } });
  assert.deepEqual([bad.status, bad.body.error], [400, 'unsupported_schema']);
  assert.equal((await post('o1', 'good', { report: SAMPLE })).status, 201);
  /* Three calls this hour from u1 already — the limit is 3. */
  assert.equal((await post('o1', 'good', { report: SAMPLE })).status, 429);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].outingId, 'o1');
});

test('POST /:id/diagnostics stores the sanitised report', async (t) => {
  const calls = [];
  const service = {
    authenticate: async () => ({ id: 'u1' }),
    recordDiagnostics: async (_user, _id, raw) => {
      calls.push(sanitizeDiagnostics(raw).report);
      return { ok: true };
    },
  };
  const app = express();
  app.use('/api/outings', createOutingsRouter({ service, hub: null }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const res = await fetch(`http://127.0.0.1:${server.address().port}/api/outings/o1/diagnostics`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer x' },
    body: JSON.stringify({ report: { ...SAMPLE, lat: 1 } }),
  });
  assert.equal(res.status, 201);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.deepEqual(calls[0], SAMPLE);
});

test('replay tool: sample passes, a slow phone fails the hard ack threshold', () => {
  const { row } = require('../../../scripts/replay-diagnostics.cjs');
  assert.equal(row('a.json', SAMPLE).verdict, 'PASS');
  const slow = JSON.parse(JSON.stringify(SAMPLE));
  slow.ack_latency_ms.p95 = 4_000;
  const r = row('b.json', slow);
  assert.equal(r.verdict, 'FAIL');
  assert.deepEqual(r._checks.filter((c) => !c.ok).map((c) => c.id), ['ack_p95']);
  slow.ack_latency_ms.p95 = 500;
  slow.battery.drain_pct_per_hour = 30;
  assert.equal(row('c.json', slow).verdict, 'WARN');
});
