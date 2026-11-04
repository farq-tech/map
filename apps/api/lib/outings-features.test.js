'use strict';

/**
 * Outing features — return timer + watch link + sweeper, «غرّزت», shared
 * waypoints, convoy, trip plan (+ destination) and checklist — over a real
 * Postgres, the real router, real WebSockets, a fake clock and fake push
 * senders (web push + APNs).
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-features.test.js
 *
 * The DB test runs in its own database (`<db>_sary_features`). The pure tests
 * at the top run without a database.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const v = require('./outings/validate');
const { featurePayload, watcherPayload, createPushNotifier } = require('./outings/push');
const { apnsRequestFor, createApnsNotifier } = require('./outings/apns');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const RIYADH = { lat: 24.7136, lng: 46.6753 };
const fix = (i = 0, base = RIYADH) => ({ lat: base.lat + 0.001 * i, lng: base.lng + 0.001 * i, accuracy: 8, heading: 45, speed: 3, age_ms: 300 });
const jpeg = (bytes = 2000) => `data:image/jpeg;base64,${Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(bytes - 4, 9)]).toString('base64')}`;

/* ---------------- pure ---------------- */

test('validate: return timer due time and contact name', () => {
  const now = Date.parse('2026-11-04T10:00:00Z');
  assert.equal(v.returnTimer({ due_at: '2026-11-04T12:00:00Z', contact_name: '  أمي  ' }, now).value.contact_name, 'أمي');
  assert.equal(v.returnTimer({ due_at: '2026-11-04T10:00:30Z', contact_name: 'أمي' }, now).reason, 'invalid_due_at', 'under a minute ahead');
  assert.equal(v.returnTimer({ due_at: '2026-11-04T09:00:00Z', contact_name: 'أمي' }, now).reason, 'invalid_due_at', 'in the past');
  assert.equal(v.returnTimer({ due_at: '2026-11-12T10:00:00Z', contact_name: 'أمي' }, now).reason, 'invalid_due_at', 'over 7 days');
  assert.equal(v.returnTimer({ due_at: 'tomorrow', contact_name: 'أمي' }, now).reason, 'invalid_due_at');
  assert.equal(v.returnTimer({ due_at: '2026-11-04T12:00:00Z', contact_name: '' }, now).reason, 'invalid_contact_name');
  assert.equal([...v.returnTimer({ due_at: '2026-11-04T12:00:00Z', contact_name: 'ا'.repeat(60) }, now).value.contact_name].length, 40);
});

test('validate: waypoints — kind, title, note, coordinates, JPEG ≤150 KB', () => {
  const ok = v.waypoint({ kind: 'water', title: 'بئر', note: 'ماء عذب', lat: 24.5, lng: 46.5, photo: jpeg() });
  assert.equal(ok.ok, true);
  assert.equal(v.waypoint({ kind: 'lava', title: 'x', lat: 1, lng: 1 }).reason, 'invalid_kind');
  assert.equal(v.waypoint({ kind: 'camp', title: '', lat: 1, lng: 1 }).reason, 'invalid_title');
  assert.equal(v.waypoint({ kind: 'camp', title: 'x', lat: 91, lng: 1 }).reason, 'invalid_coordinates');
  assert.equal(v.waypoint({ kind: 'camp', title: 'x', lat: 0, lng: 0 }).reason, 'invalid_coordinates');
  assert.equal(v.waypoint({ kind: 'camp', title: 'x', lat: 1, lng: 1, photo: 'data:image/png;base64,iVBORw0KGgo=' }).reason, 'invalid_photo');
  assert.equal(v.waypointPhoto(`data:image/jpeg;base64,${Buffer.alloc(100, 1).toString('base64')}`), undefined, 'not really a JPEG');
  assert.ok(v.waypointPhoto(jpeg(150 * 1024)), 'exactly 150 KB');
  assert.equal(v.waypointPhoto(jpeg(150 * 1024 + 1)), undefined, 'over 150 KB');
  assert.equal([...v.waypoint({ kind: 'other', title: 'x', note: 'ن'.repeat(300), lat: 1, lng: 1 }).value.note].length, 140);
});

test('validate: convoy patch, plan route / notes / destination', () => {
  const id = crypto.randomUUID();
  assert.deepEqual(v.convoyPatch({ lead_user_id: id, tail_user_id: null, max_gap_m: 800 }), { lead: id, tail: null, gap: 800 });
  assert.equal(v.convoyPatch({ max_gap_m: 199 }), null);
  assert.equal(v.convoyPatch({ max_gap_m: 5001 }), null);
  assert.equal(v.convoyPatch({ lead_user_id: 'nope' }), null);
  assert.equal(v.convoyPatch({}), null);

  const line = { type: 'LineString', coordinates: [[46.6, 24.7], [46.7, 24.8]] };
  assert.deepEqual(v.planRoute(line), line);
  assert.equal(v.planRoute(null), null);
  assert.equal(v.planRoute({ type: 'LineString', coordinates: [[46.6, 24.7]] }), undefined, 'one point');
  assert.equal(v.planRoute({ type: 'Point', coordinates: [46.6, 24.7] }), undefined);
  assert.equal(v.planRoute({ type: 'LineString', coordinates: [[46.6, 95], [46.7, 24.8]] }), undefined);
  assert.equal(v.planRoute({ type: 'LineString', coordinates: Array.from({ length: 5001 }, (_, i) => [46 + i / 1e4, 24]) }), undefined);
  assert.equal(v.planRoute({ type: 'LineString', coordinates: Array.from({ length: 5000 }, (_, i) => [46 + i / 1e4, 24]) }).coordinates.length, 5000);
  assert.equal(v.planNotes('سطر\r\nسطر‮'), 'سطر\nسطر');
  assert.equal([...v.planNotes('x'.repeat(1200))].length, 1000);

  assert.deepEqual(v.destination({ name: ' روضة خريم ', lat: 25.38, lng: 47.27 }), { name: 'روضة خريم', lat: 25.38, lng: 47.27 });
  assert.equal(v.destination(null), null);
  assert.equal(v.destination({ name: '', lat: 25, lng: 47 }), undefined);
  assert.equal(v.destination({ name: 'x', lat: 25, lng: 181 }), undefined);
  assert.equal(v.destination({ name: 'x', lat: -91, lng: 47 }), undefined);
  assert.equal([...v.destination({ name: 'و'.repeat(41), lat: 25, lng: 47 }).name].length, 40, 'a long name is cut to 40');
  assert.equal(v.planPut({}).error, 'invalid_plan');
  assert.equal(v.planPut({ destination: { name: 'x', lat: 'a', lng: 1 } }).error, 'invalid_destination');
});

test('push payloads: Arabic texts, targeting flags, APNs interruption levels', () => {
  const overdue = featurePayload('return_timer_overdue', { outingName: 'طلعة', outingId: 'o' });
  assert.equal(overdue.body, 'تأخرتوا عن وقت الرجوع — اضغط وصلت أو مدّد');
  assert.equal(overdue.include_ended, true, 'reaches members of an outing that has ended');
  assert.equal(overdue.always, true);
  const st = featurePayload('member_stuck', { senderName: 'سعد', userId: 'u' });
  assert.match(st.title, /سعد غرّز/);
  const reply = featurePayload('stuck_reply', { senderName: 'فهد', replyKind: 'coming', userId: 'u2' });
  assert.equal(reply.body, 'فهد جاي');
  assert.equal(reply.to_user, 'u2', 'only the stuck person');
  assert.equal(featurePayload('stuck_reply', { senderName: 'فهد', replyKind: 'have_rope', userId: 'u2' }).body, 'فهد عنده حبل سحب');
  assert.match(featurePayload('waypoint_added', { senderName: 'فهد', title: 'بئر' }).body, /بئر/);
  assert.equal(featurePayload('nope'), null);
  assert.match(watcherPayload('overdue', { ownerName: 'فهد' }).body, /تأخروا عن وقت الرجوع/);
  assert.match(watcherPayload('arrived', { ownerName: 'فهد' }).title, /وصلوا بالسلامة/);

  const level = (p) => JSON.parse(apnsRequestFor(p, 'o').body).aps['interruption-level'];
  assert.equal(level(st), 'time-sensitive');
  assert.equal(level(overdue), 'time-sensitive');
  assert.equal(level(reply), 'active');
  assert.equal(level(featurePayload('waypoint_added', { title: 'x' })), 'passive');
  assert.equal(JSON.parse(apnsRequestFor(featurePayload('waypoint_added', { title: 'x' }), 'o').body).aps.sound, undefined, 'passive is silent');
});

test('notifiers pass include_ended / to_user into the recipient query', async () => {
  const calls = [];
  const pool = { query: async (text, params) => { calls.push({ text, params }); return { rows: [] }; } };
  const web = createPushNotifier({ pool, config: { enabled: true, publicKey: 'k', privateKey: 'p' }, sender: { send: async () => ({}) } });
  await web.notifyMembers('11111111-1111-4111-8111-111111111111', null, { type: 'stuck_reply', to_user: '22222222-2222-4222-8222-222222222222', include_ended: true });
  assert.deepEqual(calls[0].params.slice(2), [true, '22222222-2222-4222-8222-222222222222']);
  const apns = createApnsNotifier({ pool, config: { enabled: true, bundleId: 'sa.sary.albarq', key: {} }, sender: { send: async () => ({ status: 200 }) }, info: () => {} });
  await apns.notifyMembers('11111111-1111-4111-8111-111111111111', null, { type: 'x' });
  assert.deepEqual(calls[1].params.slice(3), [false, null]);
});

/* ---------------- database ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_features`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('outing features end to end', { skip, timeout: 120_000 }, async (t) => {
  const { createPool, migrate } = require('./outings/db');
  const { setupOutings } = require('./outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);

  /* Fake clock: real time plus an offset the test moves forward. */
  let offset = 0;
  const now = () => Date.now() + offset;
  const advance = (ms) => { offset += ms; };

  const webInbox = [];
  const apnsInbox = [];
  const outings = setupOutings({
    pool,
    autoMigrate: false,
    now,
    config: { minFixIntervalMs: 0, persistEveryMs: 0 },
    limits: { identityPerHour: 100, invitePer10Min: 100, deletePerHour: 10 },
    push: {
      config: { enabled: true, publicKey: 'BTestPublicKey', privateKey: 'unused-by-fake' },
      sender: { async send(sub, body, opts) { webInbox.push({ endpoint: sub.endpoint, payload: JSON.parse(body), opts }); return { statusCode: 201 }; } },
    },
    apns: {
      config: { enabled: true, bundleId: 'sa.sary.albarq', key: {} },
      sender: { async send(device, req) { apnsInbox.push({ token: device.token, headers: req.headers, body: JSON.parse(req.body) }); return { status: 200 }; } },
    },
  });
  const app = express();
  app.use(express.json({ limit: '1mb' })); // as server.js
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
  const svc = outings.service;
  const api = async (method, path, token, body) => {
    const res = await fetch(`http://127.0.0.1:${port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body && method !== 'GET' ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
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
  const until = async (pred, ms = 5000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const x = pred();
      if (x) return x;
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error('timeout');
  };
  const settle = () => new Promise((r) => setTimeout(r, 250));
  const keys = () => {
    const ecdh = crypto.createECDH('prime256v1');
    ecdh.generateKeys();
    return { p256dh: ecdh.getPublicKey().toString('base64url'), auth: crypto.randomBytes(16).toString('base64url') };
  };
  const sub = (name) => ({ endpoint: `https://fcm.googleapis.com/fcm/send/${name}-${crypto.randomUUID()}`, keys: keys() });
  const hexToken = () => crypto.randomBytes(32).toString('hex');

  /* --- people: A owner, B member, D co-leader (sharing off), C outsider --- */
  const mk = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  const A = await mk('أبو فهد');
  const B = await mk('سعد');
  const C = await mk('غريب');
  const D = await mk('مساعد');
  await api('PATCH', '/me', A.token, { phone: '0551234567' });
  const subs = {};
  const apnsTok = {};
  for (const [n, p] of Object.entries({ A, B, D })) {
    subs[n] = sub(n);
    apnsTok[n] = hexToken();
    assert.equal((await api('POST', '/push/subscribe', p.token, { subscription: subs[n] })).status, 201);
    assert.equal((await api('POST', '/push/apns', p.token, { token: apnsTok[n], environment: 'sandbox' })).status, 201);
  }
  const webTo = (n, type) => webInbox.filter((m) => m.endpoint === subs[n].endpoint && m.payload.type === type);
  const apnsTo = (n, type) => apnsInbox.filter((m) => m.token === apnsTok[n] && m.body.type === type);

  const created = await api('POST', '/', A.token, { name: 'طلعة النفود' });
  const O = created.body.outing_id;
  for (const p of [B, D]) assert.equal((await api('POST', '/invites/join', p.token, { token: created.body.invite.token })).status, 200);
  assert.equal((await api('POST', `/${O}/members/${D.user.id}/co-leader`, A.token, { co_leader: true })).status, 200);
  assert.equal((await api('POST', `/${O}/status`, A.token, { action: 'start' })).status, 200);
  assert.equal((await api('PATCH', `/${O}/me`, D.token, { sharing: false })).status, 200);
  assert.equal((await api('POST', `/${O}/positions`, A.token, { fix: fix(0) })).status, 200);
  assert.equal((await api('POST', `/${O}/positions`, B.token, { fix: fix(3) })).status, 200);

  /* Everyone has the outing open in the background (away), so pushes are not skipped as "on screen". */
  const la = live(A.token, O);
  const lb = live(B.token, O);
  await Promise.all([la.opened, lb.opened]);
  await la.next((m) => m.type === 'ready');
  await lb.next((m) => m.type === 'ready');
  la.send({ type: 'presence', away: true });
  lb.send({ type: 'presence', away: true });
  await settle();

  /* ============ 1. return timer ============ */
  const due = (ms) => new Date(now() + ms).toISOString();
  for (const [method, path] of [['GET', '/return-timer'], ['POST', '/return-timer'], ['POST', '/return-timer/arrived'], ['DELETE', '/return-timer']]) {
    assert.equal((await api(method, `/${O}${path}`, null, { due_at: due(3600_000), contact_name: 'أمي' })).status, 401, `${method} ${path} needs auth`);
    assert.equal((await api(method, `/${O}${path}`, C.token, { due_at: due(3600_000), contact_name: 'أمي' })).status, 404, `${method} ${path}: outsider`);
  }
  assert.equal((await api('POST', `/${O}/return-timer`, A.token, { due_at: due(10_000), contact_name: 'أمي' })).body.error, 'invalid_due_at');
  assert.equal((await api('POST', `/${O}/return-timer`, A.token, { due_at: due(3600_000), contact_name: '' })).body.error, 'invalid_contact_name');
  assert.deepEqual((await api('GET', `/${O}/return-timer`, A.token)).body, { ok: true, timer: null });

  const armed = await api('POST', `/${O}/return-timer`, A.token, { due_at: due(3600_000), contact_name: 'أمي' });
  assert.equal(armed.status, 201);
  assert.deepEqual(Object.keys(armed.body.timer).sort(), ['contact_name', 'due_at', 'id', 'state']);
  assert.equal(armed.body.timer.state, 'armed');
  const m = /^https:\/\/farq-map-investor\.vercel\.app\/watch#([A-Za-z0-9_-]{43})$/.exec(armed.body.watch_url);
  assert.ok(m, 'watch_url carries a 43-char base64url token in the fragment');
  const tokA1 = m[1];
  const ev = await lb.next((x) => x.type === 'return_timer');
  assert.deepEqual(ev, { type: 'return_timer', user_id: A.user.id, state: 'armed', due_at: armed.body.timer.due_at });
  assert.equal((await api('GET', `/${O}/return-timer`, A.token)).body.timer.id, armed.body.timer.id);
  assert.equal((await api('GET', `/${O}/return-timer`, B.token)).body.timer, null, 'only my own timer');

  /* Token hashing: only the SHA-256 digest is stored, nowhere the plaintext. */
  const { rows: tokRows } = await pool.query('SELECT token_hash FROM sary.watch_tokens WHERE timer_id = $1', [armed.body.timer.id]);
  assert.equal(tokRows.length, 1);
  assert.ok(tokRows[0].token_hash.equals(crypto.createHash('sha256').update(tokA1).digest()));
  const dump = JSON.stringify((await pool.query('SELECT t.*, w.* FROM sary.return_timers t JOIN sary.watch_tokens w ON w.timer_id = t.id')).rows);
  assert.ok(!dump.includes(tokA1), 'plaintext token is not in the database');

  /* Public watch link: no auth, token in the body. */
  assert.equal((await api('POST', '/watch/status', null, { token: 'A'.repeat(43) })).status, 404, 'guessed token');
  assert.equal((await api('POST', '/watch/status', null, { token: 'short' })).status, 404);
  assert.equal((await api('POST', '/watch/status', null, {})).status, 404);
  const ws1 = await api('POST', '/watch/status', null, { token: tokA1 });
  assert.equal(ws1.status, 200);
  assert.equal(ws1.body.state, 'armed');
  assert.equal(ws1.body.outing_name, 'طلعة النفود');
  assert.equal(ws1.body.owner_name, 'أبو فهد');
  assert.equal(ws1.body.contact_name, 'أمي');
  assert.deepEqual(ws1.body.members.map((x) => x.name).sort(), ['أبو فهد', 'سعد', 'مساعد'].sort());
  assert.equal('last_known' in ws1.body, false, 'no positions before overdue');
  assert.equal('owner_phone' in ws1.body, false, 'no phone before overdue');
  assert.ok(!JSON.stringify(ws1.body).includes(String(RIYADH.lat).slice(0, 5)), 'not a coordinate anywhere');
  assert.equal((await pool.query('SELECT last_known FROM sary.return_timers WHERE id = $1', [armed.body.timer.id])).rows[0].last_known, null, 'nothing snapshotted while armed');

  /* Watcher subscribes to web push. */
  const watcherSub = sub('watcher');
  assert.equal((await api('POST', '/watch/subscribe', null, { token: tokA1, subscription: { endpoint: 'https://evil.example.com/x', keys: keys() } })).status, 400);
  assert.equal((await api('POST', '/watch/subscribe', null, { token: 'B'.repeat(43), subscription: watcherSub })).status, 404);
  assert.equal((await api('POST', '/watch/subscribe', null, { token: tokA1, subscription: watcherSub })).status, 201);
  const watcherGot = (type) => webInbox.filter((x) => x.endpoint === watcherSub.endpoint && x.payload.type === type);

  /* Sweeper before due: nothing. */
  assert.deepEqual(await svc.sweepReturnTimers(), { overdue: 0 });
  /* Fake clock past due → overdue, with the snapshot of members who share (A, B — not D). */
  advance(2 * 3600_000);
  assert.equal((await api('POST', `/${O}/positions`, B.token, { fix: fix(5) })).status, 200, 'B moved after due: snapshot is taken at the sweep');
  assert.deepEqual(await svc.sweepReturnTimers(), { overdue: 1 });
  assert.deepEqual(await svc.sweepReturnTimers(), { overdue: 0 }, 'never alarms twice');
  const evOver = await lb.next((x) => x.type === 'return_timer' && x.state === 'overdue');
  assert.equal(evOver.user_id, A.user.id);
  const ws2 = (await api('POST', '/watch/status', null, { token: tokA1 })).body;
  assert.equal(ws2.state, 'overdue');
  assert.equal(ws2.owner_phone, '+966551234567');
  assert.deepEqual(ws2.last_known.map((x) => x.name).sort(), ['أبو فهد', 'سعد'].sort(), 'only sharing members');
  for (const p of ws2.last_known) assert.deepEqual(Object.keys(p).sort(), ['at', 'lat', 'lng', 'name'], 'no user ids leave the outing');
  const bSnap = ws2.last_known.find((x) => x.name === 'سعد');
  assert.equal(bSnap.lat, fix(5).lat);
  /* Later movement does not change the snapshot. */
  assert.equal((await api('POST', `/${O}/positions`, B.token, { fix: fix(9) })).status, 200);
  assert.equal((await api('POST', '/watch/status', null, { token: tokA1 })).body.last_known.find((x) => x.name === 'سعد').lat, fix(5).lat);

  /* Push fan-out: watcher (web), every member incl. the timer owner (web + APNs, time-sensitive). */
  await until(() => watcherGot('return_timer_overdue').length === 1);
  const wp = watcherGot('return_timer_overdue')[0].payload;
  assert.equal(wp.url, '/watch');
  assert.equal('outing_id' in wp, false, 'the watcher push carries no outing id');
  for (const n of ['A', 'B', 'D']) {
    await until(() => webTo(n, 'return_timer_overdue').length === 1 && apnsTo(n, 'return_timer_overdue').length === 1);
    assert.equal(webTo(n, 'return_timer_overdue')[0].payload.body, 'تأخرتوا عن وقت الرجوع — اضغط وصلت أو مدّد');
    assert.equal(apnsTo(n, 'return_timer_overdue')[0].body.aps['interruption-level'], 'time-sensitive');
  }

  /* «مدّد» — same contact: same timer, the old link keeps working, a new link too, watchers told. */
  const ext = await api('POST', `/${O}/return-timer`, A.token, { due_at: due(3600_000), contact_name: 'أمي' });
  assert.equal(ext.status, 201);
  assert.equal(ext.body.timer.id, armed.body.timer.id);
  const tokA2 = ext.body.watch_url.split('#')[1];
  for (const tk of [tokA1, tokA2]) {
    const s = (await api('POST', '/watch/status', null, { token: tk })).body;
    assert.equal(s.state, 'armed');
    assert.equal(s.due_at, ext.body.timer.due_at);
    assert.equal('last_known' in s, false, 'snapshot hidden (and cleared) once armed again');
  }
  assert.equal((await pool.query('SELECT last_known FROM sary.return_timers WHERE id = $1', [armed.body.timer.id])).rows[0].last_known, null);
  await until(() => watcherGot('return_timer_extended').length === 1);

  /* «وصلت» → arrived, watchers get «وصلوا بالسلامة», link says so and shows no names. */
  const arr = await api('POST', `/${O}/return-timer/arrived`, A.token);
  assert.equal(arr.body.timer.state, 'arrived');
  await lb.next((x) => x.type === 'return_timer' && x.state === 'arrived');
  await until(() => watcherGot('return_timer_arrived').length === 1);
  assert.match(watcherGot('return_timer_arrived')[0].payload.title, /وصلوا بالسلامة/);
  const ws3 = (await api('POST', '/watch/status', null, { token: tokA1 })).body;
  assert.equal(ws3.state, 'arrived');
  assert.deepEqual(ws3.members, []);
  assert.equal((await api('POST', `/${O}/return-timer/arrived`, A.token)).status, 404, 'nothing left to close');
  assert.equal((await api('POST', '/watch/subscribe', null, { token: tokA1, subscription: sub('late') })).status, 410, 'closed link takes no new watchers');

  /* Different contact replaces: old link shows cancelled. Then DELETE cancels. */
  const t1 = await api('POST', `/${O}/return-timer`, A.token, { due_at: due(3600_000), contact_name: 'أبوي' });
  const t2 = await api('POST', `/${O}/return-timer`, A.token, { due_at: due(3600_000), contact_name: 'أخوي' });
  assert.notEqual(t1.body.timer.id, t2.body.timer.id);
  assert.equal((await api('POST', '/watch/status', null, { token: t1.body.watch_url.split('#')[1] })).body.state, 'cancelled');
  assert.equal((await api('DELETE', `/${O}/return-timer`, A.token)).body.timer.state, 'cancelled');
  assert.equal((await api('POST', '/watch/status', null, { token: t2.body.watch_url.split('#')[1] })).body.state, 'cancelled');

  /* ============ 2. «غرّزت» ============ */
  assert.equal((await api('POST', `/${O}/stuck`, null, {})).status, 401);
  assert.equal((await api('POST', `/${O}/stuck`, C.token, {})).status, 404);
  const st = await api('POST', `/${O}/stuck`, B.token, { note: 'غرّزت عند الطعس الكبير', fix: { lat: 1, lng: 1 } });
  assert.equal(st.status, 200);
  assert.equal(st.body.stuck.note, 'غرّزت عند الطعس الكبير');
  assert.equal('fix' in st.body.stuck, false, 'no position rides on «غرّزت»');
  const evStuck = await la.next((x) => x.type === 'member_stuck');
  assert.deepEqual(Object.keys(evStuck).sort(), ['at', 'note', 'type', 'user_id']);
  assert.equal(evStuck.user_id, B.user.id);
  await until(() => webTo('A', 'member_stuck').length === 1 && apnsTo('A', 'member_stuck').length === 1);
  assert.match(webTo('A', 'member_stuck')[0].payload.title, /سعد غرّز/);
  assert.equal(apnsTo('A', 'member_stuck')[0].body.aps['interruption-level'], 'time-sensitive');
  assert.equal(webTo('B', 'member_stuck').length, 0, 'not to the sender');
  assert.equal((await api('POST', `/${O}/stuck`, B.token, { note: 'x' })).status, 429, 'too frequent');
  advance(5_000);
  assert.equal((await api('POST', `/${O}/stuck`, B.token, { note: 'ما زلت' })).status, 200);
  await settle();
  assert.equal(webTo('A', 'member_stuck').length, 1, 'a refresh does not alarm again');

  assert.equal((await api('POST', `/${O}/stuck/${B.user.id}/reply`, A.token, { kind: 'teleport' })).body.error, 'invalid_kind');
  assert.equal((await api('POST', `/${O}/stuck/${B.user.id}/reply`, B.token, { kind: 'coming' })).body.error, 'cannot_reply_self');
  assert.equal((await api('POST', `/${O}/stuck/${A.user.id}/reply`, B.token, { kind: 'coming' })).status, 404, 'A is not stuck');
  assert.equal((await api('POST', `/${O}/stuck/${B.user.id}/reply`, C.token, { kind: 'coming' })).status, 404, 'outsider');
  const rep = await api('POST', `/${O}/stuck/${B.user.id}/reply`, A.token, { kind: 'coming' });
  assert.equal(rep.status, 200);
  assert.deepEqual(await lb.next((x) => x.type === 'stuck_reply'), { type: 'stuck_reply', user_id: A.user.id, to_user_id: B.user.id, kind: 'coming' });
  await until(() => webTo('B', 'stuck_reply').length === 1 && apnsTo('B', 'stuck_reply').length === 1);
  assert.equal(webTo('B', 'stuck_reply')[0].payload.body, 'أبو فهد جاي');
  await settle();
  assert.equal(webTo('D', 'stuck_reply').length + apnsTo('D', 'stuck_reply').length, 0, 'the reply goes to the stuck person only');
  const liveSnap = (await api('GET', `/${O}/live`, D.token)).body;
  assert.deepEqual(liveSnap.stuck, [{ user_id: B.user.id, at: evStuck.at, note: 'ما زلت', replies: [{ user_id: A.user.id, kind: 'coming' }] }]);
  assert.equal((await api('DELETE', `/${O}/stuck`, B.token)).status, 200);
  assert.deepEqual(await la.next((x) => x.type === 'stuck_clear'), { type: 'stuck_clear', user_id: B.user.id });
  assert.deepEqual((await api('GET', `/${O}/live`, A.token)).body.stuck, []);
  /* Auto-clears after 3 h. */
  advance(5_000);
  await api('POST', `/${O}/stuck`, B.token, {});
  advance(3 * 3600_000 + 1000);
  assert.deepEqual((await api('GET', `/${O}/live`, A.token)).body.stuck, [], 'gone after 3 h');

  /* ============ 3. waypoints ============ */
  const wpBody = { kind: 'water', title: 'بئر الشيحية', note: 'ماء صالح للشرب', lat: 25.1, lng: 46.2, photo: jpeg(140 * 1024) };
  assert.equal((await api('POST', `/${O}/waypoints`, null, wpBody)).status, 401);
  assert.equal((await api('POST', `/${O}/waypoints`, C.token, wpBody)).status, 404);
  assert.equal((await api('GET', `/${O}/waypoints`, C.token)).status, 404);
  assert.equal((await api('POST', `/${O}/waypoints`, A.token, { ...wpBody, kind: 'lava' })).body.error, 'invalid_kind');
  assert.equal((await api('POST', `/${O}/waypoints`, A.token, { ...wpBody, photo: jpeg(151 * 1024) })).body.error, 'invalid_photo');
  assert.equal((await api('POST', `/${O}/waypoints`, A.token, { ...wpBody, lat: 'x' })).body.error, 'invalid_coordinates');
  const w1 = await api('POST', `/${O}/waypoints`, A.token, wpBody);
  assert.equal(w1.status, 201, 'a 140 KB photo fits');
  assert.equal(w1.body.waypoint.photo, wpBody.photo);
  assert.equal(w1.body.waypoint.user_id, A.user.id);
  assert.equal((await lb.next((x) => x.type === 'waypoint_added')).waypoint.id, w1.body.waypoint.id);
  await until(() => apnsTo('B', 'waypoint_added').length === 1);
  assert.equal(apnsTo('B', 'waypoint_added')[0].body.aps['interruption-level'], 'passive');
  const w2 = await api('POST', `/${O}/waypoints`, B.token, { kind: 'danger', title: 'حفرة', lat: 25.2, lng: 46.3 });
  const w3 = await api('POST', `/${O}/waypoints`, B.token, { kind: 'camp', title: 'المخيم', lat: 25.3, lng: 46.4 });
  const list = (await api('GET', `/${O}/waypoints`, D.token)).body.waypoints;
  assert.deepEqual(list.map((x) => x.title), ['بئر الشيحية', 'حفرة', 'المخيم']);
  assert.equal((await api('DELETE', `/${O}/waypoints/${w1.body.waypoint.id}`, B.token)).status, 403, 'not the creator, not a leader');
  assert.equal((await api('DELETE', `/${O}/waypoints/${w1.body.waypoint.id}`, C.token)).status, 404);
  assert.equal((await api('DELETE', `/${O}/waypoints/${crypto.randomUUID()}`, A.token)).status, 404);
  assert.equal((await api('DELETE', `/${O}/waypoints/${w2.body.waypoint.id}`, D.token)).status, 200, 'co-leader may');
  assert.deepEqual(await la.next((x) => x.type === 'waypoint_removed'), { type: 'waypoint_removed', id: w2.body.waypoint.id });
  assert.equal((await api('DELETE', `/${O}/waypoints/${w3.body.waypoint.id}`, B.token)).status, 200, 'creator may');

  /* ============ 4. convoy ============ */
  assert.deepEqual((await api('GET', `/${O}`, B.token)).body.outing.convoy, { lead_user_id: null, tail_user_id: null, max_gap_m: 1000 });
  assert.equal((await api('PATCH', `/${O}/convoy`, null, { max_gap_m: 500 })).status, 401);
  assert.equal((await api('PATCH', `/${O}/convoy`, C.token, { max_gap_m: 500 })).status, 404);
  assert.equal((await api('PATCH', `/${O}/convoy`, B.token, { max_gap_m: 500 })).status, 403, 'members cannot');
  assert.equal((await api('PATCH', `/${O}/convoy`, A.token, { max_gap_m: 100 })).body.error, 'invalid_convoy');
  assert.equal((await api('PATCH', `/${O}/convoy`, A.token, { lead_user_id: C.user.id })).body.error, 'invalid_convoy_member');
  assert.equal((await api('PATCH', `/${O}/convoy`, A.token, { lead_user_id: B.user.id, tail_user_id: B.user.id })).body.error, 'invalid_convoy');
  const cv = await api('PATCH', `/${O}/convoy`, A.token, { lead_user_id: A.user.id, tail_user_id: B.user.id, max_gap_m: 800 });
  assert.deepEqual(cv.body.convoy, { lead_user_id: A.user.id, tail_user_id: B.user.id, max_gap_m: 800 });
  assert.deepEqual((await lb.next((x) => x.type === 'convoy_updated')).convoy, cv.body.convoy);
  assert.equal((await api('PATCH', `/${O}/convoy`, D.token, { max_gap_m: 1200 })).body.convoy.max_gap_m, 1200, 'co-leader may; others kept');
  assert.deepEqual((await api('GET', `/${O}/live`, B.token)).body.outing.convoy, { lead_user_id: A.user.id, tail_user_id: B.user.id, max_gap_m: 1200 });

  /* ============ 5. plan + destination ============ */
  const route = { type: 'LineString', coordinates: Array.from({ length: 5000 }, (_, i) => [46.6 + i / 1e5, 24.7 + i / 1e5]) };
  assert.deepEqual((await api('GET', `/${O}/plan`, B.token)).body, { ok: true, route: null, notes: '', destination: null, updated_at: null });
  assert.equal((await api('GET', `/${O}/plan`, C.token)).status, 404);
  assert.equal((await api('PUT', `/${O}/plan`, null, { notes: 'x' })).status, 401);
  assert.equal((await api('PUT', `/${O}/plan`, B.token, { notes: 'x' })).status, 403, 'members cannot');
  assert.equal((await api('PUT', `/${O}/plan`, A.token, { route: { type: 'LineString', coordinates: [[46, 24]] } })).body.error, 'invalid_route');
  assert.equal((await api('PUT', `/${O}/plan`, A.token, { destination: { name: 'x', lat: 91, lng: 46 } })).body.error, 'invalid_destination');
  assert.equal((await api('PUT', `/${O}/plan`, A.token, { destination: { name: '', lat: 25, lng: 46 } })).body.error, 'invalid_destination');
  const dest = { name: 'روضة خريم', lat: 25.38, lng: 47.27 };
  const put = await api('PUT', `/${O}/plan`, A.token, { route, notes: 'نطلع الفجر\nنرجع قبل المغرب', destination: dest });
  assert.equal(put.status, 200, 'a 5000-point route fits');
  assert.equal(put.body.route.coordinates.length, 5000);
  assert.equal(put.body.notes, 'نطلع الفجر\nنرجع قبل المغرب');
  assert.deepEqual(put.body.destination, dest);
  const evPlan = await lb.next((x) => x.type === 'plan_updated');
  assert.deepEqual(evPlan.plan.destination, dest);
  assert.equal(evPlan.plan.updated_at, put.body.updated_at);
  const put2 = await api('PUT', `/${O}/plan`, D.token, { notes: 'تغيير' });
  assert.equal(put2.body.route.coordinates.length, 5000, 'absent fields are kept');
  assert.deepEqual(put2.body.destination, dest);
  assert.equal((await api('PUT', `/${O}/plan`, A.token, { destination: null })).body.destination, null, 'null clears it');
  assert.equal((await api('GET', `/${O}/plan`, B.token)).body.notes, 'تغيير');

  /* ============ 5b. checklist ============ */
  assert.equal((await api('GET', `/${O}/checklist`, C.token)).status, 404);
  assert.equal((await api('POST', `/${O}/checklist`, C.token, { title: 'حطب' })).status, 404);
  assert.equal((await api('POST', `/${O}/checklist`, B.token, { title: '' })).body.error, 'invalid_title');
  const i1 = await api('POST', `/${O}/checklist`, A.token, { title: 'حطب' });
  assert.equal(i1.status, 201);
  assert.deepEqual((await lb.next((x) => x.type === 'checklist_updated')).items.map((x) => x.title), ['حطب']);
  const i2 = await api('POST', `/${O}/checklist`, B.token, { title: 'ماء' });
  assert.equal(i2.body.item.created_by, B.user.id);
  assert.equal((await api('PATCH', `/${O}/checklist/${i1.body.item.id}`, B.token, { assignee_user_id: C.user.id })).body.error, 'invalid_assignee');
  assert.equal((await api('PATCH', `/${O}/checklist/${i1.body.item.id}`, B.token, { done: 'yes' })).body.error, 'invalid_item');
  assert.equal((await api('PATCH', `/${O}/checklist/${crypto.randomUUID()}`, B.token, { done: true })).status, 404);
  const pa = await api('PATCH', `/${O}/checklist/${i1.body.item.id}`, B.token, { assignee_user_id: B.user.id, done: true });
  assert.deepEqual([pa.body.item.assignee_user_id, pa.body.item.done], [B.user.id, true]);
  const evList = await la.next((x) => x.type === 'checklist_updated' && x.items.some((i) => i.done));
  assert.equal(evList.items.length, 2);
  assert.equal((await api('DELETE', `/${O}/checklist/${i1.body.item.id}`, B.token)).status, 403, 'not the creator, not a leader');
  assert.equal((await api('DELETE', `/${O}/checklist/${i2.body.item.id}`, B.token)).status, 200, 'creator may');
  assert.equal((await api('DELETE', `/${O}/checklist/${i1.body.item.id}`, A.token)).status, 200, 'leader may');
  assert.deepEqual((await api('GET', `/${O}/checklist`, D.token)).body.items, []);

  /* ============ ending does NOT cancel a return timer ============ */
  const tb = await api('POST', `/${O}/return-timer`, B.token, { due_at: due(3600_000), contact_name: 'زوجتي' });
  const tokB = tb.body.watch_url.split('#')[1];
  await api('POST', `/${O}/waypoints`, A.token, { kind: 'passable', title: 'طريق سالك', lat: 25.5, lng: 46.5 });
  assert.equal((await api('POST', `/${O}/status`, A.token, { action: 'end' })).status, 200);
  assert.equal((await api('POST', '/watch/status', null, { token: tokB })).body.state, 'armed', 'still armed after the outing ended');
  assert.equal((await api('GET', `/${O}/return-timer`, B.token)).body.timer.state, 'armed');
  assert.equal((await api('GET', `/${O}/waypoints`, B.token)).body.waypoints.length, 2, 'waypoints persist after the outing ends');
  assert.equal((await api('POST', `/${O}/waypoints`, B.token, { kind: 'camp', title: 'x', lat: 25, lng: 46 })).status, 409);
  assert.equal((await api('POST', `/${O}/stuck`, B.token, {})).status, 409);
  assert.equal((await api('PUT', `/${O}/plan`, A.token, { notes: 'x' })).status, 409);
  assert.equal((await api('POST', `/${O}/checklist`, A.token, { title: 'x' })).status, 409);
  advance(2 * 3600_000);
  const beforeB = webTo('A', 'return_timer_overdue').length;
  assert.deepEqual(await svc.sweepReturnTimers(), { overdue: 1 });
  const sB = (await api('POST', '/watch/status', null, { token: tokB })).body;
  assert.equal(sB.state, 'overdue');
  assert.deepEqual(sB.last_known, [], 'outing ended: positions were deleted, nothing is invented');
  assert.equal(sB.owner_phone, null, 'B has no phone on the profile');
  await until(() => webTo('A', 'return_timer_overdue').length === beforeB + 1 && webTo('B', 'return_timer_overdue').length === 2);
  assert.equal((await api('POST', `/${O}/return-timer/arrived`, B.token)).status, 200, '«وصلت» works after the outing ended');

  /* ============ outing 2: leaving keeps the timer closable; account deletion cleanup ============ */
  const E = await mk('عمر');
  const c2 = await api('POST', '/', A.token, { name: 'طلعة ثانية' });
  const O2 = c2.body.outing_id;
  for (const p of [B, E]) await api('POST', '/invites/join', p.token, { token: c2.body.invite.token });
  await api('POST', `/${O2}/status`, A.token, { action: 'start' });
  await api('POST', `/${O2}/positions`, A.token, { fix: fix(0) });
  await api('POST', `/${O2}/positions`, B.token, { fix: fix(4) });

  const te = await api('POST', `/${O2}/return-timer`, E.token, { due_at: due(3600_000), contact_name: 'أمي' });
  assert.equal((await api('POST', `/${O2}/leave`, E.token)).status, 200);
  assert.equal((await api('GET', `/${O2}/return-timer`, E.token)).body.timer.id, te.body.timer.id, 'leaving does not cancel it');
  assert.equal((await api('POST', `/${O2}/return-timer`, E.token, { due_at: due(3600_000), contact_name: 'أمي' })).status, 404, 'but a former member cannot arm a new one');
  assert.equal((await api('DELETE', `/${O2}/return-timer`, E.token)).body.timer.state, 'cancelled', 'and can still cancel their own');

  /* B leaves stuff everywhere, then deletes the account. */
  const ta = await api('POST', `/${O2}/return-timer`, A.token, { due_at: due(3600_000), contact_name: 'أمي' });
  const tokA3 = ta.body.watch_url.split('#')[1];
  const tb2 = await api('POST', `/${O2}/return-timer`, B.token, { due_at: due(7200_000), contact_name: 'أخوي' });
  const tokB2 = tb2.body.watch_url.split('#')[1];
  assert.equal((await api('POST', '/watch/subscribe', null, { token: tokB2, subscription: sub('wb') })).status, 201);
  await api('POST', `/${O2}/waypoints`, B.token, { kind: 'stuck_spot', title: 'تغريز', lat: 25.6, lng: 46.6 });
  const keepWp = await api('POST', `/${O2}/waypoints`, A.token, { kind: 'camp', title: 'مخيم', lat: 25.7, lng: 46.7 });
  const bItem = await api('POST', `/${O2}/checklist`, B.token, { title: 'كشاف' });
  const aItem = await api('POST', `/${O2}/checklist`, A.token, { title: 'خيمة' });
  await api('PATCH', `/${O2}/checklist/${aItem.body.item.id}`, A.token, { assignee_user_id: B.user.id });
  await api('PATCH', `/${O2}/convoy`, A.token, { lead_user_id: A.user.id, tail_user_id: B.user.id });
  advance(5_000);
  await api('POST', `/${O2}/stuck`, B.token, { note: 'غرّزت' });
  advance(3600_000 + 60_000);
  assert.deepEqual(await svc.sweepReturnTimers(), { overdue: 1 }, 'A overdue, with B in the snapshot');
  assert.ok((await api('POST', '/watch/status', null, { token: tokA3 })).body.last_known.some((x) => x.name === 'سعد'));

  const la2 = live(A.token, O2);
  await la2.opened;
  await la2.next((x) => x.type === 'ready');
  assert.equal((await api('DELETE', '/me', B.token)).status, 200);
  await la2.next((x) => x.type === 'stuck_clear' && x.user_id === B.user.id);
  await la2.next((x) => x.type === 'waypoint_removed');
  await la2.next((x) => x.type === 'return_timer' && x.user_id === B.user.id && x.state === 'cancelled');
  assert.equal((await api('POST', '/watch/status', null, { token: tokB2 })).status, 404, "B's watch link is gone with B");
  const count = async (sql, p) => (await pool.query(sql, p)).rows[0].n;
  assert.equal(await count('SELECT count(*)::int AS n FROM sary.return_timers WHERE user_id = $1', [B.user.id]), 0);
  assert.equal(await count('SELECT count(*)::int AS n FROM sary.outing_waypoints WHERE user_id = $1', [B.user.id]), 0);
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.watch_subscriptions WHERE endpoint LIKE '%/wb-%'`), 0);
  assert.deepEqual((await api('GET', `/${O2}/waypoints`, A.token)).body.waypoints.map((x) => x.id), [keepWp.body.waypoint.id]);
  const items = (await api('GET', `/${O2}/checklist`, A.token)).body.items;
  assert.equal(items.find((i) => i.id === bItem.body.item.id).created_by, A.user.id, "B's item passes to the owner");
  assert.equal(items.find((i) => i.id === aItem.body.item.id).assignee_user_id, null, 'unassigned');
  const snapA = (await api('POST', '/watch/status', null, { token: tokA3 })).body;
  assert.equal(snapA.state, 'overdue');
  assert.deepEqual(snapA.last_known.map((x) => x.name), ['أبو فهد'], "B is struck from other people's snapshots");
  assert.ok(!JSON.stringify((await pool.query('SELECT last_known FROM sary.return_timers')).rows).includes(B.user.id));
  const o2 = (await api('GET', `/${O2}`, A.token)).body;
  assert.deepEqual(o2.outing.convoy, { lead_user_id: A.user.id, tail_user_id: null, max_gap_m: 1000 });
  assert.deepEqual(o2.stuck, []);

  /* Housekeeping sweep: closed timers go after a day, unclosed overdue ones 7 days after due. */
  advance(25 * 3600_000);
  await svc.sweep();
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.return_timers WHERE state IN ('arrived', 'cancelled')`), 0);
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.return_timers WHERE state = 'overdue'`), 1);
  advance(7 * 24 * 3600_000);
  await svc.sweep();
  assert.equal(await count('SELECT count(*)::int AS n FROM sary.return_timers'), 0);
  assert.equal((await api('POST', '/watch/status', null, { token: tokA3 })).status, 404);

  for (const s of [la, lb, la2]) s.ws.close();
});

test('watch link is rate limited per address', { skip, timeout: 30_000 }, async (t) => {
  const { createPool } = require('./outings/db');
  const { setupOutings } = require('./outings');
  const pool = createPool(await isolatedDb(URL_));
  const outings = setupOutings({ pool, autoMigrate: false, limits: { watchPer10Min: 3 } });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(async () => {
    outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const hit = () => fetch(`http://127.0.0.1:${server.address().port}/api/outings/watch/status`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: 'A'.repeat(43) }) }).then((r) => r.status);
  assert.deepEqual([await hit(), await hit(), await hit(), await hit()], [404, 404, 404, 429]);
  /* Subscribing without web push configured is refused plainly. */
  const r = await fetch(`http://127.0.0.1:${server.address().port}/api/outings/watch/subscribe`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: 'A'.repeat(43), subscription: {} }) });
  assert.equal(r.status, 503);
});
