'use strict';

/**
 * «المشاوير» — legs inside an outing (lib/outings/legs.js, migration 016).
 *
 *   node --test apps/api/lib/outings-legs.test.js                    (pure parts)
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-legs.test.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { parseLegStart, parseLegTotals } = require('./outings/legs');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- pure ---------------- */

test('leg start body: a named place, group by default, personal on request, a safe client id', () => {
  const ok = parseLegStart({ destination: { name: ' مخيم النفود ', lat: 28.1, lng: 41.2 } });
  assert.deepEqual(ok.value, { destination: { name: 'مخيم النفود', lat: 28.1, lng: 41.2 }, scope: 'group', clientId: null });
  assert.equal(parseLegStart({ destination: { name: 'محطة', lat: 24.7, lng: 46.6 }, scope: 'personal', client_id: 'a-1_B' }).value.scope, 'personal');
  assert.equal(parseLegStart(null).error, 'invalid_leg');
  assert.equal(parseLegStart({}).error, 'invalid_destination');
  assert.equal(parseLegStart({ destination: { name: '', lat: 1, lng: 1 } }).error, 'invalid_destination');
  assert.equal(parseLegStart({ destination: { name: 'x', lat: 91, lng: 1 } }).error, 'invalid_destination');
  assert.equal(parseLegStart({ destination: { name: 'x', lat: 1, lng: 1 }, scope: 'everyone' }).error, 'invalid_scope');
  assert.equal(parseLegStart({ destination: { name: 'x', lat: 1, lng: 1 }, client_id: 'no spaces' }).error, 'invalid_client_id');
});

test('leg totals: whole, in range, else absent', () => {
  assert.deepEqual(parseLegTotals({ distance_m: 12345.6, duration_s: 600.2 }), { distance_m: 12346, duration_s: 600 });
  assert.deepEqual(parseLegTotals({ distance_m: -1, duration_s: 'x' }), { distance_m: null, duration_s: null });
  assert.deepEqual(parseLegTotals({ distance_m: 9e9 }), { distance_m: 3_000_000, duration_s: null });
  assert.deepEqual(parseLegTotals(undefined), { distance_m: null, duration_s: null });
});

/* ---------------- database ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_legs`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('legs end to end: leader group legs, personal legs, old clients see the destination, arrival ends the leg only, the end closes the rest', { skip, timeout: 60_000 }, async (t) => {
  const { createPool, migrate } = require('./outings/db');
  const { setupOutings } = require('./outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  const applied = await migrate(pool);
  assert.ok(applied.includes('016_sary_outing_legs.sql'));
  /* Additive and re-runnable: the migration applies again on top of itself. */
  await pool.query(require('fs').readFileSync(require('path').join(__dirname, '..', 'migrations', '016_sary_outing_legs.sql'), 'utf8'));
  const outings = setupOutings({ pool, autoMigrate: false, config: { minFixIntervalMs: 0, persistEveryMs: 0 }, limits: { identityPerHour: 100, invitePer10Min: 100 } });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  outings.attach(server);
  const port = server.address().port;
  t.after(async () => {
    outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const base = `http://127.0.0.1:${port}/api/outings`;
  const api = async (method, path, token, body) => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body && method !== 'GET' ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  function live(token, outingId) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    const inbox = [];
    ws.on('message', (d, isBinary) => (isBinary ? null : inbox.push(JSON.parse(String(d)))));
    const next = async (pred, ms = 3000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const i = inbox.findIndex(pred);
        if (i >= 0) return inbox.splice(i, 1)[0];
        await sleep(10);
      }
      throw new Error('timeout waiting for message');
    };
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    return { ws, inbox, next, opened };
  }

  const mk = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  const [A, B, X] = [await mk('أبو فهد'), await mk('سعد'), await mk('غريب')];
  const created = await api('POST', '/', A.token, { name: 'كشتة النفود' });
  const O = created.body.outing_id;
  assert.equal((await api('POST', '/invites/join', B.token, { token: created.body.invite.token })).status, 200);

  const camp = { name: 'مخيم النفود', lat: 28.12, lng: 41.25 };
  const gas = { name: 'محطة الوقود', lat: 24.72, lng: 46.69 };

  /* Not started: no legs yet (an outing needs no destination; a leg needs a running outing). */
  assert.deepEqual((await api('GET', `/${O}/legs`, A.token)).body.legs, []);
  assert.equal((await api('POST', `/${O}/legs`, A.token, { destination: gas })).body.error, 'outing_not_active');
  await api('POST', `/${O}/status`, A.token, { action: 'start' });

  /* Strangers and members. */
  assert.equal((await api('GET', `/${O}/legs`, X.token)).status, 404);
  assert.equal((await api('POST', `/${O}/legs`, X.token, { destination: gas })).status, 404);
  assert.equal((await api('POST', `/${O}/legs`, B.token, { destination: gas })).body.error, 'leader_only');
  assert.equal((await api('POST', `/${O}/legs`, A.token, { destination: { name: 'x' } })).body.error, 'invalid_destination');
  assert.equal((await api('GET', `/${O}/legs`, null)).status, 401);

  const wsB = live(B.token, O);
  await wsB.opened;
  await wsB.next((m) => m.type === 'ready' || m.type === 'snapshot' || m.type === 'auth_ok', 3000).catch(() => null);

  /* Leg 1 (group): home → gas station. Old clients see it as the plan's destination. */
  const l1 = await api('POST', `/${O}/legs`, A.token, { destination: gas, client_id: 'leg-1' });
  assert.equal(l1.status, 201);
  assert.equal(l1.body.leg.seq, 1);
  assert.equal(l1.body.leg.scope, 'group');
  assert.equal(l1.body.leg.state, 'active');
  assert.deepEqual(l1.body.leg.destination, gas);
  assert.deepEqual((await api('GET', `/${O}/plan`, B.token)).body.destination, gas);
  assert.equal((await wsB.next((m) => m.type === 'leg_updated')).leg.id, l1.body.leg.id);
  assert.deepEqual((await wsB.next((m) => m.type === 'plan_updated')).plan.destination, gas);
  /* A retried start is the same leg. */
  const again = await api('POST', `/${O}/legs`, A.token, { destination: gas, client_id: 'leg-1' });
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);
  assert.equal(again.body.leg.id, l1.body.leg.id);

  /* A member's own leg: only they see it, and the plan is untouched. */
  const p1 = await api('POST', `/${O}/legs`, B.token, { destination: { name: 'بيت أبوي', lat: 24.8, lng: 46.7 }, scope: 'personal' });
  assert.equal(p1.status, 201);
  assert.equal(p1.body.leg.scope, 'personal');
  assert.deepEqual((await api('GET', `/${O}/plan`, A.token)).body.destination, gas);
  const seenA = (await api('GET', `/${O}/legs`, A.token)).body;
  assert.equal(seenA.legs.length, 1);
  assert.equal(seenA.current.id, l1.body.leg.id);
  assert.equal(seenA.mine, null);
  const seenB = (await api('GET', `/${O}/legs`, B.token)).body;
  assert.equal(seenB.legs.length, 2);
  assert.equal(seenB.mine.id, p1.body.leg.id);
  assert.equal((await api('POST', `/${O}/legs/${p1.body.leg.id}/arrive`, A.token, {})).status, 404);
  assert.equal((await api('POST', `/${O}/legs/${p1.body.leg.id}/cancel`, B.token)).body.leg.state, 'cancelled');

  /* Members cannot close the group's leg; the leader's «وصلنا» ends that leg only. */
  assert.equal((await api('POST', `/${O}/legs/${l1.body.leg.id}/arrive`, B.token, {})).body.error, 'leader_only');
  const a1 = await api('POST', `/${O}/legs/${l1.body.leg.id}/arrive`, A.token, { distance_m: 8200, duration_s: 900 });
  assert.equal(a1.status, 200);
  assert.equal(a1.body.leg.state, 'arrived');
  assert.equal(a1.body.leg.distance_m, 8200);
  assert.equal(a1.body.leg.duration_s, 900);
  assert.ok(a1.body.leg.arrived_at);
  assert.equal((await wsB.next((m) => m.type === 'leg_updated' && m.leg.state === 'arrived')).leg.id, l1.body.leg.id);
  /* Idempotent. */
  assert.equal((await api('POST', `/${O}/legs/${l1.body.leg.id}/arrive`, A.token, {})).body.leg.distance_m, 8200);
  assert.equal((await api('POST', `/${O}/legs/${l1.body.leg.id}/cancel`, A.token)).body.error, 'leg_closed');
  /* The outing is still running. */
  assert.equal((await api('GET', `/${O}`, A.token)).body.outing.status, 'active');

  /* Leg 2 → camp, then a changed mind → روضة (leg 2 is cancelled, not a leg in the timeline). */
  const l2 = await api('POST', `/${O}/legs`, A.token, { destination: camp });
  assert.equal(l2.body.leg.seq, 3);
  const l3 = await api('POST', `/${O}/legs`, A.token, { destination: { name: 'روضة خريم', lat: 25.4, lng: 47.2 } });
  const after = (await api('GET', `/${O}/legs`, A.token)).body.legs;
  assert.equal(after.find((l) => l.id === l2.body.leg.id).state, 'cancelled');
  assert.equal(after.filter((l) => l.state === 'active').length, 1);
  assert.equal((await api('GET', `/${O}/plan`, B.token)).body.destination.name, 'روضة خريم');
  assert.equal((await api('POST', `/${O}/legs/not-a-uuid/arrive`, A.token, {})).status, 404);

  /* «أنهِ الطلعة»: the leg on the way reads as ended; nothing new can start. */
  await api('POST', `/${O}/status`, A.token, { action: 'end' });
  const ended = (await api('GET', `/${O}/legs`, A.token));
  assert.equal(ended.status, 200);
  assert.equal(ended.body.legs.find((l) => l.id === l3.body.leg.id).state, 'ended');
  assert.equal(ended.body.current, null);
  assert.equal((await api('POST', `/${O}/legs`, A.token, { destination: gas })).body.error, 'outing_ended');

  /* Deleting an identity takes its personal legs; group legs forget who started them. */
  const rowsBefore = (await pool.query(`SELECT count(*)::int AS n FROM sary.outing_legs WHERE owner_user_id IS NOT NULL`)).rows[0].n;
  assert.equal(rowsBefore, 1);
  wsB.ws.close();
});
