'use strict';

/**
 * «قناة الطلعة» — the live walkie-talkie: floor control, relay fan-out, limits,
 * the APNs `pushtotalk` request (against an h2c stand-in for APNs), and the
 * token routes + live audio over a real Postgres, router and WebSockets.
 *
 *   node --test apps/api/lib/outings-ptt.test.js                       (pure + fake APNs)
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-ptt.test.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const http = require('http');
const http2 = require('http2');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { createPttRelay } = require('./outings/ptt');
const { createHub } = require('./outings/hub');
const { pttRequestFor, parsePttRegistration, createApnsSender, createApnsNotifier, apnsConfigFromEnv } = require('./outings/apns');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const OUTING = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- relay with fake sockets ---------------- */

function fakeWs() {
  return {
    readyState: 1,
    bufferedAmount: 0,
    json: [],
    bin: [],
    send(data, opts) {
      if (opts?.binary) this.bin.push(Buffer.from(data));
      else this.json.push(JSON.parse(data));
    },
    close() {
      this.readyState = 3;
    },
  };
}

function setup(options = {}, { apns = null, membership } = {}) {
  const hub = createHub();
  const service = { membership: membership || (async () => ({ status: 'active', outing_status: 'active' })) };
  const ptt = createPttRelay({ hub, service, apns, options: { maxTalkMs: 400, silenceMs: 150, ...options }, log: () => {} });
  let n = 0;
  const conn = (userId, outingId = OUTING, name = userId) => {
    const c = { ws: fakeWs(), userId, user: { id: userId, display_name: name }, outingId: null, window: [] };
    hub.join(outingId, c);
    n += 1;
    return c;
  };
  return { hub, ptt, conn };
}

const frame = (burst, seq = 0, bytes = 60) => {
  const b = Buffer.alloc(4 + bytes, 7);
  b[0] = 1;
  b[1] = burst;
  b.writeUInt16BE(seq, 2);
  return b;
};
const last = (c, type) => c.ws.json.filter((m) => m.type === type).at(-1);

test('floor: grant to the first, deny «busy» to the second, release on stop', async () => {
  const { ptt, conn } = setup();
  const a = conn('A', OUTING, 'فهد');
  const b = conn('B');
  await ptt.handle(a, { type: 'ptt_join' });
  await ptt.handle(b, { type: 'ptt_join' });
  assert.deepEqual(last(a, 'ptt_state'), { type: 'ptt_state', talker: null, max_ms: 400, channel: '1' }, 'an old client is on «تردد ١» (the field is additive)');

  await ptt.handle(a, { type: 'ptt_start', id: 1 });
  const g = last(a, 'ptt_grant');
  assert.equal(g.id, 1);
  assert.equal(g.burst, 1);
  const talker = last(b, 'ptt_talker');
  assert.equal(talker.user_id, 'A');
  assert.equal(talker.name, 'فهد');
  assert.equal(a.ws.json.some((m) => m.type === 'ptt_talker'), false, 'the talker is not told about themselves');

  await ptt.handle(b, { type: 'ptt_start', id: 9 });
  assert.deepEqual(last(b, 'ptt_deny'), { type: 'ptt_deny', id: 9, reason: 'busy', talker_id: 'A' });

  await ptt.handle(a, { type: 'ptt_start', id: 2 });
  assert.equal(last(a, 'ptt_grant').burst, 1, 'asking again while holding keeps the same burst');

  await ptt.handle(a, { type: 'ptt_stop' });
  assert.equal(last(b, 'ptt_idle').reason, 'released');
  assert.equal(last(a, 'ptt_idle').reason, 'released');
  await ptt.handle(b, { type: 'ptt_start', id: 10 });
  assert.equal(last(b, 'ptt_grant').burst, 2, 'a new burst number per transmission');
});

test('floor: not joined → denied; a removed member → not_allowed; stop by a non-holder is ignored', async () => {
  const { ptt, conn } = setup({}, { membership: async (_o, uid) => (uid === 'X' ? { status: 'left', outing_status: 'active' } : { status: 'active', outing_status: 'active' }) });
  const a = conn('A');
  const x = conn('X');
  await ptt.handle(a, { type: 'ptt_start', id: 1 });
  assert.equal(last(a, 'ptt_deny').reason, 'not_joined');
  await ptt.handle(x, { type: 'ptt_join' });
  await ptt.handle(x, { type: 'ptt_start', id: 1 });
  assert.equal(last(x, 'ptt_deny').reason, 'not_allowed');
  await ptt.handle(a, { type: 'ptt_join' });
  await ptt.handle(a, { type: 'ptt_start' });
  await ptt.handle(x, { type: 'ptt_stop' });
  assert.equal(ptt.state(OUTING).user_id, 'A', 'only the holder can release');
});

test('floor: max duration and silence timeouts release it', async () => {
  const { ptt, conn } = setup({ maxTalkMs: 250, silenceMs: 120 });
  const a = conn('A');
  const b = conn('B');
  await ptt.handle(a, { type: 'ptt_join' });
  await ptt.handle(b, { type: 'ptt_join' });

  /* Silence: no frames for silenceMs. */
  await ptt.handle(a, { type: 'ptt_start' });
  await sleep(180);
  assert.equal(last(b, 'ptt_idle').reason, 'silence');
  assert.equal(ptt.state(OUTING), null);

  /* Max duration: keep sending frames past maxTalkMs. */
  await ptt.handle(a, { type: 'ptt_start' });
  const burst = last(a, 'ptt_grant').burst;
  for (let i = 0; i < 8; i++) {
    ptt.audio(a, frame(burst, i));
    await sleep(40);
  }
  assert.equal(last(b, 'ptt_idle').reason, 'max_duration');
  assert.equal(last(a, 'ptt_idle').reason, 'max_duration', 'the talker learns it was cut off');
  assert.equal(ptt.audio(a, frame(burst, 99)), false, 'frames after the cut are dropped');
});

test('relay: to joined members of the same outing only — never the sender, a muted member or another outing', async () => {
  const { ptt, conn } = setup();
  const a1 = conn('A');
  const a2 = conn('A'); // the talker's second device
  const b = conn('B');
  const muted = conn('M');
  const never = conn('N'); // in the room, never joined the channel
  const other = conn('O', OTHER);
  for (const c of [a1, a2, b, muted, other]) await ptt.handle(c, { type: 'ptt_join' });
  await ptt.handle(muted, { type: 'ptt_leave' });
  await ptt.handle(a1, { type: 'ptt_start' });
  const burst = last(a1, 'ptt_grant').burst;
  const f = frame(burst, 1);
  assert.equal(ptt.audio(a1, f), true);
  assert.deepEqual(b.ws.bin, [f], 'byte for byte');
  for (const [c, why] of [[a1, 'sender'], [a2, "sender's other device"], [muted, 'muted'], [never, 'not joined'], [other, 'other outing']]) {
    assert.equal(c.ws.bin.length, 0, why);
  }
  assert.equal(other.ws.json.some((m) => m.type === 'ptt_talker'), false, 'another outing never hears of it');
  assert.equal(muted.ws.json.some((m) => m.type === 'ptt_talker'), false);

  /* Not the floor holder → dropped. */
  assert.equal(ptt.audio(b, frame(burst, 2)), false);
  assert.equal(b.ws.bin.length, 1);
});

test('limits: version, burst, frame size, frames/s and bytes/s; floor requests per minute', async () => {
  const { ptt, conn } = setup({ maxFramesPerSec: 10, maxBytesPerSec: 100_000, maxStartsPerMin: 3, silenceMs: 2000, maxTalkMs: 5000 });
  const a = conn('A');
  const b = conn('B');
  await ptt.handle(a, { type: 'ptt_join' });
  await ptt.handle(b, { type: 'ptt_join' });
  await ptt.handle(a, { type: 'ptt_start' });
  const burst = last(a, 'ptt_grant').burst;

  const bad = frame(burst);
  bad[0] = 2;
  assert.equal(ptt.audio(a, bad), false, 'unknown version');
  assert.equal(ptt.audio(a, frame((burst % 255) + 1)), false, 'stale / wrong burst');
  assert.equal(ptt.audio(a, Buffer.from([1, burst, 0, 0])), false, 'header only');
  assert.equal(ptt.audio(a, frame(burst, 0, 1197)), false, 'over 1200 bytes');
  assert.equal(ptt.audio(a, frame(burst, 0, 1196)), true, 'exactly 1200 bytes');
  let ok = 1;
  for (let i = 0; i < 20; i++) ok += ptt.audio(a, frame(burst, i)) ? 1 : 0;
  assert.equal(ok, 10, 'frames per second capped');
  assert.equal(b.ws.bin.length, 10);

  /* A slow listener skips frames instead of buffering without end. */
  await sleep(1050);
  b.ws.bufferedAmount = 1e6;
  assert.equal(ptt.audio(a, frame(burst, 50)), true, 'accepted from the talker');
  assert.equal(b.ws.bin.length, 10, 'not queued to the lagging socket');
  b.ws.bufferedAmount = 0;
  await ptt.handle(a, { type: 'ptt_stop' });

  /* 3 starts per minute in this config (granted once above). */
  await ptt.handle(a, { type: 'ptt_start' });
  await ptt.handle(a, { type: 'ptt_stop' });
  await ptt.handle(a, { type: 'ptt_start' });
  await ptt.handle(a, { type: 'ptt_stop' });
  await ptt.handle(a, { type: 'ptt_start', id: 'x' });
  assert.equal(last(a, 'ptt_deny').reason, 'rate_limited');

  const { ptt: p2, conn: c2 } = setup({ maxBytesPerSec: 500, maxFramesPerSec: 100, silenceMs: 2000 });
  const t = c2('T');
  await p2.handle(t, { type: 'ptt_join' });
  await p2.handle(t, { type: 'ptt_start' });
  const bb = last(t, 'ptt_grant').burst;
  let n = 0;
  for (let i = 0; i < 10; i++) n += p2.audio(t, frame(bb, i, 96)) ? 1 : 0;
  assert.equal(n, 5, 'bytes per second capped (5 × 100 B)');
  p2.close();
});

test('a phone that joins mid-sentence gets the current talker and the last few seconds; a closed socket frees the floor', async () => {
  const { ptt, conn } = setup({ catchUpFrames: 3, silenceMs: 2000, maxTalkMs: 5000 });
  const a = conn('A');
  await ptt.handle(a, { type: 'ptt_join' });
  await ptt.handle(a, { type: 'ptt_start' });
  const burst = last(a, 'ptt_grant').burst;
  const frames = [0, 1, 2, 3, 4].map((i) => frame(burst, i));
  for (const f of frames) ptt.audio(a, f);
  const late = conn('L');
  await ptt.handle(late, { type: 'ptt_join' });
  assert.equal(last(late, 'ptt_state').talker.user_id, 'A');
  assert.deepEqual(late.ws.bin, frames.slice(2), 'only the newest 3, in order');

  ptt.drop(a); // the ws close handler
  assert.equal(last(late, 'ptt_idle').reason, 'left');
  assert.equal(ptt.state(OUTING), null);
  const again = conn('Z');
  await ptt.handle(again, { type: 'ptt_join' });
  assert.equal(again.ws.bin.length, 0, 'the catch-up buffer went with the transmission');
});

test('push: wakes members not listening live (away or offline), never the talker or a foreground listener', async () => {
  const calls = [];
  const apns = { enabled: true, notifyPtt: async (outingId, talker, opts) => (calls.push({ outingId, talker, ...opts }), { sent: 1 }) };
  const { hub, ptt, conn } = setup({}, { apns });
  const a = conn('A', OUTING, 'فهد');
  const b = conn('B');
  const c = conn('C');
  for (const x of [a, b, c]) await ptt.handle(x, { type: 'ptt_join' });
  hub.setAway(OUTING, 'C', true);
  await ptt.handle(a, { type: 'ptt_start' });
  await sleep(5);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, 'فهد');
  assert.deepEqual([...calls[0].skipUsers].sort(), ['A', 'B'], 'C is in the background: woken');
});

/* ---------------- APNs pushtotalk request ---------------- */

test('pushtotalk request: headers and payload as Apple documents them', () => {
  const r = pttRequestFor({ outingId: OUTING, talkerId: 'u1', name: 'فهد', burst: 7 }, { bundleId: 'sa.sary.albarq' });
  assert.deepEqual(r.headers, {
    'apns-push-type': 'pushtotalk',
    'apns-priority': '10',
    'apns-expiration': '0',
    'apns-topic': 'sa.sary.albarq.voip-ptt',
  });
  const body = JSON.parse(r.body);
  assert.deepEqual(body.aps, {}, 'no alert, no sound: the system shows its own PTT UI');
  assert.equal(body.activeSpeaker, 'فهد');
  assert.equal(body.outing_id, OUTING);
  assert.equal(body.burst, 7);
  assert.ok(!/lat|lng/.test(r.body), 'no position');
  assert.ok(Buffer.byteLength(JSON.parse(pttRequestFor({ name: 'ف'.repeat(500) }).body).activeSpeaker) <= 120);
});

test('ptt token registration: hex token + environment', () => {
  assert.deepEqual(parsePttRegistration({ token: 'AB'.repeat(32), environment: 'sandbox' }), { token: 'ab'.repeat(32), environment: 'sandbox', voice_notes: false });
  assert.equal(parsePttRegistration({ token: 'ab'.repeat(32), environment: 'sandbox', voice_notes: true }).voice_notes, true);
  assert.equal(parsePttRegistration({ token: 'xyz', environment: 'sandbox' }).error, 'invalid_token');
  assert.equal(parsePttRegistration({ token: 'ab'.repeat(32), environment: 'dev' }).error, 'invalid_environment');
  assert.equal(parsePttRegistration(null).error, 'invalid_token');
});

async function fakeApns(t, reply = () => ({ status: 200 })) {
  const seen = [];
  const server = http2.createServer();
  server.on('stream', (stream, headers) => {
    let body = '';
    stream.setEncoding('utf8');
    stream.on('data', (c) => (body += c));
    stream.on('end', () => {
      const rec = { headers, body: JSON.parse(body), token: headers[':path'].split('/').pop() };
      seen.push(rec);
      const r = reply(rec);
      stream.respond({ ':status': r.status, ...(r.reason ? { 'content-type': 'application/json' } : {}) });
      stream.end(r.reason ? JSON.stringify({ reason: r.reason }) : undefined);
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  return { seen, origin: `http://127.0.0.1:${server.address().port}` };
}

test('notifyPtt over HTTP/2: pushtotalk headers on the wire, skips listeners, deletes dead tokens', async (t) => {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const ENV = { APNS_KEY_ID: 'ABC123DEFG', APNS_TEAM_ID: 'MH7J92HV9N', APNS_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }), APNS_BUNDLE_ID: 'sa.sary.albarq' };
  const GONE = 'c'.repeat(64);
  const apns = await fakeApns(t, (rec) => (rec.token === GONE ? { status: 410, reason: 'Unregistered' } : { status: 200 }));
  const config = apnsConfigFromEnv(ENV);
  const sender = createApnsSender(config, { origins: { production: apns.origin, sandbox: apns.origin } });
  t.after(() => sender.close());
  const calls = [];
  const rows = [
    { id: 'r1', user_id: 'B', token: 'b'.repeat(64), environment: 'sandbox' },
    { id: 'r2', user_id: 'C', token: GONE, environment: 'production' },
    { id: 'r3', user_id: 'D', token: 'd'.repeat(64), environment: 'sandbox' },
  ];
  const pool = {
    query: async (text, params) => {
      calls.push({ text: text.replace(/\s+/g, ' ').trim(), params });
      return { rows: /FROM sary\.ptt_tokens t/.test(text) ? rows : [] };
    },
  };
  const n = createApnsNotifier({ pool, config, sender, info: () => {}, log: () => {} });
  const r = await n.notifyPtt(OUTING, '00000000-0000-4000-8000-00000000000a', { name: 'فهد', burst: 3, skipUsers: new Set(['D']) });
  assert.deepEqual({ ...r, users: [...r.users] }, { sent: 1, removed: 1, failed: 0, skipped: 1, users: ['B'] });
  assert.equal(apns.seen.length, 2);
  for (const s of apns.seen) {
    assert.equal(s.headers['apns-push-type'], 'pushtotalk');
    assert.equal(s.headers['apns-topic'], 'sa.sary.albarq.voip-ptt');
    assert.equal(s.headers['apns-priority'], '10');
    assert.equal(s.headers['apns-expiration'], '0');
    assert.match(s.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    assert.equal(s.body.activeSpeaker, 'فهد');
  }
  assert.ok(!apns.seen.some((s) => s.token === 'd'.repeat(64)), 'a live listener is not woken');
  const sel = calls.find((c) => /FROM sary\.ptt_tokens t/.test(c.text));
  assert.match(sel.text, /m\.status = 'active'/);
  assert.match(sel.text, /o\.status <> 'ended'/);
  assert.match(sel.text, /t\.user_id <> \$2::uuid/, 'never the talker');
  assert.deepEqual(calls.find((c) => /^DELETE FROM sary\.ptt_tokens WHERE id = ANY/.test(c.text)).params, [['r2']]);
});

/* ---------------- database: token routes + live audio over real WebSockets ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_ptt`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('ptt end to end: token routes, live relay over the outing socket, pushtotalk wake-ups', { skip, timeout: 60_000 }, async (t) => {
  const { createPool, migrate } = require('./outings/db');
  const { setupOutings } = require('./outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);
  const apnsInbox = [];
  const outings = setupOutings({
    pool,
    autoMigrate: false,
    config: { minFixIntervalMs: 0, persistEveryMs: 0 },
    limits: { identityPerHour: 100, invitePer10Min: 100 },
    ptt: { silenceMs: 1500, maxTalkMs: 5000 },
    apns: {
      config: { enabled: true, bundleId: 'sa.sary.albarq', key: {} },
      sender: { async send(device, req) { apnsInbox.push({ token: device.token, headers: req.headers, body: JSON.parse(req.body) }); return { status: 200 }; } },
    },
  });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  outings.attach(server);
  const port = server.address().port;
  t.after(async () => {
    await outings.close();
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
  function live(token, outingId) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    const inbox = [];
    const bin = [];
    ws.on('message', (d, isBinary) => (isBinary ? bin.push(Buffer.from(d)) : inbox.push(JSON.parse(String(d)))));
    const next = async (pred, ms = 3000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const i = inbox.findIndex(pred);
        if (i >= 0) return inbox.splice(i, 1)[0];
        await sleep(15);
      }
      throw new Error('timeout waiting for message');
    };
    const closed = new Promise((r) => ws.on('close', (code) => r(code)));
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    return { ws, inbox, bin, next, opened, closed, send: (m) => ws.send(JSON.stringify(m)) };
  }
  const until = async (pred, ms = 3000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (pred()) return;
      await sleep(15);
    }
    throw new Error('timeout');
  };
  const hex = () => crypto.randomBytes(32).toString('hex');

  const mk = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  const [A, B, C, D, E] = [await mk('فهد'), await mk('سعد'), await mk('غريب'), await mk('نورة'), await mk('ريم')];
  const created = await api('POST', '/', A.token, { name: 'طلعة النفود' });
  const O = created.body.outing_id;
  for (const p of [B, D, E]) assert.equal((await api('POST', '/invites/join', p.token, { token: created.body.invite.token })).status, 200);
  await api('POST', `/${O}/status`, A.token, { action: 'start' });

  /* ---- token routes ---- */
  const tok = { B: hex(), D: hex(), E: hex() };
  assert.equal((await api('POST', `/${O}/ptt/token`, null, { token: tok.B, environment: 'sandbox' })).status, 401);
  assert.equal((await api('POST', `/${O}/ptt/token`, C.token, { token: hex(), environment: 'sandbox' })).status, 404, 'outsider');
  assert.equal((await api('POST', `/${O}/ptt/token`, B.token, { token: 'zz', environment: 'sandbox' })).body.error, 'invalid_token');
  assert.equal((await api('POST', `/${O}/ptt/token`, B.token, { token: tok.B, environment: 'prod' })).body.error, 'invalid_environment');
  for (const n of ['B', 'D', 'E']) assert.equal((await api('POST', `/${O}/ptt/token`, { B, D, E }[n].token, { token: tok[n], environment: 'sandbox' })).status, 201);
  assert.equal((await api('POST', `/${O}/ptt/token`, B.token, { token: tok.B, environment: 'sandbox' })).status, 201, 'idempotent');
  for (let i = 0; i < 4; i++) await api('POST', `/${O}/ptt/token`, D.token, { token: hex(), environment: 'sandbox' });
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.ptt_tokens WHERE user_id = $1', [D.user.id])).rows[0].n, 3, 'oldest dropped past 3 per outing');
  assert.equal((await pool.query('SELECT 1 FROM sary.ptt_tokens WHERE token = $1', [tok.D])).rows.length, 0);
  assert.equal((await api('DELETE', `/${O}/ptt/token`, C.token, {})).status, 404, 'outsider cannot delete');
  assert.deepEqual((await api('DELETE', `/${O}/ptt/token`, D.token, {})).body, { ok: true, removed: 3 }, '«اكتم القناة»: all my tokens for this outing');
  tok.D = hex();
  await api('POST', `/${O}/ptt/token`, D.token, { token: tok.D, environment: 'sandbox' });

  /* ---- live: A talks; B listens live; E is in the background; D is offline; C cannot get in ---- */
  const la = live(A.token, O);
  const lb = live(B.token, O);
  const le = live(E.token, O);
  const lc = live(C.token, O);
  await Promise.all([la.opened, lb.opened, le.opened, lc.opened]);
  assert.equal(await lc.closed, 4404, 'outsider socket refused');
  for (const l of [la, lb, le]) {
    await l.next((m) => m.type === 'ready');
    l.send({ type: 'ptt_join' });
    assert.deepEqual(await l.next((m) => m.type === 'ptt_state'), { type: 'ptt_state', talker: null, max_ms: 5000, channel: '1' });
  }
  le.send({ type: 'presence', away: true });
  await sleep(100);

  la.send({ type: 'ptt_start', id: 1 });
  const grant = await la.next((m) => m.type === 'ptt_grant');
  assert.equal(grant.id, 1);
  const tb = await lb.next((m) => m.type === 'ptt_talker');
  assert.equal(tb.user_id, A.user.id);
  assert.equal(tb.name, 'فهد');
  lb.send({ type: 'ptt_start', id: 2 });
  assert.equal((await lb.next((m) => m.type === 'ptt_deny')).reason, 'busy');

  const frames = [0, 1, 2].map((i) => {
    const f = Buffer.alloc(84, i + 1);
    f[0] = 1;
    f[1] = grant.burst;
    f.writeUInt16BE(i, 2);
    return f;
  });
  for (const f of frames) la.ws.send(f);
  await until(() => lb.bin.length === 3 && le.bin.length === 3);
  assert.deepEqual(lb.bin, frames, 'relayed byte for byte, in order');
  assert.equal(la.bin.length, 0, 'never back to the talker');

  /* Push: D (offline) and E (background) are woken; B (foreground, joined) is not. */
  await until(() => apnsInbox.length === 2);
  assert.deepEqual(apnsInbox.map((x) => x.token).sort(), [tok.D, tok.E].sort());
  for (const p of apnsInbox) {
    assert.equal(p.headers['apns-push-type'], 'pushtotalk');
    assert.equal(p.headers['apns-topic'], 'sa.sary.albarq.voip-ptt');
    assert.equal(p.body.activeSpeaker, 'فهد');
  }

  /* D wakes up mid-sentence: catches up from the start of this transmission. */
  const ld = live(D.token, O);
  await ld.opened;
  await ld.next((m) => m.type === 'ready');
  ld.send({ type: 'ptt_join' });
  assert.equal((await ld.next((m) => m.type === 'ptt_state')).talker.user_id, A.user.id);
  await until(() => ld.bin.length === 3);
  assert.deepEqual(ld.bin, frames);

  /* Mute: B leaves the channel and hears nothing more. */
  lb.send({ type: 'ptt_leave' });
  await sleep(80);
  la.ws.send(frames[0]);
  await until(() => le.bin.length === 4);
  assert.equal(lb.bin.length, 3, 'muted');

  /* Text-only before auth: binary from an unauthenticated socket closes it. */
  const raw = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
  await new Promise((r) => raw.on('open', r));
  raw.send(frames[0]);
  assert.equal(await new Promise((r) => raw.on('close', (c) => r(c))), 1003);

  la.send({ type: 'ptt_stop' });
  assert.equal((await le.next((m) => m.type === 'ptt_idle')).reason, 'released');

  /* Silence timeout over the real socket. */
  la.send({ type: 'ptt_start', id: 3 });
  await la.next((m) => m.type === 'ptt_grant');
  assert.equal((await le.next((m) => m.type === 'ptt_idle', 4000)).reason, 'silence');

  /* E leaves the outing: token gone, no more wake-ups, and a talker's socket closing frees the floor. */
  assert.equal((await api('POST', `/${O}/leave`, E.token)).status, 200);
  assert.equal((await pool.query('SELECT 1 FROM sary.ptt_tokens WHERE outing_id = $1 AND user_id = $2', [O, E.user.id])).rows.length, 0);
  ld.send({ type: 'ptt_start', id: 4 });
  await ld.next((m) => m.type === 'ptt_grant');
  ld.ws.close();
  assert.equal((await la.next((m) => m.type === 'ptt_idle' && m.user_id === D.user.id)).reason, 'left');

  /* The live relay keeps no audio in the database (only «رسالة صوتية» notes, migration 015, are stored). */
  const cols = (await pool.query(`SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'sary' AND data_type = 'bytea'`)).rows;
  assert.ok(!cols.some((c) => /ptt/.test(c.table_name) && c.table_name !== 'ptt_voice_notes'), 'the PTT table holds tokens only');

  /* Ending the outing drops every PTT token. */
  await api('POST', `/${O}/status`, A.token, { action: 'end' });
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.ptt_tokens WHERE outing_id = $1', [O])).rows[0].n, 0);
  for (const l of [la, lb]) l.ws.close();
});
