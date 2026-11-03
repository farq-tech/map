'use strict';

/**
 * End-to-end over a real Postgres, the real router and real WebSockets.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… npm test -w @farq/map-api
 *
 * Skipped without that variable. It DROPS the `sary` schema of the database it
 * is pointed at, so it refuses anything that does not look like a test DB.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { createPool, migrate } = require('./outings/db');
const { setupOutings } = require('./outings');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const RIYADH = { lat: 24.7136, lng: 46.6753 };

function step(p, i) {
  /* ~110 m north-east per step: real movement, not jitter. */
  return { lat: p.lat + 0.001 * i, lng: p.lng + 0.001 * i, accuracy: 8, heading: 45, speed: 14, age_ms: 300 };
}

test('shared outings — full lifecycle', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(URL_);
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  const applied = await migrate(pool);
  assert.deepEqual(applied, ['001_sary_outings.sql']);
  assert.deepEqual(await migrate(pool), [], 'migrations are idempotent');

  const outings = setupOutings({
    pool,
    autoMigrate: false,
    config: { minFixIntervalMs: 0, persistEveryMs: 0 },
  });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  outings.attach(server);
  const base = `http://127.0.0.1:${server.address().port}`;
  const wsUrl = `ws://127.0.0.1:${server.address().port}/api/outings/live`;
  t.after(async () => {
    outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });

  async function api(method, path, token, body) {
    const res = await fetch(`${base}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const json = await res.json().catch(() => null);
    return { status: res.status, body: json };
  }

  function live(token, outingId) {
    const ws = new WebSocket(wsUrl);
    const inbox = [];
    const waiters = [];
    ws.on('message', (d) => {
      const msg = JSON.parse(String(d));
      inbox.push(msg);
      for (const w of [...waiters]) if (w.pred(msg)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(msg); }
    });
    const closed = new Promise((r) => ws.on('close', (code, reason) => r({ code, reason: String(reason) })));
    const next = (pred, ms = 4000) => {
      const hit = inbox.find(pred);
      if (hit) { inbox.splice(inbox.indexOf(hit), 1); return Promise.resolve(hit); }
      return new Promise((resolve, reject) => {
        const w = { pred, resolve: (m) => { clearTimeout(timer); inbox.splice(inbox.indexOf(m), 1); resolve(m); } };
        const timer = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); reject(new Error('timeout waiting for message')); }, ms);
        waiters.push(w);
      });
    };
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    return { ws, next, closed, opened, inbox, send: (m) => ws.send(JSON.stringify(m)) };
  }

  /* --- identities --- */
  const a = await api('POST', '/me', null, { display_name: 'أبو فهد' });
  const b = await api('POST', '/me', null, { display_name: 'خويي سعد' });
  const c = await api('POST', '/me', null, { display_name: 'غريب' });
  assert.equal(a.status, 201);
  const A = a.body.token, B = b.body.token, C = c.body.token;
  const aId = a.body.user.id, bId = b.body.user.id, cId = c.body.user.id;
  assert.equal((await api('GET', '/me', 'x'.repeat(43))).status, 401, 'unknown token is refused');
  assert.equal((await api('GET', '/', null)).status, 401, 'no token is refused');

  /* --- create + invite --- */
  const created = await api('POST', '/', A, { name: 'طلعة الثمامة' });
  assert.equal(created.status, 201);
  const outingId = created.body.outing_id;
  const invite = created.body.invite.token;
  assert.match(invite, /^[A-Za-z0-9_-]{43}$/);

  const preview = await api('POST', '/invites/preview', null, { token: invite });
  assert.equal(preview.body.invite.name, 'طلعة الثمامة');
  assert.equal(preview.body.invite.owner_name, 'أبو فهد');
  assert.equal(preview.body.invite.member_count, 1);
  assert.equal((await api('POST', '/invites/preview', null, { token: 'A'.repeat(43) })).status, 404, 'guessed token');

  /* --- outsiders see nothing --- */
  assert.equal((await api('GET', `/${outingId}`, C)).status, 404, 'non-member cannot read the outing');
  assert.equal((await api('GET', `/${outingId}/live`, C)).status, 404, 'non-member cannot poll');
  assert.equal((await api('POST', `/${outingId}/positions`, C, { fix: step(RIYADH, 0) })).status, 404);

  /* --- join (twice is idempotent) --- */
  const j1 = await api('POST', '/invites/join', B, { token: invite });
  assert.deepEqual([j1.status, j1.body.already], [200, false]);
  const j2 = await api('POST', '/invites/join', B, { token: invite });
  assert.deepEqual([j2.status, j2.body.already], [200, true]);
  const snap = await api('GET', `/${outingId}`, B);
  assert.equal(snap.body.members.length, 2);
  assert.equal(snap.body.me.role, 'member');
  assert.equal(snap.body.invite, null, 'members do not see invite state');

  /* --- only the owner drives the outing --- */
  assert.equal((await api('POST', `/${outingId}/status`, B, { action: 'start' })).status, 403);
  /* Before start, positions are refused. */
  assert.equal((await api('POST', `/${outingId}/positions`, A, { fix: step(RIYADH, 0) })).body.error, 'outing_created');
  assert.equal((await api('POST', `/${outingId}/status`, A, { action: 'start' })).body.outing.status, 'active');
  assert.equal((await api('POST', `/${outingId}/status`, A, { action: 'start' })).status, 409, 'cannot start twice');

  /* --- device to device over WebSockets --- */
  const la = live(A, outingId);
  const lb = live(B, outingId);
  await Promise.all([la.opened, lb.opened]);
  const ra = await la.next((m) => m.type === 'ready');
  await lb.next((m) => m.type === 'ready');
  assert.equal(ra.snapshot.outing.status, 'active');

  for (let i = 1; i <= 3; i += 1) {
    la.send({ type: 'position', id: i, fix: step(RIYADH, i) });
    const ack = await la.next((m) => m.type === 'ack' && m.id === i);
    assert.equal(ack.ok, true, `fix ${i} accepted`);
    const got = await lb.next((m) => m.type === 'position');
    assert.equal(got.position.user_id, aId);
    assert.equal(got.position.lat, Math.round((RIYADH.lat + 0.001 * i) * 1e6) / 1e6, 'B sees A move');
    assert.equal(got.position.heading, 45);
  }
  assert.equal(la.inbox.filter((m) => m.type === 'position').length, 0, 'own position is not echoed');

  /* An old fix arriving late must not move the marker backwards. */
  la.send({ type: 'position', id: 'late', fix: { ...step(RIYADH, 1), age_ms: 50_000 } });
  assert.equal((await la.next((m) => m.id === 'late')).reason, 'out_of_order');
  la.send({ type: 'position', id: 'bad', fix: { lat: 'x', lng: 1 } });
  assert.equal((await la.next((m) => m.id === 'bad')).reason, 'invalid_coordinates');

  /* B moves too, via the HTTP fallback; A hears it on the socket. */
  assert.equal((await api('POST', `/${outingId}/positions`, B, { fix: step(RIYADH, -2) })).status, 200);
  assert.equal((await la.next((m) => m.type === 'position')).position.user_id, bId);

  /* An outsider cannot join a room by socket. */
  const lc = live(C, outingId);
  await lc.opened;
  assert.equal((await lc.closed).code, 4404);

  /* --- reconnect: the snapshot restores the last known positions --- */
  lb.ws.terminate();
  await lb.closed;
  const lb2 = live(B, outingId);
  await lb2.opened;
  const r2 = await lb2.next((m) => m.type === 'ready');
  const aPos = r2.snapshot.positions.find((p) => p.user_id === aId);
  assert.ok(aPos, 'last known position survives a reconnect');
  assert.ok(aPos.received_at && aPos.recorded_at);

  /* --- pause / resume sharing --- */
  assert.equal((await api('PATCH', `/${outingId}/me`, A, { sharing: false })).body.sharing, false);
  assert.equal((await lb2.next((m) => m.type === 'member_sharing')).sharing, false);
  la.send({ type: 'position', id: 'off', fix: step(RIYADH, 9) });
  assert.equal((await la.next((m) => m.id === 'off')).reason, 'sharing_off');
  let s = await api('GET', `/${outingId}`, B);
  assert.equal(s.body.positions.find((p) => p.user_id === aId), undefined, 'paused member position is deleted, not hidden');
  const stored = await pool.query('SELECT count(*)::int AS n FROM sary.member_positions WHERE user_id = $1', [aId]);
  assert.equal(stored.rows[0].n, 0);
  await api('PATCH', `/${outingId}/me`, A, { sharing: true });
  la.send({ type: 'position', id: 'on', fix: step(RIYADH, 10) });
  assert.equal((await la.next((m) => m.id === 'on')).ok, true);

  /* --- owner pauses the whole outing --- */
  await api('POST', `/${outingId}/status`, A, { action: 'pause' });
  assert.equal((await lb2.next((m) => m.type === 'outing_status')).status, 'paused');
  s = await api('GET', `/${outingId}`, B);
  assert.equal(s.body.positions.length, 0, 'no positions while paused');
  await api('POST', `/${outingId}/status`, A, { action: 'resume' });

  /* --- revoke + rotate invites --- */
  await api('DELETE', `/${outingId}/invites`, A);
  assert.equal((await api('POST', '/invites/join', C, { token: invite })).body.error, 'invite_revoked');
  const rotated = await api('POST', `/${outingId}/invites`, A, { ttl_hours: 1 });
  const invite2 = rotated.body.invite.token;
  assert.equal((await api('POST', '/invites/join', C, { token: invite2 })).status, 200);

  /* --- expired invite --- */
  await pool.query(`UPDATE sary.outing_invites SET expires_at = now() - interval '1 minute' WHERE revoked_at IS NULL`);
  assert.equal((await api('POST', '/invites/preview', null, { token: invite2 })).body.error, 'invite_expired');

  /* --- removal: kicked at once, cannot rejoin --- */
  const lc2 = live(C, outingId);
  await lc2.opened;
  await lc2.next((m) => m.type === 'ready');
  assert.equal((await api('DELETE', `/${outingId}/members/${cId}`, B)).status, 403, 'members cannot remove');
  await api('DELETE', `/${outingId}/members/${cId}`, A);
  assert.equal((await lc2.closed).code, 4403);
  assert.equal((await api('GET', `/${outingId}/live`, C)).status, 404, 'removed member loses access');
  const fresh = await api('POST', `/${outingId}/invites`, A, {});
  assert.equal((await api('POST', '/invites/join', C, { token: fresh.body.invite.token })).body.error, 'removed_from_outing');

  /* --- owner leaves: ownership moves to B --- */
  const left = await api('POST', `/${outingId}/leave`, A);
  assert.equal(left.body.owner, bId);
  assert.equal((await la.closed).code, 4403);
  assert.equal((await lb2.next((m) => m.type === 'owner_changed')).owner_id, bId);
  assert.equal((await api('GET', `/${outingId}`, A)).status, 404, 'left member loses access');

  /* --- end: everything is closed and positions are gone --- */
  await api('POST', `/${outingId}/positions`, B, { fix: step(RIYADH, 20) });
  const ended = await api('POST', `/${outingId}/status`, B, { action: 'end' });
  assert.equal(ended.body.outing.status, 'ended');
  assert.equal((await lb2.closed).code, 4410);
  const leftover = await pool.query('SELECT count(*)::int AS n FROM sary.member_positions WHERE outing_id = $1', [outingId]);
  assert.equal(leftover.rows[0].n, 0, 'ending deletes every stored position');
  assert.equal((await api('POST', '/invites/preview', null, { token: fresh.body.invite.token })).body.error, 'invite_revoked');

  const history = await api('GET', '/', B);
  assert.equal(history.body.current.length, 0);
  assert.equal(history.body.history[0].name, 'طلعة الثمامة');
});

test('twenty members in one outing, two outings isolated', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(URL_);
  await migrate(pool);
  const outings = setupOutings({ pool, autoMigrate: false, limits: { identityPerHour: 100, invitePer10Min: 100 }, config: { minFixIntervalMs: 0, persistEveryMs: 5_000 } });
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
  const call = async (method, path, token, body) => {
    const res = await fetch(`http://127.0.0.1:${port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return res.json();
  };

  const people = [];
  for (let i = 0; i < 20; i += 1) people.push(await call('POST', '/me', null, { display_name: `مشارك ${i + 1}` }));
  const owner = people[0];
  const o1 = await call('POST', '/', owner.token, { name: 'كبيرة' });
  for (const p of people.slice(1)) await call('POST', '/invites/join', p.token, { token: o1.invite.token });
  await call('POST', `/${o1.outing_id}/status`, owner.token, { action: 'start' });

  const other = await call('POST', '/me', null, { display_name: 'طلعة ثانية' });
  const o2 = await call('POST', '/', other.token, { name: 'منفصلة' });
  await call('POST', `/${o2.outing_id}/status`, other.token, { action: 'start' });

  const sockets = people.map((p) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    const got = [];
    ws.on('message', (d) => got.push(JSON.parse(String(d))));
    const ready = new Promise((r) => ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'auth', token: p.token, outing_id: o1.outing_id }));
      r();
    }));
    return { ws, got, ready, id: p.user.id };
  });
  const spy = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
  const spyGot = [];
  spy.on('message', (d) => spyGot.push(JSON.parse(String(d))));
  await new Promise((r) => spy.on('open', r));
  spy.send(JSON.stringify({ type: 'auth', token: other.token, outing_id: o2.outing_id }));
  await Promise.all(sockets.map((s) => s.ready));
  const until = async (pred, ms = 8000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (pred()) return;
      await new Promise((r) => setTimeout(r, 25));
    }
    throw new Error('timeout');
  };
  await until(() => sockets.every((s) => s.got.some((m) => m.type === 'ready')) && spyGot.some((m) => m.type === 'ready'));

  const started = Date.now();
  sockets.forEach((s, i) => s.ws.send(JSON.stringify({ type: 'position', id: 1, fix: step(RIYADH, i) })));
  await until(() => sockets.every((s) => s.got.filter((m) => m.type === 'position').length === 19));
  const fanoutMs = Date.now() - started;
  assert.ok(fanoutMs < 5000, `20×19 deliveries took ${fanoutMs} ms`);
  assert.equal(spyGot.filter((m) => m.type === 'position').length, 0, 'another outing receives nothing');
  const snap = await call('GET', `/${o1.outing_id}`, people[5].token);
  assert.equal(snap.members.length, 20);
  assert.equal(snap.positions.length, 20);
  for (const s of sockets) s.ws.close();
  spy.close();
});
