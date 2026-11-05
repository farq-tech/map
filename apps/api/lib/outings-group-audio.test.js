'use strict';

/**
 * «إذاعة الطلعة» — shared trip audio state.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-group-audio.test.js
 *
 * Pure tests run without a database; the end-to-end test runs in its own
 * database (`<db>_sary_group_audio`) over the real router, real WebSockets and a fake clock.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { parseCommand, parseItem, positionAt, mayControl, QUEUE_MAX } = require('./outings/group-audio');
const { STATIONS, station, quranUrl, audiusId, catalog } = require('./outings/group-audio-catalog');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const QURAN = 'https://cdn.mp3quran.net/audio/abdulrahman-sudais/r1/001.mp3';

/* ---------------- pure ---------------- */

test('catalog: https only, unique ids, Quran radio from Makkah first', () => {
  assert.ok(STATIONS.length >= 8);
  assert.equal(new Set(STATIONS.map((s) => s.id)).size, STATIONS.length);
  for (const s of STATIONS) {
    assert.match(s.url, /^https:\/\//, s.id);
    assert.ok(s.name && s.homepage, s.id);
  }
  assert.equal(STATIONS[0].id, 'sba-quran');
  assert.equal(station('nope'), null);
  assert.equal(station(undefined), null);
  assert.deepEqual(Object.keys(catalog()[0]).sort(), ['group', 'homepage', 'id', 'name', 'subtitle', 'url']);
});

test('items: a station URL always comes from the catalog, never the phone', () => {
  const r = parseItem({ source: 'radio', id: 'sba-quran', url: 'https://evil.example/x.mp3', title: 'x' });
  assert.equal(r.item.url, station('sba-quran').url);
  assert.equal(r.item.title, 'إذاعة القرآن الكريم');
  assert.equal(r.item.live, true);
  assert.equal(parseItem({ source: 'radio', id: 'evil' }).reason, 'unknown_station');
  assert.equal(parseItem({ source: 'spotify', id: 'x' }).reason, 'invalid_source');
  assert.equal(parseItem(null).reason, 'invalid_source');
});

test('items: Quran only from mp3quran.net, Audius ids only', () => {
  assert.equal(quranUrl(QURAN), QURAN);
  assert.equal(quranUrl('https://server8.mp3quran.net/afs/002.mp3'), 'https://server8.mp3quran.net/afs/002.mp3');
  assert.equal(quranUrl('http://cdn.mp3quran.net/audio/a/r1/001.mp3'), null, 'https only');
  assert.equal(quranUrl('https://cdn.mp3quran.net.evil.com/audio/a/r1/001.mp3'), null);
  assert.equal(quranUrl('https://cdn.mp3quran.net/audio/a/r1/001.mp3?x=1'), null);
  assert.equal(parseItem({ source: 'quran', url: QURAN, title: ' سورة   الفاتحة ', subtitle: 'السديس', duration_s: 50 }).item.title, 'سورة الفاتحة');
  assert.equal(parseItem({ source: 'quran', url: 'https://x.com/1.mp3' }).reason, 'invalid_url');
  assert.equal(parseItem({ source: 'quran', url: QURAN, duration_s: -1 }).reason, 'invalid_duration');
  assert.equal(audiusId('1AXEE'), '1AXEE');
  assert.equal(audiusId('../x'), null);
  assert.equal(parseItem({ source: 'audius', id: '1AXEE', title: 'Oud', subtitle: 'Andros', duration_s: 337 }).item.url, null, 'the phone resolves the stream');
  assert.equal(parseItem({ source: 'audius', id: 'a/b' }).reason, 'invalid_track');
  assert.equal(parseItem({ source: 'audius', id: 'ab', title: {} }).reason, 'invalid_title');
});

test('commands: parsing', () => {
  assert.equal(parseCommand({ action: 'play_item', item: { source: 'radio', id: 'mbc-fm' } }).value.item.id, 'mbc-fm');
  assert.equal(parseCommand({ action: 'play_item' }).reason, 'invalid_source');
  assert.equal(parseCommand({ action: 'dance' }).reason, 'invalid_action');
  assert.equal(parseCommand(null).reason, 'invalid_action');
  assert.equal(parseCommand({ action: 'seek' }).reason, 'invalid_position');
  assert.equal(parseCommand({ action: 'seek', position_s: '3' }).reason, 'invalid_position');
  assert.equal(parseCommand({ action: 'seek', position_s: 12.34567 }).value.position_s, 12.346);
  assert.equal(parseCommand({ action: 'allow_all' }).reason, 'invalid_value');
  assert.equal(parseCommand({ action: 'allow_all', value: true }).value.value, true);
  for (const a of ['play', 'pause', 'next', 'stop']) assert.equal(parseCommand({ action: a }).ok, true, a);
});

test('position math: live radio has none; files run on the server clock and stop at the end', () => {
  const at = 1_000_000;
  const file = { source: 'quran', live: false, duration_s: 100 };
  assert.equal(positionAt({ item: file, playing: true, position_s: 10, at }, at + 5000), 15);
  assert.equal(positionAt({ item: file, playing: false, position_s: 10, at }, at + 60_000), 10, 'paused: frozen');
  assert.equal(positionAt({ item: file, playing: true, position_s: 10, at }, at - 5000), 10, 'a clock going back never rewinds');
  assert.equal(positionAt({ item: file, playing: true, position_s: 90, at }, at + 60_000), 100, 'clamped to the duration');
  assert.equal(positionAt({ item: { live: true }, playing: true, position_s: 0, at }, at + 60_000), 0);
  assert.equal(positionAt(null, at), 0);
});

test('permission: leaders always; members only with «الكل يقدر يشغّل»', () => {
  assert.equal(mayControl({ leads: true, allowAll: false }), true);
  assert.equal(mayControl({ leads: false, allowAll: false }), false);
  assert.equal(mayControl({ leads: false, allowAll: true }), true);
  assert.equal(mayControl({}), false);
});

/* ---------------- database ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_group_audio`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('group audio end to end: permissions, state, ws, late join, restart, cleanup', { skip, timeout: 120_000 }, async (t) => {
  const { createPool, migrate } = require('./outings/db');
  const { setupOutings } = require('./outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);

  let offset = 0;
  const now = () => Date.now() + offset;
  const advance = (ms) => { offset += ms; };
  const limits = { identityPerHour: 100, invitePer10Min: 100, deletePerHour: 10 };

  async function boot() {
    const outings = setupOutings({ pool, autoMigrate: false, now, limits });
    const app = express();
    app.use(express.json({ limit: '1mb' }));
    app.use('/api/outings', outings.router);
    const server = http.createServer(app);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    outings.attach(server);
    return { outings, server, port: server.address().port };
  }
  let srv = await boot();
  t.after(async () => {
    srv.outings.close();
    await new Promise((r) => srv.server.close(r));
    await pool.end();
  });
  const api = async (method, path, token, body) => {
    const res = await fetch(`http://127.0.0.1:${srv.port}/api/outings${path}`, {
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
    const ws = new WebSocket(`ws://127.0.0.1:${srv.port}/api/outings/live`);
    const inbox = [];
    ws.on('message', (d) => inbox.push(JSON.parse(String(d))));
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    return { ws, inbox, opened, ga: () => inbox.filter((m) => m.type === 'group_audio_state') };
  }
  const cmd = (token, O, body) => api('POST', `/${O}/group-audio`, token, body);
  const radio = (id) => ({ action: 'play_item', item: { source: 'radio', id } });

  /* A owner, B member, D co-leader, C outsider, L joins late. */
  const mk = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  const [A, B, C, D, L] = [await mk('أبو فهد'), await mk('سعد'), await mk('غريب'), await mk('مساعد'), await mk('متأخر')];
  const created = await api('POST', '/', A.token, { name: 'طلعة' });
  const O = created.body.outing_id;
  for (const p of [B, D]) assert.equal((await api('POST', '/invites/join', p.token, { token: created.body.invite.token })).status, 200);
  assert.equal((await api('POST', `/${O}/members/${D.user.id}/co-leader`, A.token, { co_leader: true })).status, 200);
  assert.equal((await api('POST', `/${O}/status`, A.token, { action: 'start' })).status, 200);

  /* --- catalog is public, cacheable --- */
  const cat = await api('GET', '/group-audio/catalog');
  assert.equal(cat.status, 200);
  assert.equal(cat.body.stations[0].id, 'sba-quran');

  const lb = live(B.token, O);
  await lb.opened;
  const ready = await until(() => lb.inbox.find((m) => m.type === 'ready'));
  assert.equal(ready.snapshot.group_audio.item, null, 'idle in the live snapshot');
  assert.equal(ready.snapshot.group_audio.allow_all, false);

  /* --- membership, validation, idle --- */
  assert.equal((await api('GET', `/${O}/group-audio`, C.token)).status, 404, 'outsider');
  assert.equal((await cmd(C.token, O, radio('sba-quran'))).status, 404);
  assert.equal((await api('GET', `/${O}/group-audio`)).status, 401, 'no token');
  const idle = await api('GET', `/${O}/group-audio`, B.token);
  assert.equal(idle.body.group_audio.item, null);
  assert.equal(idle.body.can_control, false);
  assert.ok(idle.body.server_now);
  assert.equal((await cmd(A.token, O, { action: 'pause' })).body.error, 'audio_idle');
  assert.equal((await cmd(A.token, O, radio('evil'))).body.error, 'unknown_station');

  /* --- a plain member cannot start; the leader can --- */
  assert.equal((await cmd(B.token, O, radio('mbc-fm'))).body.error, 'not_allowed');
  const n0 = lb.ga().length;
  const started = await cmd(A.token, O, radio('sba-quran'));
  assert.equal(started.status, 200);
  assert.equal(started.body.group_audio.item.url, 'https://live.kwikmotion.com/sbrksaquranradiolive/ksaquranradio/chunks.m3u8');
  assert.equal(started.body.group_audio.by, A.user.id);
  assert.equal(started.body.group_audio.playing, true);
  const ev = await until(() => lb.ga().length > n0 && lb.ga().at(-1));
  assert.equal(ev.state.item.id, 'sba-quran', 'group_audio_state reaches members');
  assert.ok(ev.server_now);
  assert.equal((await cmd(B.token, O, { action: 'pause' })).status, 403, 'member: no control');
  assert.equal((await cmd(B.token, O, { action: 'allow_all', value: true })).body.error, 'leader_only');
  assert.equal((await cmd(D.token, O, { action: 'pause' })).status, 200, 'co-leader controls');
  assert.equal((await cmd(D.token, O, { action: 'seek', position_s: 10 })).body.error, 'live_stream');

  /* --- «الكل يقدر يشغّل» --- */
  assert.equal((await cmd(A.token, O, { action: 'allow_all', value: true })).body.group_audio.allow_all, true);
  assert.equal((await api('GET', `/${O}/group-audio`, B.token)).body.can_control, true);
  const quran = await cmd(B.token, O, { action: 'play_item', item: { source: 'quran', url: QURAN, title: 'الفاتحة', subtitle: 'السديس', duration_s: 600 } });
  assert.equal(quran.status, 200, 'member may play with allow_all');
  assert.equal(quran.body.group_audio.by, B.user.id);

  /* --- position math on the server clock --- */
  advance(30_000);
  const p30 = (await api('GET', `/${O}/group-audio`, D.token)).body.group_audio;
  assert.ok(Math.abs(p30.position_s - 30) < 1, `≈30 s, got ${p30.position_s}`);
  const paused = await cmd(B.token, O, { action: 'pause' });
  const frozen = paused.body.group_audio.position_s;
  advance(60_000);
  assert.equal((await api('GET', `/${O}/group-audio`, D.token)).body.group_audio.position_s, frozen, 'paused: frozen');
  assert.equal((await cmd(B.token, O, { action: 'seek', position_s: 120.5 })).body.group_audio.position_s, 120.5);
  await cmd(B.token, O, { action: 'play' });

  /* --- queue: anyone suggests; next in order; empty next stops --- */
  await cmd(A.token, O, { action: 'allow_all', value: false });
  assert.equal((await cmd(B.token, O, { action: 'next' })).status, 403, 'allow_all off again');
  assert.equal((await cmd(B.token, O, { action: 'queue_add', item: { source: 'audius', id: '1AXEE', title: 'Oud', duration_s: 337 } })).status, 200);
  for (let i = 1; i < QUEUE_MAX; i += 1) await cmd(A.token, O, { action: 'queue_add', item: { source: 'radio', id: 'mbc-fm' } });
  assert.equal((await cmd(B.token, O, { action: 'queue_add', item: { source: 'radio', id: 'mbc-fm' } })).body.error, 'queue_full');
  const nx = await cmd(A.token, O, { action: 'next' });
  assert.equal(nx.body.group_audio.item.source, 'audius');
  assert.ok(nx.body.group_audio.position_s < 0.5);

  /* --- ws command with ack, refused for a member --- */
  const la = live(A.token, O);
  await la.opened;
  await until(() => la.inbox.some((m) => m.type === 'ready'));
  la.ws.send(JSON.stringify({ type: 'group_audio_cmd', id: 7, cmd: radio('panorama-fm') }));
  const ack = await until(() => la.inbox.find((m) => m.type === 'group_audio_ack'));
  assert.equal(ack.id, 7);
  assert.equal(ack.ok, true);
  assert.equal(ack.state.item.id, 'panorama-fm');
  lb.ws.send(JSON.stringify({ type: 'group_audio_cmd', id: 8, cmd: { action: 'stop' } }));
  const nack = await until(() => lb.inbox.find((m) => m.type === 'group_audio_ack'));
  assert.deepEqual([nack.ok, nack.reason], [false, 'not_allowed']);
  lb.ws.send(JSON.stringify({ type: 'group_audio_sync' }));
  await until(() => lb.ga().at(-1)?.state.item?.id === 'panorama-fm');

  /* --- a member joining late finds what plays, in the ready snapshot and over HTTP --- */
  assert.equal((await api('POST', '/invites/join', L.token, { token: created.body.invite.token })).status, 200);
  const ll = live(L.token, O);
  await ll.opened;
  const lready = await until(() => ll.inbox.find((m) => m.type === 'ready'));
  assert.equal(lready.snapshot.group_audio.item.id, 'panorama-fm');
  assert.equal((await api('GET', `/${O}`, L.token)).body.group_audio.item.id, 'panorama-fm');
  for (const x of [la, lb, ll]) x.ws.close();

  /* --- a server restart keeps it (sary.group_audio) --- */
  const [row] = (await pool.query('SELECT state FROM sary.group_audio WHERE outing_id = $1', [O])).rows;
  assert.equal(row.state.item.id, 'panorama-fm');
  srv.outings.close();
  await new Promise((r) => srv.server.close(r));
  srv = await boot();
  const after = await api('GET', `/${O}/group-audio`, L.token);
  assert.equal(after.body.group_audio.item.id, 'panorama-fm', 'read back after restart');
  assert.equal(after.body.group_audio.queue.length, QUEUE_MAX - 1);

  /* --- ending clears it, row included --- */
  assert.equal((await api('POST', `/${O}/status`, A.token, { action: 'end' })).status, 200);
  assert.equal((await api('GET', `/${O}/group-audio`, A.token)).body.group_audio.item, null);
  assert.equal((await cmd(A.token, O, radio('mbc-fm'))).body.error, 'outing_ended');
  await until(async () => true);
  await new Promise((r) => setTimeout(r, 100));
  assert.equal((await pool.query('SELECT 1 FROM sary.group_audio WHERE outing_id = $1', [O])).rows.length, 0);

  /* --- per-member command limit --- */
  const c2 = await api('POST', '/', A.token, { name: 'طلعة ٢' });
  const codes = [];
  for (let i = 0; i < 65; i += 1) codes.push((await cmd(A.token, c2.body.outing_id, radio('mbc-fm'))).status);
  assert.ok(codes.includes(429), 'rate limited');
});
