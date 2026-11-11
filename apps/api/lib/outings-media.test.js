'use strict';

/**
 * «قناة الطلعة» — shared YouTube channel state (memory only).
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-media.test.js
 *
 * Pure tests run without a database; the end-to-end test runs in its own
 * database (`<db>_sary_media`) over the real router, real WebSockets and a fake clock.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { parseAction, positionAt, videoId, cleanTitle, QUEUE_MAX } = require('./outings/media');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

/* ---------------- pure ---------------- */

test('media: video id is exactly 11 YouTube characters', () => {
  assert.equal(videoId('dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
  assert.equal(videoId('a-b_c-d_e-f'), 'a-b_c-d_e-f');
  assert.equal(videoId('dQw4w9WgXc'), null, '10 chars');
  assert.equal(videoId('dQw4w9WgXcQQ'), null, '12 chars');
  assert.equal(videoId('dQw4w9WgXc!'), null);
  assert.equal(videoId('https://youtu.be/dQw4w9WgXcQ'), null, 'a URL is not an id — the client extracts it');
  assert.equal(videoId(12345678901), null);
  assert.equal(videoId(undefined), null);
});

test('media: title is display only — cleaned, ≤100, bidi overrides dropped', () => {
  assert.equal(cleanTitle('  أغنية   الطلعة \n'), 'أغنية الطلعة');
  assert.equal(cleanTitle('abc‮def'), 'abcdef');
  assert.equal([...cleanTitle('ي'.repeat(150))].length, 100);
  assert.equal(cleanTitle(undefined), '');
  assert.equal(cleanTitle(42), null);
});

test('media: action parsing', () => {
  assert.deepEqual(parseAction({ action: 'load', video_id: 'dQw4w9WgXcQ', title: 'x' }).value, { action: 'load', video_id: 'dQw4w9WgXcQ', title: 'x' });
  assert.equal(parseAction({ action: 'load', video_id: 'nope' }).reason, 'invalid_video_id');
  assert.equal(parseAction({ action: 'load', video_id: 'dQw4w9WgXcQ', title: {} }).reason, 'invalid_title');
  assert.equal(parseAction({ action: 'queue_add' }).reason, 'invalid_video_id');
  assert.equal(parseAction({ action: 'dance' }).reason, 'invalid_action');
  assert.equal(parseAction(null).reason, 'invalid_action');
  assert.equal(parseAction({ action: 'seek' }).reason, 'invalid_position', 'seek needs a position');
  assert.equal(parseAction({ action: 'seek', position_s: -1 }).reason, 'invalid_position');
  assert.equal(parseAction({ action: 'seek', position_s: '12' }).reason, 'invalid_position');
  assert.equal(parseAction({ action: 'seek', position_s: Infinity }).reason, 'invalid_position');
  assert.equal(parseAction({ action: 'seek', position_s: 25 * 3600 }).reason, 'invalid_position');
  assert.equal(parseAction({ action: 'seek', position_s: 12.3456 }).value.position_s, 12.346);
  assert.equal(parseAction({ action: 'play', rate: 1.5 }).value.rate, 1.5);
  assert.equal(parseAction({ action: 'play', rate: 3 }).reason, 'invalid_rate');
  assert.equal(parseAction({ action: 'pause' }).ok, true);
  assert.equal(parseAction({ action: 'stop' }).ok, true);
  assert.equal(parseAction({ action: 'next' }).ok, true);
});

test('media: position math — position_s + (now − at) × rate while playing', () => {
  const at = 1_000_000;
  assert.equal(positionAt({ playing: true, position_s: 10, rate: 1, at }, at + 5000), 15);
  assert.equal(positionAt({ playing: true, position_s: 10, rate: 2, at }, at + 5000), 20);
  assert.equal(positionAt({ playing: true, position_s: 10, rate: 0.5, at }, at + 5000), 12.5);
  assert.equal(positionAt({ playing: false, position_s: 10, rate: 1, at }, at + 60_000), 10, 'paused: frozen');
  assert.equal(positionAt({ playing: true, position_s: 10, rate: 1, at }, at - 5000), 10, 'a clock going back never rewinds');
  assert.equal(positionAt(null, at), 0);
});

/* ---------------- database ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_media`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('shared channel end to end: roles, events, position math, cleanup', { skip, timeout: 120_000 }, async (t) => {
  const { createPool, migrate } = require('./outings/db');
  const { setupOutings } = require('./outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);

  let offset = 0;
  const now = () => Date.now() + offset;
  const advance = (ms) => { offset += ms; };

  const outings = setupOutings({ pool, autoMigrate: false, now, limits: { identityPerHour: 100, invitePer10Min: 100, deletePerHour: 10 } });
  const app = express();
  app.use(express.json({ limit: '1mb' }));
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
  const until = async (pred, ms = 4000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const x = pred();
      if (x) return x;
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error('timeout');
  };
  function live(token, outingId) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    const inbox = [];
    ws.on('message', (d) => inbox.push(JSON.parse(String(d))));
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    return { ws, inbox, opened, media: () => inbox.filter((m) => m.type === 'media_state') };
  }

  /* A owner, B member, D co-leader, E member, C outsider. */
  const mk = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  const [A, B, C, D, E] = [await mk('أبو فهد'), await mk('سعد'), await mk('غريب'), await mk('مساعد'), await mk('ناصر')];
  const created = await api('POST', '/', A.token, { name: 'طلعة' });
  const O = created.body.outing_id;
  for (const p of [B, D, E]) assert.equal((await api('POST', '/invites/join', p.token, { token: created.body.invite.token })).status, 200);
  assert.equal((await api('POST', `/${O}/members/${D.user.id}/co-leader`, A.token, { co_leader: true })).status, 200);
  assert.equal((await api('POST', `/${O}/status`, A.token, { action: 'start' })).status, 200);

  const la = live(A.token, O);
  await la.opened;
  await until(() => la.inbox.some((m) => m.type === 'ready'));
  assert.equal(la.inbox.find((m) => m.type === 'ready').snapshot.media, null, 'idle in the live snapshot');

  /* --- membership, idle, validation --- */
  assert.equal((await api('GET', `/${O}/media`, C.token)).status, 404, 'outsider');
  assert.equal((await api('POST', `/${O}/media`, C.token, { action: 'load', video_id: 'dQw4w9WgXcQ' })).status, 404);
  assert.equal((await api('GET', `/${O}/media`)).status, 401, 'no token');
  const idle = await api('GET', `/${O}/media`, B.token);
  assert.equal(idle.status, 200);
  assert.equal(idle.body.media, null);
  assert.ok(idle.body.server_now);
  assert.equal((await api('POST', `/${O}/media`, B.token, { action: 'play' })).body.error, 'media_idle');
  assert.equal((await api('POST', `/${O}/media/takeover`, D.token)).body.error, 'media_idle');
  assert.equal((await api('POST', `/${O}/media`, B.token, { action: 'load', video_id: 'https://youtu.be/dQw4w9WgXcQ' })).body.error, 'invalid_video_id');
  assert.equal((await api('POST', `/${O}/media`, B.token, { action: 'load', video_id: 'dQw4w9WgXcQ', position_s: -3 })).body.error, 'invalid_position');

  /* --- anyone may start when idle: B loads and controls --- */
  const loaded = await api('POST', `/${O}/media`, B.token, { action: 'load', video_id: 'dQw4w9WgXcQ', title: '  شيلة   الطلعة ' });
  assert.equal(loaded.status, 200);
  assert.equal(loaded.body.media.controller_user_id, B.user.id);
  assert.equal(loaded.body.media.title, 'شيلة الطلعة');
  assert.equal(loaded.body.media.playing, true);
  assert.ok(loaded.body.media.position_s < 0.5);
  assert.equal(loaded.body.media.rate, 1);
  const ev = await until(() => la.media().at(-1));
  assert.equal(ev.state.video_id, 'dQw4w9WgXcQ', 'media_state reaches other members');
  assert.ok(ev.state.at, 'carries the server time');

  /* --- position math on the server clock --- */
  advance(30_000);
  const p30 = (await api('GET', `/${O}/media`, E.token)).body.media;
  assert.ok(Math.abs(p30.position_s - 30) < 1, `≈30 s after start, got ${p30.position_s}`);
  assert.ok(Math.abs(Date.parse(p30.at) - now()) < 1000, 'at is now');
  await api('POST', `/${O}/media`, B.token, { action: 'play', rate: 2 });
  advance(10_000);
  assert.ok(Math.abs((await api('GET', `/${O}/media`, E.token)).body.media.position_s - 50) < 1.5, 'rate 2: +20 s in 10 s');
  const paused = await api('POST', `/${O}/media`, B.token, { action: 'pause' });
  assert.equal(paused.body.media.playing, false);
  const frozen = paused.body.media.position_s;
  advance(60_000);
  assert.equal((await api('GET', `/${O}/media`, E.token)).body.media.position_s, frozen, 'paused: frozen');
  const sought = await api('POST', `/${O}/media`, B.token, { action: 'seek', position_s: 95.5 });
  assert.equal(sought.body.media.position_s, 95.5, 'paused after seek: exact');
  assert.equal(sought.body.media.playing, false, 'seek keeps pause');
  await api('POST', `/${O}/media`, B.token, { action: 'play', rate: 1 });

  /* --- roles while active --- */
  const n = la.media().length;
  assert.equal((await api('POST', `/${O}/media`, E.token, { action: 'pause' })).status, 403, 'a plain member cannot control');
  assert.equal((await api('POST', `/${O}/media`, E.token, { action: 'load', video_id: 'aaaaaaaaaaa' })).body.error, 'not_controller');
  assert.equal((await api('POST', `/${O}/media`, E.token, { action: 'stop' })).status, 403);
  assert.equal((await api('POST', `/${O}/media/takeover`, E.token)).body.error, 'leader_only');
  assert.equal((await api('POST', `/${O}/media/takeover`, B.token)).body.error, 'leader_only', 'controller is not a leader');
  assert.equal(la.media().length, n, 'refused actions emit nothing');
  assert.equal((await api('POST', `/${O}/media`, D.token, { action: 'pause' })).status, 200, 'a co-leader may control');
  assert.equal((await api('POST', `/${O}/media`, A.token, { action: 'play' })).status, 200, 'the owner may control');
  assert.equal((await api('GET', `/${O}/media`, E.token)).body.media.controller_user_id, B.user.id, 'controlling is not taking over');

  /* --- queue: any member may suggest; ≤20; next plays in order, then stops --- */
  assert.equal((await api('POST', `/${O}/media`, E.token, { action: 'queue_add', video_id: 'bbbbbbbbbbb' })).status, 200);
  assert.equal((await api('POST', `/${O}/media`, B.token, { action: 'queue_add', video_id: 'ccccccccccc' })).status, 200);
  assert.deepEqual((await api('GET', `/${O}/media`, A.token)).body.media.queue, ['bbbbbbbbbbb', 'ccccccccccc']);
  for (let i = 2; i < QUEUE_MAX; i += 1) await api('POST', `/${O}/media`, B.token, { action: 'queue_add', video_id: `q${String(i).padStart(10, '0')}` });
  assert.equal((await api('POST', `/${O}/media`, B.token, { action: 'queue_add', video_id: 'zzzzzzzzzzz' })).body.error, 'queue_full');
  assert.equal((await api('POST', `/${O}/media`, E.token, { action: 'next' })).status, 403, 'next is control');
  const nx = await api('POST', `/${O}/media`, B.token, { action: 'next' });
  assert.equal(nx.body.media.video_id, 'bbbbbbbbbbb');
  assert.ok(nx.body.media.position_s < 0.5);
  assert.equal(nx.body.media.queue.length, QUEUE_MAX - 1);

  /* --- takeover by a co-leader, events --- */
  const tk = await api('POST', `/${O}/media/takeover`, D.token);
  assert.equal(tk.body.media.controller_user_id, D.user.id);
  await until(() => la.media().at(-1).state?.controller_user_id === D.user.id);
  assert.equal((await api('POST', `/${O}/media`, B.token, { action: 'pause' })).status, 403, 'the old controller lost control');

  /* --- snapshots carry it --- */
  assert.equal((await api('GET', `/${O}/live`, E.token)).body.media.video_id, 'bbbbbbbbbbb');
  assert.equal((await api('GET', `/${O}`, E.token)).body.media.controller_user_id, D.user.id);

  /* --- controller leaves → owner takes over --- */
  assert.equal((await api('POST', `/${O}/leave`, D.token)).status, 200);
  await until(() => la.media().at(-1).state?.controller_user_id === A.user.id);
  /* --- owner hands over to E by stopping, E starts, E removed → owner --- */
  await api('POST', `/${O}/media`, A.token, { action: 'stop' });
  await until(() => la.media().at(-1).state === null);
  assert.equal((await api('GET', `/${O}/media`, E.token)).body.media, null);
  await api('POST', `/${O}/media`, E.token, { action: 'load', video_id: 'ddddddddddd' });
  assert.equal((await api('DELETE', `/${O}/members/${E.user.id}`, A.token)).status, 200);
  await until(() => la.media().at(-1).state?.controller_user_id === A.user.id && la.media().at(-1).state.video_id === 'ddddddddddd');

  /* --- next on an empty queue stops --- */
  const st = await api('POST', `/${O}/media`, A.token, { action: 'next' });
  assert.equal(st.body.media, null);

  /* --- owner controller leaves: the heir (B) becomes owner and controller --- */
  await api('POST', `/${O}/media`, A.token, { action: 'load', video_id: 'eeeeeeeeeee' });
  assert.equal((await api('POST', `/${O}/leave`, A.token)).status, 200);
  let m2 = null;
  for (let i = 0; i < 100 && m2?.controller_user_id !== B.user.id; i += 1) {
    m2 = (await api('GET', `/${O}/media`, B.token)).body.media;
    if (m2?.controller_user_id !== B.user.id) await new Promise((r) => setTimeout(r, 20));
  }
  assert.equal(m2?.controller_user_id, B.user.id, 'the new owner inherits the channel');
  assert.equal(m2.video_id, 'eeeeeeeeeee');
  la.ws.close();

  /* --- ending clears it --- */
  assert.equal((await api('POST', `/${O}/status`, B.token, { action: 'end' })).status, 200);
  const ended = await api('GET', `/${O}/media`, B.token);
  assert.equal(ended.body.media, null);
  assert.equal((await api('POST', `/${O}/media`, B.token, { action: 'load', video_id: 'dQw4w9WgXcQ' })).body.error, 'outing_ended');

  /* --- TTL: a channel untouched for 12 h is gone --- */
  const c2 = await api('POST', '/', B.token, { name: 'طلعة ٢' });
  const O2 = c2.body.outing_id;
  await api('POST', `/${O2}/media`, B.token, { action: 'load', video_id: 'dQw4w9WgXcQ' });
  advance(12 * 3600_000 + 1000);
  assert.equal((await api('GET', `/${O2}/media`, B.token)).body.media, null);

  /* --- per-member action limit --- */
  await api('POST', `/${O2}/media`, B.token, { action: 'load', video_id: 'dQw4w9WgXcQ' });
  const codes = [];
  for (let i = 0; i < 65; i += 1) codes.push((await api('POST', `/${O2}/media`, B.token, { action: 'seek', position_s: i })).status);
  assert.ok(codes.includes(429), 'rate limited');
});
