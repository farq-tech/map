'use strict';

/**
 * «مباشر / متأخر / منقطع» + why, and the offline backfill. A real Postgres, the
 * real service and router, a fake clock and a recording hub.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-presence.test.js
 *
 * Runs in its own database (`<db>_sary_presence`). The pure tests run without one.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const { Pool } = require('pg');
const { presenceOf, clientOf, LIVE_MS, OFFLINE_MS, reasonText } = require('./outings/presence');
const { featurePayload } = require('./outings/push');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const MIN = 60_000;
const T = Date.parse('2026-11-06T10:00:00Z');

/* ---------------- pure ---------------- */

test('presence: judged on the last fix time, not the socket', () => {
  assert.deepEqual(presenceOf({ nowMs: T, fixAtMs: T - 10_000, heardAtMs: null }), { state: 'live', reason: null });
  assert.equal(presenceOf({ nowMs: T, fixAtMs: T - LIVE_MS - 1, heardAtMs: T }).state, 'stale', 'socket open, fix old: not live');
  assert.equal(presenceOf({ nowMs: T, fixAtMs: T - OFFLINE_MS - 1 }).state, 'offline');
  assert.equal(presenceOf({ nowMs: T, fixAtMs: null }).state, 'offline', 'never sent');
  assert.deepEqual(presenceOf({ nowMs: T, fixAtMs: T, hidden: true }), { state: 'hidden', reason: 'hidden' });
});

test('presence: the most specific reason wins', () => {
  const old = T - 3 * MIN;
  const r = (o) => presenceOf({ nowMs: T, fixAtMs: old, ...o }).reason;
  assert.equal(r({ gps: 'denied', heardAtMs: T }), 'location_off');
  assert.equal(r({ hint: { hint: 'location_off', at: T - MIN } }), 'location_off');
  assert.equal(r({ hint: { hint: 'terminated', at: T - MIN } }), 'app_closed');
  assert.equal(r({ hint: { hint: 'bg_when_in_use', at: T - 2 * MIN } }), 'when_in_use');
  assert.equal(r({ client: 'web' }), 'web');
  assert.equal(r({ heardAtMs: T - 10_000, gps: 'weak' }), 'no_gps', 'we hear the phone but it has no fix');
  assert.equal(r({ heardAtMs: T - 10_000, lowPower: true }), 'low_power');
  assert.equal(r({ lowPower: true }), 'low_power');
  assert.equal(r({}), 'no_network', 'nothing reaches us');
  /* A hint older than the last fix no longer holds. */
  assert.equal(r({ hint: { hint: 'bg_when_in_use', at: old - 60_000 } }), 'no_network');
});

test('presence: client from the User-Agent; Najdi reason lines; push says why', () => {
  assert.equal(clientOf('SaryAlbarq/21 CFNetwork/3860.700.1 Darwin/25.6.0'), 'ios');
  assert.equal(clientOf('Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) Safari/604.1'), 'web');
  assert.equal(clientOf(''), null);
  assert.equal(reasonText('location_off'), 'جواله مقفل الموقع');
  assert.equal(reasonText('no_network'), 'ما فيه شبكة');
  assert.equal(reasonText('nope'), null);
  const p = featurePayload('member_silent', { senderName: 'عبيص', silentMinutes: 10, lastMinutes: 12, level: 10, reason: 'web' });
  assert.equal(p.body, 'عبيص: يتابع من المتصفح — آخر موقع قبل ١٢ د');
  assert.doesNotMatch(p.body, /انقطع/);
});

/* ---------------- database ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_presence`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

function recordingHub(now) {
  const events = [];
  const links = new Map();
  const rooms = new Set();
  return {
    events,
    rooms,
    emit(outingId, event, opts) {
      events.push({ outingId, event, opts });
      return 1;
    },
    heartbeat(outingId, userId, gps) {
      if (!links.has(outingId)) links.set(outingId, new Map());
      links.get(outingId).set(userId, { at: now(), gps: gps || null });
    },
    kick() {},
    closeRoom() {},
    touchPoll(outingId) { rooms.add(outingId); },
    roomIds: () => [...rooms],
    onlineUsers: () => new Set(),
    awayUsers: () => new Set(),
    linkState: (o) => new Map(links.get(o) || []),
  };
}

const quietPush = { enabled: false, async notifyMembers() { return { sent: 0 }; }, async notifyWatchers() { return { sent: 0 }; } };

async function setup(t) {
  const { createPool, migrate } = require('./outings/db');
  const { createOutingsService } = require('./outings/service');
  const createOutingsRouter = require('../routes/outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);
  let offset = 0;
  const now = () => Date.now() + offset;
  const advance = (ms) => { offset += ms; };
  const hub = recordingHub(now);
  const svc = createOutingsService({ pool, events: hub, push: quietPush, config: { minFixIntervalMs: 0, persistEveryMs: 0 }, now });
  const app = express();
  app.use('/api/outings', createOutingsRouter({ service: svc, hub, limits: { identityPerHour: 100 } }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  t.after(async () => {
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const api = async (method, path, token, body, ua = 'SaryAlbarq/22 CFNetwork/1 Darwin/25') => {
    const res = await fetch(`http://127.0.0.1:${port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', 'user-agent': ua, ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body && method !== 'GET' ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const mk = async (name) => {
    const { user, token } = await svc.createUser({ display_name: name });
    return { ...user, token };
  };
  return { svc, hub, api, mk, advance, pool };
}

const fixAt = (i, ageMs = 300) => ({ lat: 24.7113 + 0.001 * i, lng: 46.6744 + 0.001 * i, accuracy: 8, speed: 3, age_ms: ageMs });

test('presence in the snapshot + member_presence on change, with the reason', { skip, timeout: 60_000 }, async (t) => {
  const { svc, hub, api, mk, advance } = await setup(t);
  const A = await mk('احمد');
  const B = await mk('عبيص');
  const W = await mk('ام عبيص');
  const { outing_id: O, invite } = await svc.createOuting(A, { name: 'طلعة' });
  await svc.joinByInvite(B, invite.token);
  await svc.joinByInvite(W, invite.token);
  await svc.setStatus(A, O, 'start');
  const pres = async (uid) => (await svc.getOuting(A, O)).members.find((m) => m.user_id === uid).presence;

  /* B on the app: live. */
  assert.equal((await api('POST', `/${O}/positions`, B.token, { fix: fixAt(1) })).status, 200);
  assert.equal((await pres(B.id)).state, 'live');

  /* W joined from Safari and never sent: offline, «يتابع من المتصفح». */
  await api('POST', `/${O}/heartbeat`, W.token, { gps: 'ok' }, 'Mozilla/5.0 (iPhone) Safari/604.1');
  assert.deepEqual([(await pres(W.id)).state, (await pres(W.id)).reason], ['offline', 'web']);

  /* B goes to the background with «أثناء الاستخدام» only: the app says so before it stops. */
  await api('POST', `/${O}/heartbeat`, B.token, { gps: 'ok', hint: 'bg_when_in_use' });
  advance(2 * MIN);
  const p = await pres(B.id);
  assert.deepEqual([p.state, p.reason], ['stale', 'when_in_use']);
  assert.ok(p.last_fix_at, 'last fix time travels with it');

  /* The sweep tells the others once, not again while nothing changes. */
  await svc.sweepPresence();
  await svc.sweepPresence();
  const evs = hub.events.filter((e) => e.event.type === 'member_presence' && e.event.user_id === B.id);
  assert.equal(evs.length, 1);
  assert.equal(evs[0].event.state, 'stale');
  assert.equal(evs[0].event.reason, 'when_in_use');
  assert.equal(evs[0].opts.exceptUser, B.id);

  /* Location permission revoked: «جواله مقفل الموقع». */
  await api('POST', `/${O}/heartbeat`, B.token, { gps: 'denied' });
  assert.equal((await pres(B.id)).reason, 'location_off');

  /* 10 min on: offline (reason kept). A fresh fix: live again, announced. */
  advance(9 * MIN);
  assert.equal((await pres(B.id)).state, 'offline');
  await api('POST', `/${O}/heartbeat`, B.token, { gps: 'ok', hint: 'fg' });
  assert.equal((await api('POST', `/${O}/positions`, B.token, { fix: fixAt(2) })).status, 200);
  assert.equal((await pres(B.id)).state, 'live');
  const last = hub.events.filter((e) => e.event.type === 'member_presence' && e.event.user_id === B.id).at(-1);
  assert.equal(last.event.state, 'live');
});

test('backfill: offline positions uploaded in one batch, never shown as live', { skip, timeout: 60_000 }, async (t) => {
  const { svc, hub, api, mk, advance } = await setup(t);
  const A = await mk('احمد');
  const B = await mk('فهد');
  const X = await mk('غريب');
  const { outing_id: O, invite } = await svc.createOuting(A, { name: 'طلعة' });
  await svc.joinByInvite(B, invite.token);
  await svc.setStatus(A, O, 'start');
  assert.equal((await api('POST', `/${O}/positions`, B.token, { fix: fixAt(0) })).status, 200);
  advance(20 * MIN);

  /* 20 minutes without network: one fix a minute queued on the phone. */
  const fixes = [];
  for (let i = 20; i >= 2; i -= 1) fixes.push(fixAt(21 - i, i * MIN));
  fixes.push({ lat: 'bad' });
  fixes.push(fixAt(99, 30 * 3600_000)); // older than the backfill window
  const r = await api('POST', `/${O}/positions/batch`, B.token, { fixes });
  assert.equal(r.status, 200);
  assert.equal(r.body.accepted, 19);
  assert.equal(r.body.rejected, 2);
  assert.equal(r.body.applied, true);

  const snap = await svc.getOuting(A, O);
  const pos = snap.positions.find((p) => p.user_id === B.id);
  assert.ok(Date.now() + 20 * MIN - Date.parse(pos.recorded_at) >= 50_000, 'the newest queued fix, with its true (old) time');
  assert.notEqual(snap.members.find((m) => m.user_id === B.id).presence.state, 'live', 'a backfilled fix is not live');
  const bf = hub.events.filter((e) => e.event.type === 'backfill');
  assert.equal(bf.length, 1);
  assert.equal(bf[0].event.fixes.length, 19);
  assert.ok(bf[0].event.fixes.every((f, i, a) => i === 0 || f.recorded_at >= a[i - 1].recorded_at), 'oldest first');
  const posEv = hub.events.filter((e) => e.event.type === 'position' && e.event.position.backfill);
  assert.equal(posEv.length, 1);

  /* An older batch never replaces a newer position. */
  assert.equal((await api('POST', `/${O}/positions`, B.token, { fix: fixAt(50) })).status, 200);
  const again = await api('POST', `/${O}/positions/batch`, B.token, { fixes: [fixAt(3, 5 * MIN)] });
  assert.equal(again.body.applied, false);

  /* Refusals: not a member, not an array. */
  assert.equal((await api('POST', `/${O}/positions/batch`, X.token, { fixes })).status, 404);
  assert.equal((await api('POST', `/${O}/positions/batch`, B.token, { fixes: 'x' })).status, 400);
});
