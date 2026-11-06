'use strict';

/**
 * «انقطع الإرسال» — sharing went silent. A real Postgres, the real service
 * and router, a fake clock, a recording hub and a recording push notifier.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-silence.test.js
 *
 * Runs in its own database (`<db>_sary_silence`). The pure tests at the top
 * run without a database.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const { Pool } = require('pg');
const { featurePayload } = require('./outings/push');
const { apnsRequestFor } = require('./outings/apns');
const { levelFor, BOOT_GRACE_MS } = require('./outings/silence');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const MIN = 60_000;
const RIYADH = { lat: 24.7136, lng: 46.6753 };
const fix = (i = 0) => ({ lat: RIYADH.lat + 0.001 * i, lng: RIYADH.lng + 0.001 * i, accuracy: 8, heading: 45, speed: 3, age_ms: 300 });

/* ---------------- pure ---------------- */

test('silence levels: 10 and 30 minutes', () => {
  assert.equal(levelFor(9.9 * MIN), 0);
  assert.equal(levelFor(10 * MIN), 10);
  assert.equal(levelFor(29 * MIN), 10);
  assert.equal(levelFor(30 * MIN), 30);
  assert.equal(levelFor(5 * 3600_000), 30);
  assert.equal(levelFor(-1), 0);
});

test('member_silent push: Arabic text with Arabic-Indic digits, time-sensitive on iOS', () => {
  const p = featurePayload('member_silent', { senderName: 'فهد', outingName: 'طلعة النفود', silentMinutes: 10, lastMinutes: 10, level: 10, userId: 'u1' });
  assert.equal(p.type, 'member_silent');
  assert.equal(p.body, 'انقطع إرسال فهد منذ ١٠ د — آخر موقع قبل ١٠ د');
  assert.equal(p.title, '📡 انقطع إرسال فهد · طلعة النفود');
  assert.equal(p.tag, 'sary-silent-u1', 'the 30-min alert replaces the 10-min one on the lock screen');
  assert.equal(p.urgency, 'high');
  assert.notEqual(p.always, true, 'members with the outing on screen get the in-app card instead');
  assert.equal(featurePayload('member_silent', { senderName: 'فهد', silentMinutes: 31, lastMinutes: 33, level: 30 }).body, 'انقطع إرسال فهد منذ ٣١ د — آخر موقع قبل ٣٣ د');
  const req = apnsRequestFor(p, 'o1', { now: Date.parse('2026-11-04T10:00:00Z') });
  const aps = JSON.parse(req.body).aps;
  assert.equal(aps['interruption-level'], 'time-sensitive');
  assert.equal(aps.sound, 'default');
  assert.equal(req.headers['apns-priority'], '10');
  assert.equal(req.headers['apns-collapse-id'], 'sary-silent-u1');
});

/* ---------------- database ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_silence`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

function recordingHub() {
  const events = [];
  return {
    events,
    emit(outingId, event, opts) {
      events.push({ outingId, event, opts });
      return 1;
    },
    kick() {},
    closeRoom() {},
    touchPoll() {},
    onlineUsers: () => new Set(),
    awayUsers: () => new Set(),
    linkState: () => new Map(),
  };
}

function recordingPush() {
  const sent = [];
  return {
    sent,
    enabled: true,
    async notifyMembers(outingId, exceptUserId, payload) {
      sent.push({ outingId, exceptUserId, payload });
      return { sent: 1, removed: 0, failed: 0, skipped: 0 };
    },
    async notifyWatchers() {
      return { sent: 0, removed: 0, failed: 0, skipped: 0 };
    },
  };
}

test('sharing went silent: 10 / 30 min alerts, resume, no alert when paused / left / ended / going offline, restart', { skip, timeout: 120_000 }, async (t) => {
  const { createPool, migrate } = require('./outings/db');
  const { createOutingsService } = require('./outings/service');
  const createOutingsRouter = require('../routes/outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);

  let offset = 0;
  const now = () => Date.now() + offset;
  const advance = (ms) => { offset += ms; };
  const config = { minFixIntervalMs: 0, persistEveryMs: 0 };

  const hub = recordingHub();
  const push = recordingPush();
  const svc = createOutingsService({ pool, events: hub, push, config, now });

  const app = express();
  app.use('/api/outings', createOutingsRouter({ service: svc, hub, limits: { identityPerHour: 100 } }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  t.after(async () => {
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const api = async (method, path, token, body) => {
    const res = await fetch(`http://127.0.0.1:${port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body && method !== 'GET' ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };

  const mk = async (name) => {
    const { user, token } = await svc.createUser({ display_name: name });
    return { ...user, token };
  };
  const A = await mk('أبو فهد');
  const B = await mk('فهد');
  const C = await mk('سعد');
  const D = await mk('ناصر');
  const { outing_id: O, invite } = await svc.createOuting(A, { name: 'طلعة النفود' });
  for (const p of [B, C, D]) await svc.joinByInvite(p, invite.token);
  await svc.setStatus(A, O, 'start');

  let step = 0;
  const send = async (who) => {
    step += 1;
    const r = await svc.recordPosition(who, O, fix(step));
    assert.equal(r.ok, true, `fix from ${who.display_name}: ${r.reason}`);
    return r;
  };
  const silentEvents = (uid) => hub.events.filter((e) => e.outingId === O && e.event.type === 'member_silent' && (!uid || e.event.user_id === uid)).map((e) => e.event);
  const resumedEvents = (uid) => hub.events.filter((e) => e.outingId === O && e.event.type === 'member_resumed' && e.event.user_id === uid).map((e) => e.event);
  const silentPushes = (uid) => push.sent.filter((p) => p.outingId === O && p.payload.type === 'member_silent' && p.exceptUserId === uid);
  const until = async (pred, ms = 3000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (pred()) return;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error('timeout');
  };
  const silentList = async (who = A) => (await svc.getOuting(who, O)).silent;
  /* Move the clock in one-minute sweeps, keeping `alive` sending. */
  const walk = async (minutes, alive = []) => {
    for (let i = 0; i < minutes; i += 1) {
      advance(MIN);
      for (const p of alive) await send(p);
      await svc.sweepSilence();
    }
  };

  for (const p of [A, B, C, D]) await send(p);
  await svc.sweepSilence();
  assert.deepEqual(silentEvents(), [], 'everyone fresh');

  /* ---- B stops sending. 9 min: nothing. 10 min: one alert. ---- */
  const bLast = (await svc.getOuting(A, O)).positions.find((p) => p.user_id === B.id);
  await walk(9, [A, C, D]);
  assert.deepEqual(silentEvents(), [], 'not before 10 min');
  assert.deepEqual(await silentList(), []);
  await walk(1, [A, C, D]);
  assert.equal(silentEvents(B.id).length, 1, 'fires at 10 min');
  const ev10 = silentEvents(B.id)[0];
  assert.deepEqual(Object.keys(ev10).sort(), ['last', 'level', 'reason', 'since', 'type', 'user_id']);
  assert.equal(ev10.reason, 'no_network', 'nothing at all reaches us from B: the reason says so');
  assert.equal(ev10.level, 10);
  assert.equal(ev10.since, bLast.received_at);
  assert.deepEqual(ev10.last, { lat: bLast.lat, lng: bLast.lng, at: bLast.recorded_at });
  assert.equal(silentEvents().length, 1, 'only B');
  await until(() => silentPushes(B.id).length);
  const p10 = silentPushes(B.id);
  assert.equal(p10.length, 1, 'one push, to everyone but B');
  assert.equal(p10[0].payload.body, 'فهد: ما فيه شبكة — آخر موقع قبل ١٠ د', 'the push says why, not a vague «انقطع»');
  assert.equal(p10[0].payload.urgency, 'high');

  /* Live snapshot (HTTP fallback) carries it. */
  const live = await api('GET', `/${O}/live`, A.token);
  assert.equal(live.status, 200);
  assert.deepEqual(live.body.silent.map(({ user_id, since, level }) => ({ user_id, since, level })), [{ user_id: B.id, since: bLast.received_at, level: 10 }]);

  /* Once, not every minute. */
  await walk(19, [A, C, D]);
  assert.equal(silentEvents(B.id).length, 1, 'no repeat between 10 and 30');
  /* 30 min: escalates once. */
  await walk(1, [A, C, D]);
  assert.deepEqual(silentEvents(B.id).map((e) => e.level), [10, 30], 'escalates at 30');
  await walk(5, [A, C, D]);
  assert.deepEqual(silentEvents(B.id).map((e) => e.level), [10, 30], 'and never again');
  await until(() => silentPushes(B.id).length >= 2);
  assert.equal(silentPushes(B.id).length, 2);
  assert.match(silentPushes(B.id)[1].payload.body, /^فهد: ما فيه شبكة — آخر موقع قبل ٣٠ د/);
  assert.equal((await silentList())[0].level, 30);

  /* ---- B comes back: quiet member_resumed, reset. ---- */
  const pushesBefore = push.sent.length;
  await send(B);
  await new Promise((r) => setTimeout(r, 100));
  assert.deepEqual(resumedEvents(B.id), [{ type: 'member_resumed', user_id: B.id }]);
  assert.equal(push.sent.length, pushesBefore, 'resuming is quiet: no push');
  assert.deepEqual(await silentList(), []);
  /* …and a new silence alerts again from the start. */
  await walk(10, [A, C, D]);
  assert.deepEqual(silentEvents(B.id).map((e) => e.level), [10, 30, 10], 'reset: a new silence fires at 10 again');
  await send(B);

  /* ---- C pauses sharing: never alerted. ---- */
  assert.deepEqual(await svc.setSharing(C, O, false), { sharing: false });
  await walk(12, [A, B, D]);
  assert.equal(silentEvents(C.id).length, 0, 'sharing off: no alert');
  await svc.setSharing(C, O, true);
  await walk(12, [A, B, D]);
  assert.equal(silentEvents(C.id).length, 0, 'sharing back on but no fix yet: nothing to say');
  await send(C);

  /* ---- D says «بطلع من التغطية»: no alert until the next fix. ---- */
  const off = await api('POST', `/${O}/going-offline`, D.token, { minutes: 90 });
  assert.equal(off.status, 200);
  assert.ok(off.body.until);
  assert.ok(hub.events.some((e) => e.event.type === 'member_going_offline' && e.event.user_id === D.id && e.opts?.exceptUser === D.id));
  assert.equal((await api('POST', `/${O}/going-offline`, 'nope', {})).status, 401);
  await walk(35, [A, B, C]);
  assert.equal(silentEvents(D.id).length, 0, 'announced offline: no alert');
  await send(D); // back: the notice is used up
  await walk(10, [A, B, C]);
  assert.equal(silentEvents(D.id).length, 1, 'after coming back, a new silence alerts again');
  /* Announcing while already alerted clears the card. */
  await svc.goingOffline(D, O, {});
  assert.deepEqual(resumedEvents(D.id).at(-1), { type: 'member_resumed', user_id: D.id, reason: 'going_offline' });
  assert.deepEqual((await silentList()).map((s) => s.user_id), []);
  await send(D);

  /* ---- C goes silent, then leaves: cleared with a reason, never again. ---- */
  await walk(10, [A, B, D]);
  assert.equal(silentEvents(C.id).length, 1);
  await svc.leave(C, O);
  assert.deepEqual(resumedEvents(C.id).at(-1), { type: 'member_resumed', user_id: C.id, reason: 'left' });
  await walk(25, [A, B, D]);
  assert.equal(silentEvents(C.id).length, 1, 'left: no 30-min alert');
  assert.equal((await silentList()).length, 0);

  /* ---- Outing paused: nobody is alerted; after resume nothing until a fresh fix. ---- */
  await svc.setStatus(A, O, 'pause');
  const before = silentEvents().length;
  await walk(15);
  assert.equal(silentEvents().length, before, 'paused: no alerts');
  assert.deepEqual(await silentList(), []);
  await svc.setStatus(A, O, 'resume');
  await walk(15);
  assert.equal(silentEvents().length, before, 'resumed, fixes were deleted on pause: no alerts');
  for (const p of [A, B, D]) await send(p);
  await walk(10, [A, D]);
  assert.equal(silentEvents(B.id).length, 4, 'after resume, a real silence alerts');
  assert.deepEqual((await silentList()).map((s) => s.user_id), [B.id]);

  /* ---- Ended: dropped, no more alerts. ---- */
  await svc.setStatus(A, O, 'end');
  const atEnd = silentEvents().length;
  await walk(25);
  assert.equal(silentEvents().length, atEnd, 'ended: no alerts');
  assert.deepEqual(await silentList(), []);

  /* ---- Restart: state rebuilds from the last position times. ---- */
  const E = await mk('عبدالله');
  const F = await mk('خالد');
  const G = await mk('تركي');
  const o2 = await svc.createOuting(E, { name: 'طلعة الصمان' });
  for (const p of [F, G]) await svc.joinByInvite(p, o2.invite.token);
  await svc.setStatus(E, o2.outing_id, 'start');
  const O2 = o2.outing_id;
  const send2 = async (who) => {
    step += 1;
    assert.equal((await svc.recordPosition(who, O2, fix(step))).ok, true);
  };
  await send2(E);
  await send2(F);
  for (let i = 0; i < 10; i += 1) {
    advance(MIN);
    await send2(E);
    await send2(G);
    await svc.sweepSilence();
  }
  const ev2 = (h, uid) => h.events.filter((e) => e.outingId === O2 && e.event.type === 'member_silent' && e.event.user_id === uid).map((e) => e.event.level);
  assert.deepEqual(ev2(hub, F.id), [10], 'first process alerted F at 10');

  /* The process restarts 2 min later (deploy). */
  advance(2 * MIN);
  await send2(E);
  await send2(G);
  const hub2 = recordingHub();
  const push2 = recordingPush();
  const svc2 = createOutingsService({ pool, events: hub2, push: push2, config, now });
  await svc2.sweepSilence();
  assert.deepEqual(ev2(hub2, F.id), [], 'after the restart: no second 10-min alarm');
  assert.deepEqual((await svc2.getOuting(E, O2)).silent.map((s) => [s.user_id, s.level]), [[F.id, 10]], 'rebuilt: F still shown as silent');
  for (let i = 0; i < 18; i += 1) {
    advance(MIN);
    await send2(E);
    await send2(G);
    await svc2.sweepSilence();
  }
  assert.deepEqual(ev2(hub2, F.id), [30], 'the new process still escalates at 30');
  await until(() => push2.sent.length);
  assert.equal(push2.sent.filter((p) => p.payload.type === 'member_silent').length, 1);

  /* A threshold crossed while the server was briefly down still fires: G stops,
   * the old process dies at 9 min of G's silence, a new one starts at 10.5. */
  for (let i = 0; i < 9; i += 1) {
    advance(MIN);
    await send2(E);
    await send2(F);
  }
  advance(1.5 * MIN);
  await send2(E);
  const hub3 = recordingHub();
  const svc3 = createOutingsService({ pool, events: hub3, push: recordingPush(), config, now });
  assert.ok(BOOT_GRACE_MS >= MIN, 'grace covers one sweep interval');
  await svc3.sweepSilence();
  assert.deepEqual(ev2(hub3, G.id), [10], 'crossed during the downtime: alerted by the new process');
  assert.deepEqual(ev2(hub3, F.id), [], 'F sent fixes: not silent');
});
