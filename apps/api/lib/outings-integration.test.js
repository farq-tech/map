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
  assert.deepEqual(applied, ['001_sary_outings.sql', '002_sary_member_phone.sql', '003_sary_field_diagnostics.sql', '004_sary_accounts.sql', '005_sary_trip_summary.sql', '006_sary_push_subscriptions.sql', '007_sary_safety.sql', '008_sary_apns_tokens.sql']);
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

  /* Connection heartbeat is separate from fixes: no coordinates, just "still here" + GPS state. */
  la.send({ type: 'heartbeat', gps: 'weak' });
  const link = await lb.next((m) => m.type === 'member_link');
  assert.deepEqual([link.user_id, link.gps], [aId, 'weak']);
  assert.equal('lat' in link, false);
  const withLink = await api('GET', `/${outingId}`, B);
  const aMember = withLink.body.members.find((m) => m.user_id === aId);
  assert.ok(aMember.last_seen_at, 'snapshot says when we last heard each member');
  assert.equal(aMember.gps, 'weak');

  /* An optional phone, seen by fellow members only. */
  assert.equal((await api('PATCH', '/me', B, { phone: '0551234567' })).body.user.phone, '+966551234567');
  const ph = await api('GET', `/${outingId}`, A);
  assert.equal(ph.body.members.find((m) => m.user_id === bId).phone, '+966551234567');
  assert.equal((await api('PATCH', '/me', B, { phone: 'nope' })).status, 400);

  /* A note over A's car: B hears it live, it is in the snapshot, and it can be cleared. */
  la.send({ type: 'note', id: 'n1', text: '  بوقف عند\u202e المحطة  ' });
  const nack = await la.next((m) => m.type === 'note_ack' && m.id === 'n1');
  assert.equal(nack.ok, true);
  assert.equal(nack.note.text, 'بوقف عند المحطة', 'cleaned: trimmed, no bidi override');
  const heard = await lb.next((m) => m.type === 'member_note');
  assert.deepEqual([heard.user_id, heard.note.text], [aId, 'بوقف عند المحطة']);
  assert.equal((await api('GET', `/${outingId}`, B)).body.members.find((m) => m.user_id === aId).note.text, 'بوقف عند المحطة');
  la.send({ type: 'note', id: 'n2', text: 'again' });
  assert.equal((await la.next((m) => m.id === 'n2')).reason, 'too_frequent');
  await new Promise((r) => setTimeout(r, 2_100));
  assert.equal((await api('POST', `/${outingId}/note`, A, { text: '' })).status, 200);
  assert.equal((await lb.next((m) => m.type === 'member_note')).note, null, 'cleared');
  assert.equal((await api('POST', `/${outingId}/note`, C, { text: 'hi' })).status, 404, 'outsider cannot post');

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

  /* --- field-test diagnostics: members of the (ended) outing only, numbers only --- */
  const sample = JSON.parse(require('fs').readFileSync(require('path').join(__dirname, '../../../docs/field-test/sample-diagnostics.json'), 'utf8'));
  const dirty = { ...sample, lat: 24.7, display_name: 'خويي سعد', token: B, app: { ...sample.app, platform: 'android' } };
  assert.equal((await api('POST', `/${outingId}/diagnostics`, B, { report: dirty })).status, 201);
  assert.equal((await api('POST', `/${outingId}/diagnostics`, A, { report: sample })).status, 404, 'a member who left cannot send');
  assert.equal((await api('POST', `/${outingId}/diagnostics`, C, { report: sample })).status, 404, 'a stranger cannot send');
  assert.equal((await api('POST', `/${outingId}/diagnostics`, B, { report: { schema: 'x' } })).body.error, 'unsupported_schema');
  const diagRows = await pool.query('SELECT * FROM sary.field_diagnostics');
  assert.equal(diagRows.rows.length, 1);
  const row = diagRows.rows[0];
  assert.deepEqual(Object.keys(row).sort(), ['browser', 'id', 'outing_ref', 'platform', 'received_at', 'report']);
  const storedRow = JSON.stringify(row);
  for (const secret of [outingId, bId, B, 'خويي', '24.7']) assert.ok(!storedRow.includes(secret), `stored row leaks ${secret}`);
  assert.equal(row.report.sends.attempts, sample.sends.attempts);
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

test('outing safety — SOS, battery, rally point', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(URL_);
  await migrate(pool);
  const outings = setupOutings({ pool, autoMigrate: false, limits: { identityPerHour: 100, invitePer10Min: 100 }, config: { minFixIntervalMs: 0, persistEveryMs: 0 } });
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

  async function api(method, path, token, body) {
    const res = await fetch(`http://127.0.0.1:${port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  }

  function live(token, outingId) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    const inbox = [];
    const waiters = [];
    ws.on('message', (d) => {
      const msg = JSON.parse(String(d));
      inbox.push(msg);
      for (const w of [...waiters]) if (w.pred(msg)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(msg); }
    });
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
    return { ws, next, opened, inbox, send: (m) => ws.send(JSON.stringify(m)) };
  }

  const a = (await api('POST', '/me', null, { display_name: 'أبو فهد' })).body;
  const b = (await api('POST', '/me', null, { display_name: 'سعد' })).body;
  const c = (await api('POST', '/me', null, { display_name: 'غريب' })).body;
  const created = (await api('POST', '/', a.token, { name: 'طلعة الأمان' })).body;
  const id = created.outing_id;
  await api('POST', '/invites/join', b.token, { token: created.invite.token });
  await api('POST', `/${id}/status`, a.token, { action: 'start' });

  const la = live(a.token, id);
  const lb = live(b.token, id);
  await Promise.all([la.opened, lb.opened]);
  const ready = await la.next((m) => m.type === 'ready');
  await lb.next((m) => m.type === 'ready');
  assert.equal(ready.snapshot.outing.rally, null, 'no rally point to begin with');

  /* --- battery rides the heartbeat; nothing is invented when a phone cannot tell --- */
  lb.send({ type: 'heartbeat', gps: 'ok', battery: { level: 0.12, charging: false } });
  const link = await la.next((m) => m.type === 'member_link' && m.user_id === b.user.id);
  assert.deepEqual([link.battery.level, link.battery.charging], [0.12, false]);
  assert.ok(link.battery.at);
  let snap = (await api('GET', `/${id}`, a.token)).body;
  assert.equal(snap.members.find((m) => m.user_id === b.user.id).battery.level, 0.12, 'battery in the snapshot');
  assert.equal(snap.members.find((m) => m.user_id === a.user.id).battery, null, 'never guessed for a phone that sent none');
  assert.equal((await api('POST', `/${id}/heartbeat`, a.token, { gps: 'ok', battery: { level: 7, charging: true } })).status, 200);
  assert.equal((await lb.next((m) => m.type === 'member_link' && m.user_id === a.user.id)).battery, null, 'out-of-range reading is dropped');

  /* --- SOS --- */
  assert.equal((await api('POST', `/${id}/sos`, c.token, { fix: null })).status, 404, 'outsider cannot raise an SOS');
  assert.equal((await api('POST', `/${id}/sos`, b.token, { fix: { lat: RIYADH.lat, lng: RIYADH.lng, accuracy: 12, age_ms: 40 * 60_000 } })).body.error, 'sos_fix_stale');
  const raised = await api('POST', `/${id}/sos`, b.token, { fix: { lat: RIYADH.lat, lng: RIYADH.lng, accuracy: 12, age_ms: 90_000 } });
  assert.equal(raised.status, 200);
  const heard = await la.next((m) => m.type === 'sos');
  assert.equal(heard.user_id, b.user.id);
  assert.equal(heard.sos.fix.lat, RIYADH.lat);
  const fixAge = Date.now() - new Date(heard.sos.fix.recorded_at).getTime();
  assert.ok(fixAge >= 89_000 && fixAge < 100_000, 'the fix keeps its own (older) time');
  assert.equal((await api('POST', `/${id}/sos`, b.token, {})).body.error, 'too_frequent', 'rate limited');

  /* A late joiner and a reconnect both see it in the snapshot. */
  const rotated = (await api('POST', `/${id}/invites`, a.token, {})).body.invite.token;
  await api('POST', '/invites/join', c.token, { token: rotated });
  const lc = live(c.token, id);
  await lc.opened;
  const cReady = await lc.next((m) => m.type === 'ready');
  const bInSnap = cReady.snapshot.members.find((m) => m.user_id === b.user.id);
  assert.equal(bInSnap.sos.fix.lng, RIYADH.lng, 'late joiner sees the active SOS');

  /* «أنا بخير» clears it for everyone. */
  assert.equal((await api('DELETE', `/${id}/sos`, b.token)).status, 200);
  assert.equal((await la.next((m) => m.type === 'sos')).sos, null);
  assert.equal((await lc.next((m) => m.type === 'sos')).sos, null);
  snap = (await api('GET', `/${id}`, c.token)).body;
  assert.equal(snap.members.find((m) => m.user_id === b.user.id).sos, null);

  /* With no GPS at all you can still call for help. */
  await new Promise((r) => setTimeout(r, 3_100));
  assert.equal((await api('POST', `/${id}/sos`, b.token, { fix: null })).body.sos.fix, null);
  assert.equal((await la.next((m) => m.type === 'sos')).sos.fix, null);

  /* --- rally point --- */
  assert.equal((await api('PUT', `/${id}/rally`, b.token, { lat: 24.8, lng: 46.7 })).status, 403, 'members cannot set it');
  assert.equal((await api('PUT', `/${id}/rally`, c.token, { lat: 24.8, lng: 46.7 })).status, 403);
  assert.equal((await api('PUT', `/${id}/rally`, a.token, { lat: 'x', lng: 46.7 })).body.error, 'invalid_rally');
  const set = await api('PUT', `/${id}/rally`, a.token, { lat: 24.8, lng: 46.7, label: 'عند الطلح' });
  assert.equal(set.status, 200);
  const r1 = await lb.next((m) => m.type === 'rally');
  assert.deepEqual([r1.rally.lat, r1.rally.lng, r1.rally.label, r1.rally.set_by], [24.8, 46.7, 'عند الطلح', a.user.id]);
  await api('PUT', `/${id}/rally`, a.token, { lat: 24.81, lng: 46.71 });
  assert.equal((await lb.next((m) => m.type === 'rally')).rally.lat, 24.81, 'moved');
  assert.equal((await api('GET', `/${id}`, c.token)).body.outing.rally.lng, 46.71, 'rally in the snapshot');
  await api('DELETE', `/${id}/rally`, a.token);
  assert.equal((await lb.next((m) => m.type === 'rally')).rally, null, 'cleared');
  await api('PUT', `/${id}/rally`, a.token, { lat: 24.82, lng: 46.72 });

  /* --- leaving drops my SOS; ending wipes rally and every SOS --- */
  await api('POST', `/${id}/leave`, b.token);
  snap = (await api('GET', `/${id}`, c.token)).body;
  assert.equal(snap.members.some((m) => m.sos), false);
  await api('POST', `/${id}/status`, a.token, { action: 'end' });
  const row = (await pool.query('SELECT rally_lat, rally_lng FROM sary.outings WHERE id = $1', [id])).rows[0];
  assert.deepEqual(row, { rally_lat: null, rally_lng: null }, 'ending deletes the rally point');
  for (const s of [la, lb, lc]) s.ws.close();
});

test('web push: notes and SOS reach members whose screen is off', { skip, timeout: 60_000 }, async (t) => {
  const crypto = require('crypto');
  const pool = createPool(URL_);
  await migrate(pool);
  /* A fake push service: records what would be sent, answers 410 for "gone" endpoints. */
  const inbox = [];
  const sender = {
    async send(sub, body, opts) {
      if (sub.endpoint.includes('/gone')) throw Object.assign(new Error('gone'), { statusCode: 410 });
      inbox.push({ endpoint: sub.endpoint, keys: sub.keys, payload: JSON.parse(body), opts });
      return { statusCode: 201 };
    },
  };
  const outings = setupOutings({
    pool,
    autoMigrate: false,
    limits: { identityPerHour: 100, invitePer10Min: 100 },
    push: { config: { enabled: true, publicKey: 'BTestPublicKey', privateKey: 'unused-by-fake' }, sender, maxPerUser: 2 },
  });
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
  const api = async (method, path, token, body) => {
    const res = await fetch(`http://127.0.0.1:${port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const keys = () => {
    const ecdh = crypto.createECDH('prime256v1');
    ecdh.generateKeys();
    return { p256dh: ecdh.getPublicKey().toString('base64url'), auth: crypto.randomBytes(16).toString('base64url') };
  };
  const sub = (name) => ({ endpoint: `https://fcm.googleapis.com/fcm/send/${name}-${crypto.randomUUID()}`, keys: keys() });
  const until = async (pred, ms = 5000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const v = pred();
      if (v) return v;
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error('timeout');
  };
  const settle = () => new Promise((r) => setTimeout(r, 300));
  const gap = () => new Promise((r) => setTimeout(r, 2_100)); // one note per 2 s per person

  const cfg = await api('GET', '/push/config');
  assert.deepEqual(cfg.body, { ok: true, enabled: true, public_key: 'BTestPublicKey' });

  const A = (await api('POST', '/me', null, { display_name: 'أبو فهد' })).body;
  const B = (await api('POST', '/me', null, { display_name: 'سعد' })).body;
  const C = (await api('POST', '/me', null, { display_name: 'غريب' })).body;

  /* --- subscribe: auth, validation, cap per person --- */
  assert.equal((await api('POST', '/push/subscribe', null, { subscription: sub('x') })).status, 401);
  assert.equal((await api('POST', '/push/subscribe', B.token, { subscription: { endpoint: 'https://evil.example.com/x', keys: keys() } })).status, 400);
  assert.equal((await api('POST', '/push/subscribe', B.token, { subscription: { endpoint: 'https://fcm.googleapis.com/x', keys: { p256dh: 'AA', auth: 'BB' } } })).status, 400);
  const b1 = sub('b-old'), b2 = sub('gone'), b3 = sub('b-new');
  for (const s of [b1, b2, b3]) {
    assert.equal((await api('POST', '/push/subscribe', B.token, { subscription: s })).status, 201);
    await new Promise((r) => setTimeout(r, 15));
  }
  const bRows = (await pool.query('SELECT endpoint FROM sary.push_subscriptions WHERE user_id = $1', [B.user.id])).rows.map((r) => r.endpoint).sort();
  assert.deepEqual(bRows, [b2.endpoint, b3.endpoint].sort(), 'capped at 2 per person, oldest dropped');
  assert.equal((await api('POST', '/push/subscribe', B.token, { subscription: b3 })).status, 201, 'resubscribing is idempotent');
  const a1 = sub('a');
  assert.equal((await api('POST', '/push/subscribe', A.token, { subscription: a1 })).status, 201);
  const c1 = sub('c');
  assert.equal((await api('POST', '/push/subscribe', C.token, { subscription: c1 })).status, 201);

  /* --- an outing with A and B; C is an outsider --- */
  const o = (await api('POST', '/', A.token, { name: 'طلعة النفود' })).body;
  assert.equal((await api('POST', '/invites/join', B.token, { token: o.invite.token })).status, 200);
  assert.equal((await api('POST', `/${o.outing_id}/status`, A.token, { action: 'start' })).status, 200);

  /* A note from A → B's phones, never A's own, never the outsider's. A 410 deletes that subscription. */
  assert.equal((await api('POST', `/${o.outing_id}/note`, A.token, { text: 'بوقف عند المحطة' })).status, 200);
  const first = await until(() => inbox.find((m) => m.endpoint === b3.endpoint));
  await settle();
  assert.deepEqual(inbox.map((m) => m.endpoint), [b3.endpoint]);
  assert.equal(first.payload.type, 'note');
  assert.equal(first.payload.body, 'بوقف عند المحطة');
  assert.equal(first.payload.title, 'أبو فهد · طلعة النفود');
  assert.equal(first.payload.url, `/outings/${o.outing_id}`);
  assert.deepEqual(first.keys, b3.keys);
  const gone = await pool.query('SELECT 1 FROM sary.push_subscriptions WHERE endpoint = $1', [b2.endpoint]);
  assert.equal(gone.rowCount, 0, '410 Gone → subscription deleted');
  await gap();
  assert.equal((await api('POST', `/${o.outing_id}/note`, A.token, { text: '' })).status, 200);
  await settle();
  assert.equal(inbox.length, 1, 'clearing a note pushes nothing');

  /* B has the outing on screen (socket, not away) → no push for a note; away → push again. */
  const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
  const got = [];
  ws.on('message', (d) => got.push(JSON.parse(String(d))));
  await new Promise((r) => ws.on('open', r));
  ws.send(JSON.stringify({ type: 'auth', token: B.token, outing_id: o.outing_id }));
  await until(() => got.some((m) => m.type === 'ready'));
  await gap();
  inbox.length = 0;
  assert.equal((await api('POST', `/${o.outing_id}/note`, A.token, { text: 'وين صرتوا؟' })).status, 200);
  await until(() => got.some((m) => m.type === 'member_note' && m.note?.text === 'وين صرتوا؟'));
  await settle();
  assert.equal(inbox.length, 0, 'a member looking at the outing gets the in-app alert, not a push');
  ws.send(JSON.stringify({ type: 'presence', away: true }));
  await settle();
  await gap();
  assert.equal((await api('POST', `/${o.outing_id}/note`, A.token, { text: 'ردّوا' })).status, 200);
  await until(() => inbox.length === 1);

  /* SOS (any emitter of an `sos` event) is pushed with high urgency, even to someone watching. */
  ws.send(JSON.stringify({ type: 'presence', away: false }));
  await settle();
  inbox.length = 0;
  outings.hub.emit(o.outing_id, { type: 'sos', user_id: A.user.id, text: 'علقنا في الرمل' });
  const sos = await until(() => inbox.find((m) => m.payload.type === 'sos'));
  assert.equal(sos.endpoint, b3.endpoint);
  assert.equal(sos.opts.urgency, 'high');
  assert.match(sos.payload.title, /أبو فهد/);
  assert.equal(sos.payload.body, 'علقنا في الرمل');
  await settle();
  assert.equal(inbox.length, 1, 'the sender is not pushed about their own SOS');

  /* The real SOS route (#24) emits the shape that is auto-pushed: raise → alarm,
   * refresh → no second alarm, «أنا بخير» → a quiet replacement with the same tag. */
  inbox.length = 0;
  assert.equal((await api('POST', `/${o.outing_id}/sos`, A.token, { fix: null })).status, 200);
  const real = await until(() => inbox.find((m) => m.payload.type === 'sos'));
  assert.equal(real.endpoint, b3.endpoint);
  assert.equal(real.opts.urgency, 'high');
  await new Promise((r) => setTimeout(r, 3_100));
  assert.equal((await api('POST', `/${o.outing_id}/sos`, A.token, { fix: null })).status, 200);
  await settle();
  assert.equal(inbox.length, 1, 'refreshing an SOS does not ring again');
  assert.equal((await api('DELETE', `/${o.outing_id}/sos`, A.token)).status, 200);
  const clear = await until(() => inbox.find((m) => m.payload.type === 'sos_clear'));
  assert.equal(clear.payload.tag, real.payload.tag);
  assert.equal(clear.opts.urgency, 'normal');
  ws.close();

  /* Leaving stops pushes at once. */
  assert.equal((await api('POST', `/${o.outing_id}/leave`, B.token)).status, 200);
  await gap();
  inbox.length = 0;
  assert.equal((await api('POST', `/${o.outing_id}/note`, A.token, { text: 'باقي أحد؟' })).status, 200);
  await settle();
  assert.equal(inbox.length, 0, 'former members get nothing');

  /* Unsubscribe removes only my own row. */
  assert.deepEqual((await api('DELETE', '/push/subscribe', C.token, { endpoint: a1.endpoint })).body, { ok: true, removed: 0 });
  assert.deepEqual((await api('DELETE', '/push/subscribe', A.token, { endpoint: a1.endpoint })).body, { ok: true, removed: 1 });
});

test('voice clips (memory only) and opt-in trip summaries (totals only)', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(URL_);
  await migrate(pool);
  const outings = setupOutings({ pool, autoMigrate: false, limits: { identityPerHour: 100, invitePer10Min: 100, clipsPer5Min: 5 }, config: { minFixIntervalMs: 0, persistEveryMs: 0 } });
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
  const call = async (method, path, token, body) => {
    const res = await fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const upload = (token, outingId, buf, { type = 'audio/mp4', ms = '3200' } = {}) =>
    fetch(`${base}/${outingId}/clips`, {
      method: 'POST',
      headers: { 'content-type': type, 'x-clip-duration-ms': ms, ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: buf,
    }).then(async (r) => ({ status: r.status, body: await r.json().catch(() => null) }));
  const mp4 = (n = 2000) => Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypM4A '), Buffer.alloc(n, 7)]);

  const a = (await call('POST', '/me', null, { display_name: 'سعد' })).body;
  const b = (await call('POST', '/me', null, { display_name: 'فهد' })).body;
  const c = (await call('POST', '/me', null, { display_name: 'غريب' })).body;
  const o = (await call('POST', '/', a.token, { name: 'طلعة الصوت' })).body;
  await call('POST', '/invites/join', b.token, { token: o.invite.token });
  await call('POST', `/${o.outing_id}/status`, a.token, { action: 'start' });

  const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
  const got = [];
  ws.on('message', (d) => got.push(JSON.parse(String(d))));
  await new Promise((r) => ws.on('open', r));
  ws.send(JSON.stringify({ type: 'auth', token: b.token, outing_id: o.outing_id }));
  const until = async (pred, ms = 5000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const hit = got.find(pred);
      if (hit) return hit;
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error('timeout');
  };
  await until((m) => m.type === 'ready');

  /* --- push-to-talk --- */
  const sent = await upload(a.token, o.outing_id, mp4());
  assert.equal(sent.status, 201);
  assert.equal(sent.body.clip.mime, 'audio/mp4', 'type comes from the bytes');
  const ev = await until((m) => m.type === 'voice_clip');
  assert.equal(ev.clip.user_id, a.user.id);
  assert.equal(ev.clip.duration_ms, 3200);
  assert.ok(new Date(ev.clip.expires_at) - Date.now() <= 10 * 60_000);
  const fetched = await fetch(`http://127.0.0.1:${port}${ev.clip.url}`, { headers: { authorization: `Bearer ${b.token}` } });
  assert.equal(fetched.status, 200);
  assert.equal(fetched.headers.get('content-type'), 'audio/mp4');
  assert.equal(fetched.headers.get('cache-control'), 'no-store');
  assert.equal(Buffer.from(await fetched.arrayBuffer()).length, mp4().length, 'recipient gets the bytes');
  assert.equal((await fetch(`http://127.0.0.1:${port}${ev.clip.url}`, { headers: { authorization: `Bearer ${c.token}` } })).status, 404, 'outsider cannot fetch a clip');
  assert.equal((await fetch(`http://127.0.0.1:${port}${ev.clip.url}`)).status, 401, 'no token, no clip');
  assert.equal((await call('GET', `/${o.outing_id}`, b.token)).body.voice_clips.length, 1, 'polling clients see it in the snapshot');

  assert.equal((await upload(c.token, o.outing_id, mp4())).status, 404, 'outsider cannot post');
  assert.equal((await upload(a.token, o.outing_id, mp4())).body.error, 'too_frequent', 'one clip at a time');
  assert.equal((await upload(a.token, o.outing_id, Buffer.from('<script>x</script>'.repeat(30)), { type: 'audio/mp4' })).status, 415, 'not audio');
  assert.equal((await upload(a.token, o.outing_id, mp4(), { ms: '60000' })).body.error, 'invalid_clip_duration', 'max 15 s');
  assert.equal((await upload(a.token, o.outing_id, mp4(500 * 1024))).status, 413, 'size cap');
  assert.equal((await upload(a.token, o.outing_id, mp4())).status, 429, 'rate limited per person');
  const stored = await pool.query(`SELECT count(*)::int AS n FROM information_schema.columns WHERE table_schema = 'sary' AND data_type = 'bytea' AND column_name NOT IN ('token_hash', 'recovery_hash')`);
  assert.equal(stored.rows[0].n, 0, 'no table can hold audio');

  /* --- summaries: only after the end, only totals, only for members --- */
  const summary = { distance_m: 18_400, duration_s: 2, moving_s: 1 };
  assert.equal((await call('PUT', `/${o.outing_id}/summary`, a.token, { summary })).body.error, 'outing_not_ended');
  await new Promise((r) => setTimeout(r, 1_100));
  await call('POST', `/${o.outing_id}/status`, a.token, { action: 'end' });
  assert.equal((await fetch(`http://127.0.0.1:${port}${ev.clip.url}`, { headers: { authorization: `Bearer ${b.token}` } })).status, 404, 'ending drops clips');
  assert.equal((await call('PUT', `/${o.outing_id}/summary`, a.token, { summary: { distance_m: 18_400, duration_s: 9_999, moving_s: 10 } })).body.error, 'implausible_summary', 'longer than the outing ran');
  assert.equal((await call('PUT', `/${o.outing_id}/summary`, a.token, { summary: { ...summary, points: [[46.6, 24.7]] } })).body.error, 'invalid_summary', 'no points accepted');
  assert.equal((await call('PUT', `/${o.outing_id}/summary`, c.token, { summary })).status, 404, 'outsider cannot share');
  const ok = await call('PUT', `/${o.outing_id}/summary`, a.token, { summary: { distance_m: 400, duration_s: 2, moving_s: 1 } });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.summary.distance_m, 400);
  const cols = (await pool.query(`SELECT column_name FROM information_schema.columns WHERE table_schema = 'sary' AND table_name = 'trip_summaries' ORDER BY 1`)).rows.map((r) => r.column_name);
  assert.deepEqual(cols, ['distance_m', 'duration_s', 'moving_s', 'outing_id', 'shared_at', 'user_id'], 'totals only — no coordinates');

  /* B did not tap «شارك ملخصي»: nothing of theirs exists. */
  const hist = await call('GET', '/', b.token);
  const row = hist.body.history.find((h) => h.id === o.outing_id);
  assert.deepEqual(row.summaries.map((s) => [s.display_name, s.distance_m, s.duration_s]), [['سعد', 400, 2]]);
  assert.equal((await call('GET', '/', c.token)).body.history.length, 0, 'outsiders see no history');
  assert.equal((await call('GET', `/${o.outing_id}`, b.token)).body.summaries.length, 1);

  assert.equal((await call('DELETE', `/${o.outing_id}/summary`, a.token)).body.withdrawn, true);
  assert.equal((await call('GET', '/', b.token)).body.history.find((h) => h.id === o.outing_id).summaries.length, 0, 'withdrawn = deleted');
  ws.close();
});

test('APNs: tokens per identity, same recipients as web push, gone tokens removed', { skip, timeout: 60_000 }, async (t) => {
  const crypto = require('crypto');
  const http2 = require('http2');
  const { apnsConfigFromEnv, createApnsSender } = require('./outings/apns');
  const pool = createPool(URL_);
  await migrate(pool);

  /* A fake APNs (h2c) behind the real HTTP/2 sender; a throwaway P-256 key. */
  const pem = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  const config = apnsConfigFromEnv({ APNS_KEY_ID: 'ABC123DEFG', APNS_TEAM_ID: 'MH7J92HV9N', APNS_PRIVATE_KEY: pem.replace(/\n/g, '\\n'), APNS_BUNDLE_ID: 'sa.sary.albarq' });
  const inbox = [];
  const h2 = http2.createServer();
  h2.on('stream', (stream, headers) => {
    let body = '';
    stream.on('data', (c) => (body += c));
    stream.on('end', () => {
      const token = headers[':path'].split('/').pop();
      inbox.push({ token, headers, payload: JSON.parse(body) });
      if (token.startsWith('dead')) {
        stream.respond({ ':status': 410 });
        stream.end(JSON.stringify({ reason: 'Unregistered' }));
      } else {
        stream.respond({ ':status': 200 });
        stream.end();
      }
    });
  });
  await new Promise((r) => h2.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${h2.address().port}`;
  const sender = createApnsSender(config, { origins: { production: origin, sandbox: origin } });

  const outings = setupOutings({
    pool,
    autoMigrate: false,
    limits: { identityPerHour: 100, invitePer10Min: 100 },
    push: { config: { enabled: false } },
    apns: { config, sender, maxPerUser: 2 },
  });
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
    await new Promise((r) => h2.close(r));
    await pool.end();
  });
  const api = async (method, path, token, body) => {
    const res = await fetch(`http://127.0.0.1:${port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const until = async (pred, ms = 5000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const v = pred();
      if (v) return v;
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error('timeout');
  };
  const settle = () => new Promise((r) => setTimeout(r, 300));
  const hex = () => crypto.randomBytes(32).toString('hex');

  assert.deepEqual((await api('GET', '/push/apns')).body, { ok: true, enabled: true, bundle_id: 'sa.sary.albarq' });
  assert.equal(outings.push.enabled, false, 'web push off: APNs alone still pushes');

  const A = (await api('POST', '/me', null, { display_name: 'أبو فهد' })).body;
  const B = (await api('POST', '/me', null, { display_name: 'سعد' })).body;
  const C = (await api('POST', '/me', null, { display_name: 'غريب' })).body;

  const aTok = hex(), bOld = hex(), bNew = hex(), cTok = hex();
  const dead = 'dead'.padEnd(64, 'd'); // the fake APNs answers 410 Unregistered for this one
  assert.equal((await api('POST', '/push/apns', null, { token: aTok, environment: 'production' })).status, 401);
  assert.equal((await api('POST', '/push/apns', B.token, { token: 'nothex', environment: 'production' })).status, 400);
  assert.equal((await api('POST', '/push/apns', B.token, { token: bOld, environment: 'staging' })).status, 400);
  for (const tok of [bOld, dead, bNew]) {
    assert.equal((await api('POST', '/push/apns', B.token, { token: tok, environment: 'sandbox' })).status, 201);
    await new Promise((r) => setTimeout(r, 15));
  }
  const bRows = (await pool.query('SELECT token FROM sary.apns_tokens WHERE user_id = $1', [B.user.id])).rows.map((r) => r.token).sort();
  assert.deepEqual(bRows, [dead, bNew].sort(), 'capped at 2 per person, oldest dropped');
  assert.equal((await api('POST', '/push/apns', A.token, { token: aTok.toUpperCase(), environment: 'production' })).status, 201);
  assert.equal((await api('POST', '/push/apns', C.token, { token: cTok, environment: 'production' })).status, 201);

  const o = (await api('POST', '/', A.token, { name: 'طلعة النفود' })).body;
  assert.equal((await api('POST', '/invites/join', B.token, { token: o.invite.token })).status, 200);
  assert.equal((await api('POST', `/${o.outing_id}/status`, A.token, { action: 'start' })).status, 200);

  /* A note from A → B's iPhone only; the 410 token is deleted. */
  assert.equal((await api('POST', `/${o.outing_id}/note`, A.token, { text: 'بوقف عند المحطة' })).status, 200);
  await until(() => inbox.length >= 2);
  await settle();
  assert.deepEqual(inbox.map((m) => m.token).sort(), [dead, bNew].sort(), 'never the sender, never the outsider');
  const note = inbox.find((m) => m.token === bNew);
  assert.deepEqual(note.payload.aps.alert, { title: 'أبو فهد · طلعة النفود', body: 'بوقف عند المحطة' });
  assert.equal(note.payload.aps['interruption-level'], 'passive');
  assert.equal(note.payload.aps['thread-id'], `sary-outing-${o.outing_id}`);
  assert.equal(note.payload.outing_id, o.outing_id);
  assert.equal(note.headers['apns-topic'], 'sa.sary.albarq');
  assert.equal((await pool.query('SELECT 1 FROM sary.apns_tokens WHERE token = $1', [dead])).rowCount, 0, '410 → token deleted');

  /* The real SOS route: time-sensitive with sound; «أنا بخير» collapses onto it. */
  inbox.length = 0;
  assert.equal((await api('POST', `/${o.outing_id}/sos`, A.token, { fix: null })).status, 200);
  const sos = await until(() => inbox.find((m) => m.payload.type === 'sos'));
  assert.equal(sos.token, bNew);
  assert.equal(sos.payload.aps['interruption-level'], 'time-sensitive');
  assert.equal(sos.payload.aps.sound, 'default');
  assert.equal(sos.headers['apns-priority'], '10');
  assert.equal((await api('DELETE', `/${o.outing_id}/sos`, A.token)).status, 200);
  const clear = await until(() => inbox.find((m) => m.payload.type === 'sos_clear'));
  assert.equal(clear.headers['apns-collapse-id'], sos.headers['apns-collapse-id']);

  /* Leaving stops pushes at once. */
  assert.equal((await api('POST', `/${o.outing_id}/leave`, B.token)).status, 200);
  await new Promise((r) => setTimeout(r, 2_100));
  inbox.length = 0;
  assert.equal((await api('POST', `/${o.outing_id}/note`, A.token, { text: 'باقي أحد؟' })).status, 200);
  await settle();
  assert.equal(inbox.length, 0, 'former members get nothing');

  /* Unregister removes only my own token. */
  assert.deepEqual((await api('DELETE', '/push/apns', C.token, { token: aTok })).body, { ok: true, removed: 0 });
  assert.deepEqual((await api('DELETE', '/push/apns', A.token, { token: aTok })).body, { ok: true, removed: 1 });
});
