'use strict';

/**
 * Scale guards for shared outings (no database needed):
 *   · sweeps never overlap themselves,
 *   · a slow phone's socket does not hoard frames (hub backpressure),
 *   · the live-socket ceiling answers 503 and a restart says goodbye with 1012,
 *   · recordPosition does not send the no-op `updated_at` write on every persisted fix,
 *   · cache entries made together do not expire together,
 *   · the per-address limits are tunable from the environment.
 *
 *   node --test apps/api/lib/outings-scale.test.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { createGuardedInterval } = require('./outings/interval');
const { createHub } = require('./outings/hub');
const { attachOutingsSocket } = require('./outings/ws');
const { createOutingsService } = require('./outings/service');
const createOutingsRouter = require('../routes/outings');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('a guarded interval skips a tick while the previous run is still going', async () => {
  let started = 0;
  let overlap = 0;
  let live = 0;
  let release;
  const gate = new Promise((r) => { release = r; });
  const tracked = [];
  let tick;
  const g = createGuardedInterval(
    30_000,
    'slow',
    async () => {
      started += 1;
      live += 1;
      overlap = Math.max(overlap, live);
      await gate;
      live -= 1;
    },
    { track: (p) => tracked.push(p), setIntervalFn: (fn) => { tick = fn; return { unref() {} }; } },
  );
  tick(); tick(); tick(); tick();
  await sleep(0);
  assert.equal(started, 1, 'the first tick starts a run; the next three find it busy');
  assert.equal(g.skipped(), 3);
  assert.equal(g.running(), true);
  release();
  await Promise.all(tracked);
  assert.equal(g.running(), false);
  tick();
  await sleep(0);
  assert.equal(started, 2, 'once the run is over the next tick starts a new one');
  await Promise.all(tracked);
  assert.equal(overlap, 1, 'never two runs at once');
});

test('a guarded interval survives a failing run and logs it by name', async () => {
  const logs = [];
  const tracked = [];
  const g = createGuardedInterval(5, 'boom', async () => { throw Object.assign(new Error('x'), { code: 'E_BOOM' }); }, { track: (p) => tracked.push(p), log: (...a) => logs.push(a.join(' ')) });
  await sleep(40);
  g.stop();
  await Promise.all(tracked);
  assert.ok(logs.length >= 2, 'it kept running after the first failure');
  assert.match(logs[0], /boom/);
  assert.match(logs[0], /E_BOOM/);
});

function fakeConn(userId, buffered) {
  const sent = [];
  const ws = { readyState: 1, bufferedAmount: buffered, send: (m) => sent.push(JSON.parse(m)), terminate() { ws.terminated = true; } };
  return { ws, userId, sent };
}

test('hub: a slow socket skips superseded frames but still gets chat, and a hopeless one is cut', () => {
  const hub = createHub();
  const fast = fakeConn('u-fast', 0);
  const slow = fakeConn('u-slow', 300 * 1024);
  const stuck = fakeConn('u-stuck', 9 * 1024 * 1024);
  for (const c of [fast, slow, stuck]) hub.join('o1', c);
  fast.sent.length = slow.sent.length = stuck.sent.length = 0;
  hub.emit('o1', { type: 'position', position: { user_id: 'u-other', lat: 1, lng: 1 } });
  hub.emit('o1', { type: 'chat_message', message: { text: 'hi' } });
  assert.deepEqual(fast.sent.map((m) => m.type), ['position', 'chat_message']);
  assert.deepEqual(slow.sent.map((m) => m.type), ['chat_message'], 'the position is superseded by the next one: skipped');
  assert.equal(stuck.ws.terminated, true, 'past the hard ceiling the socket is dropped (the app reconnects with a snapshot)');
  assert.deepEqual(stuck.sent, []);
  const st = hub.stats();
  assert.ok(st.slow_dropped >= 1 && st.slow_killed >= 1);
});

async function listen(attachOpts = {}) {
  const hub = createHub();
  const service = {
    authenticate: async (t) => ({ id: t, display_name: t }),
    membership: async () => ({ status: 'active', outing_status: 'active', role: 'member' }),
    getOuting: async () => ({ outing: {}, members: [], positions: [] }),
  };
  const server = http.createServer();
  const socket = attachOutingsSocket(server, { service, hub, heartbeatMs: 60_000, ...attachOpts });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, socket, url: `ws://127.0.0.1:${server.address().port}/api/outings/live`, hub };
}

const OUTING = '47ba65dc-0000-4000-8000-000000000001';

function phone(url, token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const out = { ws, closed: null, refused: null };
    ws.on('open', () => ws.send(JSON.stringify({ type: 'auth', token, outing_id: OUTING })));
    ws.on('message', (d) => {
      if (JSON.parse(String(d)).type === 'ready') resolve(out);
    });
    ws.on('close', (code) => { out.closed = code; });
    ws.on('unexpected-response', (_req, res) => {
      out.refused = res.statusCode;
      out.retryAfter = res.headers['retry-after'];
      resolve(out);
    });
    ws.on('error', () => {});
    setTimeout(() => reject(new Error('phone timeout')), 3000).unref();
  });
}

test('live sockets: past the ceiling a new phone gets 503 + Retry-After, those already in keep working', async (t) => {
  const L = await listen({ maxSockets: 2 });
  t.after(() => { L.socket.close(); L.server.close(); });
  const a = await phone(L.url, 'ua');
  const b = await phone(L.url, 'ub');
  const c = await phone(L.url, 'uc');
  assert.equal(c.refused, 503);
  assert.equal(c.retryAfter, '5');
  assert.equal(a.refused, null);
  assert.equal(b.refused, null);
  assert.equal(L.socket.stats().refused, 1);
  assert.equal(a.ws.readyState, WebSocket.OPEN);
  for (const p of [a, b]) p.ws.close();
});

test('a restarting server closes live sockets with 1012 so the apps reconnect', async () => {
  const L = await listen();
  const a = await phone(L.url, 'ua');
  L.socket.close();
  await sleep(200);
  assert.equal(a.closed, 1012);
  await new Promise((r) => L.server.close(r));
});

/** A pool that answers like the real tables, and counts what it was asked. */
function fakePool() {
  const log = [];
  const row = { outing_id: OUTING, outing_status: 'active', owner_id: 'o', join_locked: false, open_links: true, role: 'member', status: 'active', sharing: true, co_leader: false, invited_name: null, hidden_at: null };
  return {
    log,
    async query(text) {
      const s = String(text);
      log.push(s.replace(/\s+/g, ' ').trim().slice(0, 40));
      if (/INSERT INTO sary.member_positions/.test(s)) return { rows: [{ user_id: 'u1' }] };
      if (/FROM sary.outings o\s+LEFT JOIN/.test(s)) return { rows: [row] };
      return { rows: [] };
    },
    async connect() { throw new Error('no tx here'); },
  };
}

test('recordPosition sends the updated_at touch at most once per 5 minutes per outing, not with every persisted fix', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const pool = fakePool();
  const service = createOutingsService({ pool, now: () => t, config: { minFixIntervalMs: 0, persistEveryMs: 0 } });
  const user = { id: 'u1', display_name: 'x' };
  for (let i = 0; i < 8; i++) {
    t += 10_000;
    const r = await service.recordPosition(user, OUTING, { lat: 24.7 + i * 1e-4, lng: 46.7, accuracy: 5, age_ms: 0 });
    assert.equal(r.ok, true, JSON.stringify(r));
  }
  const touches = () => pool.log.filter((l) => l.startsWith('UPDATE sary.outings')).length;
  const inserts = pool.log.filter((l) => l.startsWith('INSERT INTO sary.member_p')).length;
  assert.equal(inserts, 8, 'every fix is still persisted (persistEveryMs 0)');
  assert.equal(touches(), 1, 'the updated_at touch ran once, not eight times');
  t += 6 * 60_000;
  await service.recordPosition(user, OUTING, { lat: 24.8, lng: 46.7, accuracy: 5, age_ms: 0 });
  assert.equal(touches(), 2, 'and again after 5 minutes');
});

test('membership cache entries made together do not all expire on the same instant', async () => {
  let t = 1_000_000;
  const pool = fakePool();
  const service = createOutingsService({ pool, now: () => t });
  const users = Array.from({ length: 60 }, (_, i) => `u${i}`);
  for (const u of users) await service.membership(OUTING, u);
  const queries = () => pool.log.filter((l) => l.startsWith('SELECT o.id')).length;
  assert.equal(queries(), 60);
  /* 9.5 s later (TTL 15 s, entries live 9–15 s): some have expired, some not. */
  t += 9_500;
  for (const u of users) await service.membership(OUTING, u);
  const refreshed = queries() - 60;
  assert.ok(refreshed > 0 && refreshed < 60, `expiries are spread out: ${refreshed} of 60 refreshed`);
  /* After the full TTL every entry has expired. */
  t += 6_000;
  const before = queries();
  for (const u of users) await service.membership(OUTING, u);
  assert.ok(queries() - before >= 1);
});

test('presence sweep judges outings a few at a time, not one by one, and yields between batches', async () => {
  let live = 0;
  let peak = 0;
  const ids = Array.from({ length: 9 }, (_, i) => `47ba65dc-0000-4000-8000-00000000010${i}`);
  const pool = {
    async query(text) {
      const s = String(text);
      if (/FROM sary.outings o\s+LEFT JOIN/.test(s)) {
        live += 1;
        peak = Math.max(peak, live);
        await sleep(5);
        live -= 1;
        return { rows: [{ outing_id: ids[0], outing_status: 'ended', status: null }] };
      }
      return { rows: [] };
    },
    async connect() { throw new Error('no tx'); },
  };
  const hub = { roomIds: () => ids, emit() {}, kick() {}, closeRoom() {}, onlineUsers: () => new Set(), awayUsers: () => new Set(), linkState: () => new Map() };
  const service = createOutingsService({ pool, events: hub, config: { sweepConcurrency: 3 } });
  await service.sweepPresence();
  assert.ok(peak >= 2 && peak <= 3, `peak concurrency ${peak}`);
});

test('per-address limits: defaults leave room for a shared carrier address, and the environment tunes them', async () => {
  const mk = () => {
    const service = { authenticate: async () => null, createUser: async () => ({ user: { id: 'u' }, token: 't' }) };
    const app = express();
    app.use('/api/outings', createOutingsRouter({ service, hub: createHub(), push: {}, apns: {} }));
    return app;
  };
  async function hits(app, n) {
    const server = http.createServer(app);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const codes = [];
    for (let i = 0; i < n; i++) {
      const res = await fetch(`http://127.0.0.1:${server.address().port}/api/outings/me`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ display_name: 'x' }) });
      codes.push(res.status);
    }
    await new Promise((r) => server.close(r));
    return codes;
  }
  const prev = process.env.OUTING_LIMIT_IDENTITY_PER_HOUR;
  try {
    delete process.env.OUTING_LIMIT_IDENTITY_PER_HOUR;
    const dflt = await hits(mk(), 61);
    assert.equal(dflt.filter((c) => c === 201).length, 60, 'sixty new people an hour per address by default (was ten)');
    assert.equal(dflt[60], 429);
    process.env.OUTING_LIMIT_IDENTITY_PER_HOUR = '3';
    const tuned = await hits(mk(), 5);
    assert.deepEqual(tuned, [201, 201, 201, 429, 429]);
  } finally {
    if (prev === undefined) delete process.env.OUTING_LIMIT_IDENTITY_PER_HOUR;
    else process.env.OUTING_LIMIT_IDENTITY_PER_HOUR = prev;
  }
});

test('periodic position writes of many members go out as one batch, the first fix of a member still at once', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const pool = fakePool();
  const service = createOutingsService({ pool, now: () => t, config: { minFixIntervalMs: 0, persistEveryMs: 10_000, persistFlushMs: 60_000 } });
  const users = ['ua', 'ub', 'uc'].map((id) => ({ id, display_name: id }));
  const inserts = () => pool.log.filter((l) => l.startsWith('INSERT INTO sary.member_p')).length;
  for (const u of users) assert.equal((await service.recordPosition(u, OUTING, { lat: 24.7, lng: 46.7, accuracy: 5, age_ms: 0 })).ok, true);
  assert.equal(inserts(), 3, 'a first fix is written at once (it checks the member against the database)');
  t += 12_000;
  for (const u of users) assert.equal((await service.recordPosition(u, OUTING, { lat: 24.71, lng: 46.7, accuracy: 5, age_ms: 0 })).ok, true);
  assert.equal(inserts(), 3, 'the next ones are only queued');
  const written = await service.flushPositions();
  assert.equal(inserts(), 4, 'three members, one statement');
  assert.equal(written, 1, 'the fake answers one row per statement');
  assert.equal(await service.flushPositions(), 0, 'nothing waits afterwards');
});
