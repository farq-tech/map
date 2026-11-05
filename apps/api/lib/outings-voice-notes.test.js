'use strict';

/**
 * «رسالة صوتية» — walkie-talkie voice notes (lib/outings/voice-notes.js, migration 015):
 * upload / list / fetch over a real Postgres, router and WebSockets; who may see a note
 * (trip members, the channel's members for a private channel); delivery to new sockets,
 * the old voice_clip shape for older ones, Push to Talk wake-ups and time-sensitive alerts;
 * idempotent retries; the 24 h / trip-end / sender-left / channel-closed clean-up.
 *
 *   node --test apps/api/lib/outings-voice-notes.test.js                    (pure parts)
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-voice-notes.test.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { parseNoteDurationMs, parseAgeMs, NOTE_MAX_MS, NOTE_TTL_MS, NOTE_AUTOPLAY_MS } = require('./outings/voice-notes');
const { pttRequestFor } = require('./outings/apns');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- pure ---------------- */

test('note length: 0.3–60 s, a little overshoot tolerated and clamped', () => {
  assert.equal(NOTE_MAX_MS, 60_000);
  assert.equal(parseNoteDurationMs('4200'), 4200);
  assert.equal(parseNoteDurationMs('61200'), 60_000);
  assert.equal(parseNoteDurationMs('62000'), null);
  assert.equal(parseNoteDurationMs('100'), null);
  assert.equal(parseNoteDurationMs(undefined), null);
  assert.equal(parseNoteDurationMs('abc'), null);
});

test('age from the outbox: never negative, never past the 24 h life', () => {
  assert.equal(parseAgeMs('1500'), 1500);
  assert.equal(parseAgeMs('-5'), 0);
  assert.equal(parseAgeMs(undefined), 0);
  assert.equal(parseAgeMs(String(NOTE_TTL_MS * 3)), NOTE_TTL_MS - 60_000);
  assert.equal(NOTE_AUTOPLAY_MS, 120_000);
});

test('a voice-note Push to Talk push: names the note, lives as long as it may still play by itself', () => {
  const r = pttRequestFor(
    { outingId: 'o', talkerId: 'u', name: 'فهد', burst: null, channel: '3', type: 'voice_note', expiresInS: 90, extra: { note: { id: 'n1' } } },
    { bundleId: 'sa.sary.albarq', now: 1_000_000 },
  );
  const body = JSON.parse(r.body);
  assert.equal(r.headers['apns-push-type'], 'pushtotalk');
  assert.equal(r.headers['apns-topic'], 'sa.sary.albarq.voip-ptt');
  assert.equal(r.headers['apns-expiration'], String(1000 + 90));
  assert.equal(body.type, 'voice_note');
  assert.equal(body.activeSpeaker, 'فهد');
  assert.equal(body.channel, '3');
  assert.deepEqual(body.note, { id: 'n1' });
  /* Live pushes are unchanged. */
  const live = pttRequestFor({ outingId: 'o', talkerId: 'u', name: 'فهد', burst: 4 }, { bundleId: 'sa.sary.albarq' });
  assert.equal(live.headers['apns-expiration'], '0');
  assert.equal(JSON.parse(live.body).type, 'ptt_talker');
});

/* ---------------- database ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_voice`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

const mp4 = (n = 4000, fill = 7) => Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypM4A '), Buffer.alloc(n, fill)]);

test('voice notes end to end: members only, channel-scoped, delivered live / old clients / PTT push / alert, idempotent, cleaned up', { skip, timeout: 60_000 }, async (t) => {
  const { createPool, migrate } = require('./outings/db');
  const { setupOutings } = require('./outings');
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);
  const pttPushes = [];
  const alerts = [];
  const outings = setupOutings({
    pool,
    autoMigrate: false,
    config: { minFixIntervalMs: 0, persistEveryMs: 0 },
    limits: { identityPerHour: 100, invitePer10Min: 100 },
    apns: {
      config: { enabled: true, bundleId: 'sa.sary.albarq', key: {} },
      sender: {
        async send(device, req) {
          const body = JSON.parse(req.body);
          (req.headers['apns-push-type'] === 'pushtotalk' ? pttPushes : alerts).push({ token: device.token, body, headers: req.headers });
          return { status: 200 };
        },
      },
    },
  });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  app.use((e, _req, res, _next) => res.status(e.status || 500).json({ ok: false, error: e.type || 'error' }));
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
  const upload = async (token, outingId, buf, { ms = 4200, channel, clientId = crypto.randomBytes(8).toString('hex'), ageMs } = {}) => {
    const headers = { 'content-type': 'audio/mp4', 'x-clip-duration-ms': String(ms), 'x-client-id': clientId };
    if (token) headers.authorization = `Bearer ${token}`;
    if (channel !== undefined) headers['x-ptt-channel'] = channel;
    if (ageMs !== undefined) headers['x-clip-age-ms'] = String(ageMs);
    const res = await fetch(`${base}/${outingId}/voice-notes`, { method: 'POST', headers, body: buf });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const audio = async (token, url) => {
    const res = await fetch(`http://127.0.0.1:${port}${url}`, { headers: { authorization: `Bearer ${token}` } });
    return { status: res.status, type: res.headers.get('content-type'), buf: Buffer.from(await res.arrayBuffer()) };
  };
  function live(token, outingId, caps) {
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
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId, ...(caps ? { caps } : {}) })));
    return { ws, inbox, next, opened, send: (m) => ws.send(JSON.stringify(m)) };
  }
  const hex = () => crypto.randomBytes(32).toString('hex');

  const mk = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  const [A, B, C, D, E, X] = [await mk('أبو فهد'), await mk('سعد'), await mk('نورة'), await mk('ريم'), await mk('خالد'), await mk('غريب')];
  const created = await api('POST', '/', A.token, { name: 'طلعة النفود' });
  const O = created.body.outing_id;
  for (const p of [B, C, D, E]) assert.equal((await api('POST', '/invites/join', p.token, { token: created.body.invite.token })).status, 200);
  await api('POST', `/${O}/status`, A.token, { action: 'start' });

  /* D: phone in a pocket with a Push to Talk token, no socket. E: no PTT token, an ordinary APNs token. */
  assert.equal((await api('POST', `/${O}/ptt/token`, D.token, { token: hex(), environment: 'sandbox' })).status, 201);
  assert.equal((await api('POST', '/push/apns', E.token, { token: hex(), environment: 'sandbox' })).status, 201);

  /* A, B: this build (voice notes); C: an older build (no caps). All on «تردد ١». */
  const [la, lb, lc] = [live(A.token, O, ['voice_notes']), live(B.token, O, ['voice_notes']), live(C.token, O)];
  await Promise.all([la.opened, lb.opened, lc.opened]);
  for (const l of [la, lb, lc]) {
    await l.next((m) => m.type === 'ready');
    l.send({ type: 'ptt_join', channel: '1', channels: true });
    await l.next((m) => m.type === 'ptt_state');
  }

  /* ---- who may upload, and what ---- */
  assert.equal((await upload(null, O, mp4())).status, 401);
  assert.equal((await upload(X.token, O, mp4())).status, 404, 'outsider');
  assert.equal((await upload(A.token, O, Buffer.from('<html>not audio</html>'.repeat(30)))).status, 415);
  assert.equal((await upload(A.token, O, mp4(10))).status, 400, 'too short to be audio');
  assert.equal((await upload(A.token, O, mp4(700 * 1024))).status, 413, 'size cap');
  assert.equal((await upload(A.token, O, mp4(), { ms: 70_000 })).status, 400, 'over a minute');
  assert.equal((await upload(A.token, O, mp4(), { channel: '9' })).status, 400, 'no such channel');
  assert.equal((await upload(A.token, O, mp4(), { clientId: 'bad id!' })).status, 400, 'idempotency key required');

  /* ---- a note on «تردد ١» ---- */
  const cid = 'note-1';
  const up = await upload(A.token, O, mp4(4000, 9), { ms: 61_000, clientId: cid });
  assert.equal(up.status, 201);
  const note = up.body.note;
  assert.equal(note.channel, '1');
  assert.equal(note.duration_ms, 60_000, 'clamped to the minute');
  assert.equal(note.user_id, A.user.id);
  assert.ok(note.age_ms < 5_000);
  assert.equal(note.url, `/api/outings/${O}/voice-notes/${note.id}`);
  const ev = await lb.next((m) => m.type === 'voice_note');
  assert.equal(ev.note.id, note.id, 'a new build hears about it on its socket');
  assert.ok(ev.note.age_ms < 5_000);
  const old = await lc.next((m) => m.type === 'voice_clip');
  assert.equal(old.clip.id, note.id, 'an older build gets its usual voice banner');
  assert.equal(old.clip.url, note.url);
  assert.ok(old.clip.at && old.clip.expires_at);
  assert.ok(!la.inbox.some((m) => m.type === 'voice_note' || m.type === 'voice_clip'), 'not echoed to the sender');
  await sleep(150);
  const woke = pttPushes.filter((p) => p.body.type === 'voice_note');
  assert.equal(woke.length, 1, 'D (pocket, PTT token) is woken through Push to Talk');
  assert.equal(woke[0].body.note.id, note.id);
  assert.equal(woke[0].body.activeSpeaker, 'أبو فهد');
  assert.equal(woke[0].body.channel, '1');
  assert.ok(Number(woke[0].headers['apns-expiration']) > Math.floor(Date.now() / 1000), 'expires with the auto-play window, not at once');
  const alerted = alerts.filter((p) => p.body.type === 'voice_note');
  assert.equal(alerted.length, 1, 'E (no PTT token) gets a time-sensitive alert instead');
  assert.equal(alerted[0].body.aps['interruption-level'], 'time-sensitive');
  assert.match(alerted[0].body.aps.alert.body, /رسالة صوتية \(60 ث\)/);

  /* The same upload again (a retry after a lost answer): the same note, announced once. */
  const again = await upload(A.token, O, mp4(4000, 9), { ms: 61_000, clientId: cid });
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);
  assert.equal(again.body.note.id, note.id);
  await sleep(100);
  assert.ok(!lb.inbox.some((m) => m.type === 'voice_note'), 'no second announcement');
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.ptt_voice_notes')).rows[0].n, 1);

  /* ---- fetch and list ---- */
  const got = await audio(B.token, note.url);
  assert.equal(got.status, 200);
  assert.equal(got.type, 'audio/mp4');
  assert.ok(got.buf.equals(mp4(4000, 9)), 'byte for byte');
  assert.equal((await audio(X.token, note.url)).status, 404, 'outsider cannot fetch');
  assert.equal((await audio(B.token, `/api/outings/${O}/voice-notes/not-a-uuid`)).status, 404);
  const l1 = await api('GET', `/${O}/voice-notes?channel=1`, C.token);
  assert.equal(l1.status, 200);
  assert.deepEqual(l1.body.notes.map((n) => n.id), [note.id]);
  assert.ok(!('audio' in l1.body.notes[0]), 'the list never carries audio');
  assert.deepEqual((await api('GET', `/${O}/voice-notes?channel=2`, C.token)).body.notes, [], 'per channel');
  assert.equal((await api('GET', `/${O}/voice-notes`, X.token)).status, 404);

  /* ---- a private channel: only its members upload, hear, list or fetch ---- */
  const P = (await api('POST', `/${O}/ptt/channels`, A.token, { name: 'الأمامية', members: [B.user.id] })).body.channel.id;
  assert.equal((await upload(C.token, O, mp4(), { channel: P })).status, 403, 'not invited');
  lb.send({ type: 'ptt_join_channel', channel: P });
  await lb.next((m) => m.type === 'ptt_state' && m.channel === P);
  await sleep(1300); // past the per-person gap
  const pn = (await upload(A.token, O, mp4(3000, 3), { channel: P })).body.note;
  assert.equal(pn.channel, P);
  assert.equal((await lb.next((m) => m.type === 'voice_note')).note.id, pn.id);
  await sleep(150);
  assert.ok(!lc.inbox.some((m) => (m.type === 'voice_clip' || m.type === 'voice_note') && (m.clip?.id === pn.id || m.note?.id === pn.id)), 'C never hears of it');
  assert.equal((await api('GET', `/${O}/voice-notes?channel=${P}`, C.token)).status, 403);
  assert.equal((await audio(C.token, pn.url)).status, 404, 'for C it does not exist');
  assert.equal((await audio(B.token, pn.url)).status, 200);
  assert.ok(!pttPushes.some((p) => p.body.note?.id === pn.id), 'D is not on it: not woken');

  /* ---- a note sent late from an outbox: stored as old, no Push to Talk wake-up ---- */
  await sleep(1300);
  const late = (await upload(A.token, O, mp4(3000, 4), { ageMs: 5 * 60_000 })).body.note;
  assert.ok(late.age_ms >= 5 * 60_000);
  assert.ok(new Date(late.recorded_at) < new Date(late.created_at));
  await sleep(150);
  assert.ok(!pttPushes.some((p) => p.body.note?.id === late.id), 'too old to play by itself: no wake-up');
  assert.ok(alerts.some((p) => p.body.note_id === late.id), 'still announced by an alert');

  /* ---- clean-up ---- */
  /* The private channel closes: its notes go (hidden at once by the channel check, freed by the sweep). */
  assert.equal((await api('DELETE', `/${O}/ptt/channels/${P}`, A.token)).status, 200);
  assert.equal((await audio(B.token, pn.url)).status, 404);
  /* Expired. */
  await pool.query(`UPDATE sary.ptt_voice_notes SET expires_at = now() - interval '1 second' WHERE id = $1`, [late.id]);
  assert.ok(!(await api('GET', `/${O}/voice-notes?channel=1`, B.token)).body.notes.some((n) => n.id === late.id));
  assert.equal(await outings.voiceNotes.sweep(), 2, 'the closed channel’s note and the expired one');
  /* The sender leaves: their notes are no longer anyone's to hear. */
  await sleep(1300);
  const cNote = (await upload(C.token, O, mp4(), {})).body.note;
  assert.equal((await audio(B.token, cNote.url)).status, 200);
  assert.equal((await api('POST', `/${O}/leave`, C.token)).status, 200);
  assert.equal((await audio(B.token, cNote.url)).status, 404);
  assert.equal(await outings.voiceNotes.sweep(), 1);
  /* The trip ends: nothing to list, nothing to fetch, swept. */
  await api('POST', `/${O}/status`, A.token, { action: 'end' });
  assert.equal((await audio(B.token, note.url)).status, 404);
  assert.equal(await outings.voiceNotes.sweep(), 1);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.ptt_voice_notes')).rows[0].n, 0);
  /* Account deletion cascades (schema). */
  const fk = (await pool.query(`SELECT confdeltype FROM pg_constraint WHERE conrelid = 'sary.ptt_voice_notes'::regclass AND contype = 'f'`)).rows.map((r) => r.confdeltype);
  assert.deepEqual(fk.sort(), ['c', 'c']);
  const rls = (await pool.query(`SELECT relrowsecurity FROM pg_class WHERE oid = 'sary.ptt_voice_notes'::regclass`)).rows[0];
  assert.equal(rls.relrowsecurity, true);
  for (const l of [la, lb, lc]) l.ws.close();
});
