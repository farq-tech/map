'use strict';

/**
 * «المحادثات» — trip chat over a real Postgres, the real router and real
 * WebSockets: authorization, pagination, idempotent retries, realtime
 * delivery, read receipts, deletion, push, retention and account deletion.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-chat.test.js
 *
 * Runs in its own database (`<db>_sary_chat`, created on demand) so it can run
 * in parallel with the other integration files.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { createPool, migrate } = require('./outings/db');
const { setupOutings } = require('./outings');
const { chatText, parseWith, parseMessage, directKey } = require('./outings/chat');
const { chatPushPayload } = require('./outings/push');
const { apnsRequestFor } = require('./outings/apns');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

/* ---------- pure rules (always run) ---------- */

test('chat text: keeps line breaks, strips control/bidi, refuses > 1000 chars', () => {
  assert.equal(chatText('  هلا\r\n\n\n\nوين صرتوا؟  '), 'هلا\n\nوين صرتوا؟');
  assert.equal(chatText('a‮b\u0007c'), 'abc');
  assert.equal(chatText('   '), null);
  assert.equal(chatText(42), null);
  assert.equal(chatText('ب'.repeat(1000)), 'ب'.repeat(1000));
  assert.equal(chatText('ب'.repeat(1001)), undefined);
  /* code points, not UTF-16 units: 1000 emoji fit */
  assert.equal([...chatText('🚙'.repeat(1000))].length, 1000);
});

test('conversation keys and message shapes', () => {
  const a = '00000000-0000-4000-8000-00000000000a';
  const b = '00000000-0000-4000-8000-00000000000b';
  assert.equal(directKey(a, b), directKey(b, a));
  assert.deepEqual(parseWith(a, 'group'), { conv: 'group', peer: null });
  assert.deepEqual(parseWith(a, b), { conv: `${a}:${b}`, peer: b });
  assert.equal(parseWith(a, a), null, 'no chat with yourself');
  assert.equal(parseWith(a, 'nope'), null);
  assert.equal(parseMessage({ kind: 'text', text: 'هلا' }).body, 'هلا');
  assert.equal(parseMessage({ kind: 'text', text: '' }).error, 'invalid_message');
  assert.equal(parseMessage({ kind: 'quick', text: 'بوقف\nالحين' }).body, 'بوقف الحين');
  assert.deepEqual(parseMessage({ kind: 'location', point: { lat: 24.7, lng: 46.6, label: 'المخيم' } }), { kind: 'location', body: null, lat: 24.7, lng: 46.6, label: 'المخيم' });
  assert.equal(parseMessage({ kind: 'location', point: { lat: 200, lng: 0 } }).error, 'invalid_point');
  assert.equal(parseMessage({ kind: 'photo' }).error, 'invalid_kind');
});

test('chat push payload: trip name of the sender, normal interruption, opens the right chat', () => {
  const group = chatPushPayload({ id: 'm1', outing_id: 'o1', sender_id: 'u1', recipient_id: null, kind: 'text', text: 'وصلت' }, { senderName: 'فهد أخوي', outingName: 'النفود' });
  assert.equal(group.title, 'فهد أخوي · النفود');
  assert.equal(group.body, 'وصلت');
  assert.equal(group.extra.chat_with, 'group');
  const dm = chatPushPayload({ id: 'm2', outing_id: 'o1', sender_id: 'u1', recipient_id: 'u2', kind: 'location', point: { lat: 1, lng: 1, label: null } }, { senderName: 'فهد' });
  assert.equal(dm.title, 'فهد (خاص)');
  assert.match(dm.body, /📍/);
  assert.equal(dm.extra.chat_with, 'u1', 'the reply goes to the sender');
  const req = apnsRequestFor(group, 'o1', { bundleId: 'sa.sary.albarq' });
  const aps = JSON.parse(req.body);
  assert.equal(aps.aps['interruption-level'], 'active', 'normal alert, not time-sensitive');
  assert.equal(aps.aps.sound, 'default');
  assert.equal(aps.chat_with, 'group');
});

/* ---------- over Postgres ---------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_chat`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

async function boot(t, extra = {}) {
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);
  const pushed = [];
  const sender = {
    async send(sub, body) {
      pushed.push({ endpoint: sub.endpoint, payload: JSON.parse(body) });
      return { statusCode: 201 };
    },
  };
  const outings = setupOutings({
    pool,
    autoMigrate: false,
    config: { minFixIntervalMs: 0, persistEveryMs: 0, chatPerMinute: 1000, ...(extra.config || {}) },
    limits: { identityPerHour: 1000, invitePer10Min: 1000, deletePerHour: 100 },
    push: { config: { enabled: true, publicKey: 'BTestPublicKey', privateKey: 'unused-by-fake' }, sender },
    apns: { config: { enabled: false } },
  });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  outings.attach(server);
  const port = server.address().port;
  const sockets = [];
  t.after(async () => {
    for (const s of sockets) s.terminate();
    await outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const base = `http://127.0.0.1:${port}/api/outings`;
  const api = async (method, path, token, body) => {
    const res = await fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const person = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  function live(token, outingId) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    sockets.push(ws);
    const inbox = [];
    ws.on('message', (d) => inbox.push(JSON.parse(String(d))));
    const ready = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    const until = async (pred, ms = 4000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const hit = inbox.find(pred);
        if (hit) return hit;
        await new Promise((r) => setTimeout(r, 20));
      }
      throw new Error('timeout waiting for frame');
    };
    return { ws, inbox, until, ready: ready.then(() => until((m) => m.type === 'ready')), send: (m) => ws.send(JSON.stringify(m)) };
  }
  const settle = (ms = 250) => new Promise((r) => setTimeout(r, ms));
  return { pool, outings, api, person, live, pushed, settle };
}

test('trip chat — authorization, DMs, pagination, outbox retries, deletion, read receipts', { skip, timeout: 90_000 }, async (t) => {
  const { pool, api, person, live, settle } = await boot(t);
  const A = await person('أبو فهد'); // leader
  const B = await person('سعد');
  const C = await person('ناصر');
  const D = await person('غريب'); // never in the trip
  const E = await person('مطرود'); // removed
  const o = { id: (await api('POST', '/', A.token, { name: 'طلعة النفود' })).body.outing_id };
  const inv = (await api('POST', `/${o.id}/invites`, A.token, {})).body.invite.token;
  for (const p of [B, C, E]) assert.equal((await api('POST', '/invites/join', p.token, { token: inv })).status, 200);

  /* --- send: HTTP, idempotent on client_id --- */
  const m1 = await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-1', kind: 'text', text: 'هلا والله' });
  assert.equal(m1.status, 201);
  assert.equal(m1.body.message.seq, 1);
  assert.equal(m1.body.message.sender_name, 'سعد');
  const again = await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-1', kind: 'text', text: 'هلا والله' });
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);
  assert.equal(again.body.message.id, m1.body.message.id, 'an outbox retry never makes a copy');
  assert.equal((await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-2', text: 'x'.repeat(1001) })).body.error, 'text_too_long');
  assert.equal((await api('POST', `/${o.id}/chat/group`, B.token, { text: 'no id' })).body.error, 'invalid_client_id');

  /* --- outsiders and removed members --- */
  assert.equal((await api('GET', `/${o.id}/chat`, D.token)).status, 404);
  assert.equal((await api('GET', `/${o.id}/chat/group`, D.token)).status, 404);
  assert.equal((await api('POST', `/${o.id}/chat/group`, D.token, { client_id: 'd-1', text: 'hi' })).status, 404);
  assert.equal((await api('POST', `/${o.id}/chat/${A.user.id}`, D.token, { client_id: 'd-2', text: 'hi' })).status, 404, 'no DM into a trip you are not in');
  assert.equal((await api('POST', `/${o.id}/chat/${D.user.id}`, A.token, { client_id: 'a-x', text: 'hi' })).status, 404, 'no DM to someone outside the trip');
  assert.equal((await api('POST', `/${o.id}/chat/${A.user.id}`, A.token, { client_id: 'a-self', text: 'hi' })).status, 400);
  assert.equal((await api('GET', `/${o.id}/chat`, null)).status, 401);
  await api('POST', `/${o.id}/chat/group`, E.token, { client_id: 'e-1', text: 'قبل الطرد' });
  assert.equal((await api('DELETE', `/${o.id}/members/${E.user.id}`, A.token)).status, 200);
  assert.equal((await api('GET', `/${o.id}/chat/group`, E.token)).status, 404, 'removed: no access at all');
  assert.equal((await api('POST', `/${o.id}/chat/group`, E.token, { client_id: 'e-2', text: 'بعد' })).status, 404);

  /* --- realtime over the live socket --- */
  const la = live(A.token, o.id);
  const lb = live(B.token, o.id);
  const lc = live(C.token, o.id);
  await Promise.all([la.ready, lb.ready, lc.ready]);
  assert.ok(typeof la.inbox.find((m) => m.type === 'ready').snapshot.chat_unread === 'number', 'snapshot carries the unread badge');
  lb.send({ type: 'chat_message', id: 7, with: 'group', client_id: 'b-ws-1', kind: 'quick', text: 'اصبروا لي' });
  const ack = await lb.until((m) => m.type === 'chat_ack' && m.id === 7);
  assert.equal(ack.ok, true);
  assert.equal(ack.message.kind, 'quick');
  const gotA = await la.until((m) => m.type === 'chat_message' && m.message.client_id === 'b-ws-1');
  assert.equal(gotA.message.text, 'اصبروا لي');
  await lc.until((m) => m.type === 'chat_message' && m.message.client_id === 'b-ws-1');

  /* A direct message reaches the two of them only. */
  lb.send({ type: 'chat_message', id: 8, with: A.user.id, client_id: 'b-dm-1', kind: 'location', point: { lat: 27.5, lng: 41.7, label: 'عند الطعس' } });
  const dmAck = await lb.until((m) => m.type === 'chat_ack' && m.id === 8);
  assert.equal(dmAck.ok, true);
  const dmA = await la.until((m) => m.type === 'chat_message' && m.message.client_id === 'b-dm-1');
  assert.equal(dmA.message.conv, 'direct');
  assert.deepEqual(dmA.message.point, { lat: 27.5, lng: 41.7, label: 'عند الطعس' });
  await settle();
  assert.ok(!lc.inbox.some((m) => m.type === 'chat_message' && m.message.client_id === 'b-dm-1'), 'C never sees a DM between A and B');
  assert.equal((await api('GET', `/${o.id}/chat/${B.user.id}`, C.token)).body.messages.length, 0, "C's own chat with B is empty");
  /* Socket frames are checked too: a bad target is refused, not relayed. */
  lb.send({ type: 'chat_message', id: 9, with: D.user.id, client_id: 'b-dm-x', text: 'hi' });
  assert.equal((await lb.until((m) => m.type === 'chat_ack' && m.id === 9)).reason, 'not_a_member');

  /* Typing: to the others, never stored. */
  lc.send({ type: 'chat_typing', with: 'group', on: true });
  const typing = await la.until((m) => m.type === 'chat_typing');
  assert.equal(typing.user_id, C.user.id);
  assert.ok(!lc.inbox.some((m) => m.type === 'chat_typing'));

  /* --- unread badges + read receipts --- */
  let convA = (await api('GET', `/${o.id}/chat`, A.token)).body;
  assert.equal(convA.conversations[0].with, 'group', 'group first');
  assert.equal(convA.conversations[0].unread, 3, 'B ×2 + E (before removal)');
  assert.equal(convA.conversations[1].with, B.user.id);
  assert.equal(convA.conversations[1].unread, 1);
  assert.equal(convA.unread_total, 4);
  assert.equal(convA.can_moderate, true);
  assert.deepEqual(convA.quick_replies.slice(0, 3), ['بوقف', 'محطة بنزين', 'اصبروا لي']);
  la.send({ type: 'chat_read', with: B.user.id, seq: dmAck.message.seq });
  const receipt = await lb.until((m) => m.type === 'chat_read' && m.user_id === A.user.id);
  assert.equal(receipt.seq, dmAck.message.seq, '✓✓ for B');
  await settle();
  assert.ok(!lc.inbox.some((m) => m.type === 'chat_read' && m.conv === 'direct'), 'a DM read receipt stays between the two');
  assert.equal((await api('POST', `/${o.id}/chat/group/read`, A.token, { seq: 999999 })).body.last_read_seq <= 999999, true);
  convA = (await api('GET', `/${o.id}/chat`, A.token)).body;
  assert.equal(convA.unread_total, 0);
  const convB = (await api('GET', `/${o.id}/chat`, B.token)).body;
  assert.equal(convB.conversations.find((c) => c.with === A.user.id).peer_read_seq, dmAck.message.seq);
  assert.equal((await api('POST', `/${o.id}/chat/group/read`, A.token, { seq: 1 })).body.last_read_seq > 1, true, 'never moves backwards');

  /* --- pagination by seq --- */
  for (let i = 0; i < 60; i += 1) await api('POST', `/${o.id}/chat/group`, C.token, { client_id: `c-${i}`, text: `رسالة ${i}` });
  const newest = (await api('GET', `/${o.id}/chat/group?limit=25`, A.token)).body;
  assert.equal(newest.messages.length, 25);
  assert.equal(newest.has_more, true);
  assert.equal(newest.messages.at(-1).text, 'رسالة 59');
  const seqs = newest.messages.map((m) => m.seq);
  assert.deepEqual(seqs, [...seqs].sort((x, y) => x - y), 'oldest first, by server seq');
  const older = (await api('GET', `/${o.id}/chat/group?limit=25&before=${seqs[0]}`, A.token)).body;
  assert.equal(older.messages.length, 25);
  assert.ok(older.messages.at(-1).seq < seqs[0]);
  const all = [];
  let cursor = null;
  for (;;) {
    const page = (await api('GET', `/${o.id}/chat/group?limit=30${cursor ? `&before=${cursor}` : ''}`, A.token)).body;
    all.unshift(...page.messages);
    if (!page.has_more) break;
    cursor = page.messages[0].seq;
  }
  assert.equal(all.length, 63, 'every group message exactly once: B×2, E, C×60');
  assert.equal(new Set(all.map((m) => m.id)).size, 63);
  const after = (await api('GET', `/${o.id}/chat/group?after=${seqs.at(-3)}`, A.token)).body;
  assert.deepEqual(after.messages.map((m) => m.seq), seqs.slice(-2), 'catch up after a gap');
  assert.equal((await api('GET', `/${o.id}/chat/group?before=abc`, A.token)).status, 400);

  /* --- deletion --- */
  const target = all.find((m) => m.sender_id === C.user.id);
  assert.equal((await api('DELETE', `/${o.id}/chat/messages/${target.id}`, B.token)).status, 403, 'a member cannot delete someone else’s');
  const del = await api('DELETE', `/${o.id}/chat/messages/${target.id}`, A.token);
  assert.equal(del.status, 200);
  assert.equal(del.body.message.deleted, true);
  assert.equal(del.body.message.deleted_by, 'leader', '«حذفها أمير الرحلة»');
  assert.equal(del.body.message.text, null, 'content wiped');
  const row = (await pool.query('SELECT body FROM sary.chat_messages WHERE id = $1', [target.id])).rows[0];
  assert.equal(row.body, null, 'wiped in the database too');
  await lc.until((m) => m.type === 'chat_deleted' && m.message.id === target.id);
  const own = await api('DELETE', `/${o.id}/chat/messages/${m1.body.message.id}`, B.token);
  assert.equal(own.body.message.deleted_by, 'self');
  assert.equal((await api('DELETE', `/${o.id}/chat/messages/${dmAck.message.id}`, C.token)).status, 404, 'someone else’s DM does not exist for you');
  /* A «مساعد» moderates the group too, but never a DM between others. */
  await api('POST', `/${o.id}/members/${C.user.id}/co-leader`, A.token, { co_leader: true });
  const bMsg = (await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-3', text: 'احذفوها' })).body.message;
  assert.equal((await api('DELETE', `/${o.id}/chat/messages/${bMsg.id}`, C.token)).body.message.deleted_by, 'leader');

  /* --- leaving: read-only, history up to the moment you left --- */
  assert.equal((await api('POST', `/${o.id}/leave`, B.token)).status, 200);
  await settle(50);
  await api('POST', `/${o.id}/chat/group`, A.token, { client_id: 'a-after-b-left', text: 'بعد ما طلع سعد' });
  const bView = (await api('GET', `/${o.id}/chat/group?limit=100`, B.token)).body;
  assert.equal(bView.writable, false);
  assert.equal(bView.read_only_reason, 'chat_read_only');
  assert.ok(!bView.messages.some((m) => m.client_id === 'a-after-b-left'), 'nothing said after they left');
  assert.equal((await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-4', text: 'x' })).body.error, 'chat_read_only');
  assert.equal((await api('POST', `/${o.id}/chat/${B.user.id}`, A.token, { client_id: 'a-dm-left', text: 'x' })).body.error, 'peer_not_active');
  assert.equal((await api('GET', `/${o.id}/chat/${B.user.id}`, A.token)).body.messages.length, 1, 'the DM history stays readable');

  /* --- trip ends: read-only for everyone, history kept --- */
  assert.equal((await api('POST', `/${o.id}/status`, A.token, { action: 'end' })).status, 200);
  const endView = (await api('GET', `/${o.id}/chat`, C.token)).body;
  assert.equal(endView.writable, false);
  assert.equal(endView.read_only_reason, 'outing_ended');
  assert.ok(endView.purge_at, 'shows when it will be deleted');
  assert.equal((await api('POST', `/${o.id}/chat/group`, C.token, { client_id: 'c-end', text: 'x' })).body.error, 'outing_ended');
  /* An outbox retry of something already stored still gets its message back. */
  assert.equal((await api('POST', `/${o.id}/chat/group`, C.token, { client_id: 'c-1', text: 'رسالة 1' })).body.duplicate, true);
  assert.ok((await api('GET', `/${o.id}/chat/group`, C.token)).body.messages.length > 0);
});

test('trip chat — push to members off-screen with the personal-invite name; opt-out respected', { skip, timeout: 60_000 }, async (t) => {
  const { api, person, live, pushed, settle } = await boot(t);
  const A = await person('أبو فهد');
  const B = await person('Fahad');
  const C = await person('سعد');
  const o = { id: (await api('POST', '/', A.token, { name: 'النفود' })).body.outing_id };
  const personal = (await api('POST', `/${o.id}/invites/personal`, A.token, { name: 'فهد أخوي' })).body.invite.token;
  assert.equal((await api('POST', '/invites/join', B.token, { token: personal })).status, 200);
  const group = (await api('POST', `/${o.id}/invites`, A.token, {})).body.invite.token;
  assert.equal((await api('POST', '/invites/join', C.token, { token: group })).status, 200);
  const sub = (name) => ({ endpoint: `https://fcm.googleapis.com/fcm/send/${name}`, keys: { p256dh: Buffer.concat([Buffer.from([4]), Buffer.alloc(64, 1)]).toString('base64url'), auth: Buffer.alloc(16, 2).toString('base64url') } });
  for (const [p, n] of [[A, 'a'], [B, 'b'], [C, 'c']]) assert.equal((await api('POST', '/push/subscribe', p.token, { subscription: sub(n) })).status, 201);

  /* A is looking at the trip (socket open, not away): no push for A. */
  const la = live(A.token, o.id);
  await la.ready;
  await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-1', text: 'وصلت' });
  await settle(400);
  const first = pushed.filter((p) => p.payload.type === 'chat_message');
  assert.deepEqual(first.map((p) => p.endpoint.split('/').pop()).sort(), ['c'], 'only the member whose screen is off; never the sender');
  assert.equal(first[0].payload.title, 'فهد أخوي · النفود', 'the trip’s name for the sender');
  assert.equal(first[0].payload.extra.chat_with, 'group');

  /* C turns chat notifications off. */
  assert.deepEqual((await api('GET', '/push/chat', C.token)).body, { ok: true, chat_push: true });
  assert.equal((await api('PUT', '/push/chat', C.token, { chat_push: 'no' })).status, 400);
  assert.equal((await api('PUT', '/push/chat', C.token, { chat_push: false })).status, 200);
  pushed.length = 0;
  await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-2', text: 'وينكم' });
  await api('POST', `/${o.id}/chat/${C.user.id}`, B.token, { client_id: 'b-3', text: 'خاص' });
  await settle(400);
  assert.equal(pushed.filter((p) => p.payload.type === 'chat_message').length, 0, 'opted out: nothing, group or direct');

  /* A direct message is pushed to its recipient only. */
  la.ws.close();
  await settle(200);
  await api('POST', `/${o.id}/chat/${A.user.id}`, B.token, { client_id: 'b-4', text: 'تعال' });
  await settle(400);
  const dm = pushed.filter((p) => p.payload.type === 'chat_message');
  assert.deepEqual(dm.map((p) => p.endpoint.split('/').pop()), ['a']);
  assert.equal(dm[0].payload.title, 'فهد أخوي (خاص)');
  assert.equal(dm[0].payload.extra.chat_with, B.user.id);
});

test('trip chat — 30-day retention after the trip ends, and «احذف حسابي»', { skip, timeout: 60_000 }, async (t) => {
  const { pool, outings, api, person } = await boot(t);
  const A = await person('A');
  const B = await person('B');
  const C = await person('C');
  const mk = async (name) => {
    const o = { id: (await api('POST', '/', A.token, { name })).body.outing_id };
    const inv = (await api('POST', `/${o.id}/invites`, A.token, {})).body.invite.token;
    await api('POST', '/invites/join', B.token, { token: inv });
    await api('POST', '/invites/join', C.token, { token: inv });
    return o;
  };
  const old = await mk('قديمة');
  const recent = await mk('حديثة');
  const open = await mk('مفتوحة');
  for (const o of [old, recent, open]) {
    await api('POST', `/${o.id}/chat/group`, A.token, { client_id: `a-${o.id}`, text: 'هلا' });
    await api('POST', `/${o.id}/chat/${B.user.id}`, A.token, { client_id: `ab-${o.id}`, text: 'خاص' });
    await api('POST', `/${o.id}/chat/group/read`, B.token, { seq: 1 });
  }
  await api('POST', `/${old.id}/status`, A.token, { action: 'end' });
  await api('POST', `/${recent.id}/status`, A.token, { action: 'end' });
  await pool.query(`UPDATE sary.outings SET ended_at = now() - interval '31 days' WHERE id = $1`, [old.id]);
  await pool.query(`UPDATE sary.outings SET ended_at = now() - interval '29 days' WHERE id = $1`, [recent.id]);
  await outings.service.sweep();
  const count = async (id) => Number((await pool.query('SELECT count(*) FROM sary.chat_messages WHERE outing_id = $1', [id])).rows[0].count);
  const reads = async (id) => Number((await pool.query('SELECT count(*) FROM sary.chat_reads WHERE outing_id = $1', [id])).rows[0].count);
  assert.equal(await count(old.id), 0, 'ended 31 days ago: deleted');
  assert.equal(await reads(old.id), 0);
  assert.equal(await count(recent.id), 2, 'ended 29 days ago: kept');
  assert.equal(await count(open.id), 2, 'open trip: kept');

  /* «احذف حسابي»: B's own messages and every DM to B go; others' group messages stay. */
  await api('POST', `/${open.id}/chat/group`, B.token, { client_id: 'b-g', text: 'من B' });
  await api('POST', `/${open.id}/chat/${C.user.id}`, B.token, { client_id: 'b-c', text: 'B→C' });
  assert.equal((await api('DELETE', '/me', B.token)).status, 200);
  const left = (await pool.query('SELECT sender_id, recipient_id, body FROM sary.chat_messages WHERE outing_id = $1', [open.id])).rows;
  assert.deepEqual(left.map((r) => r.body), ['هلا'], 'only A’s group message remains');
  assert.equal(Number((await pool.query('SELECT count(*) FROM sary.chat_reads WHERE user_id = $1', [B.user.id])).rows[0].count), 0);
  assert.equal(Number((await pool.query('SELECT count(*) FROM sary.chat_messages WHERE sender_id = $1 OR recipient_id = $1', [B.user.id])).rows[0].count), 0);
});

test('«بلّغ» و«احظر» (App Store 1.2) — reports stored, blocked chat & voice notes hidden, DMs refused, SOS still reaches the blocker', { skip, timeout: 90_000 }, async (t) => {
  const { pool, api, person, live, pushed, settle } = await boot(t, { config: { reportsPerHour: 3 } });
  const A = await person('أبو فهد');
  const B = await person('مزعج');
  const C = await person('ناصر');
  const D = await person('غريب');
  const o = { id: (await api('POST', '/', A.token, { name: 'طلعة الصمان' })).body.outing_id };
  const inv = (await api('POST', `/${o.id}/invites`, A.token, {})).body.invite.token;
  for (const p of [B, C]) assert.equal((await api('POST', '/invites/join', p.token, { token: inv })).status, 200);

  const bad = (await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-1', text: 'كلام مسيء' })).body.message;

  /* --- report --- */
  assert.equal((await api('POST', `/${o.id}/chat/${bad.id}/report`, C.token, { reason: 'nope' })).body.error, 'invalid_reason');
  assert.equal((await api('POST', `/${o.id}/chat/${bad.id}/report`, D.token, { reason: 'abuse' })).status, 404, 'an outsider cannot report');
  assert.equal((await api('POST', `/${o.id}/chat/${bad.id}/report`, B.token, { reason: 'abuse' })).body.error, 'cannot_report_self');
  const r1 = await api('POST', `/${o.id}/chat/${bad.id}/report`, C.token, { reason: 'abuse', note: 'سب' });
  assert.equal(r1.status, 201);
  assert.equal(r1.body.duplicate, false);
  const r2 = await api('POST', `/${o.id}/chat/${bad.id}/report`, C.token, { reason: 'abuse' });
  assert.equal(r2.body.duplicate, true, 'one report per person per message');
  const [stored] = (await pool.query(`SELECT * FROM sary.chat_reports WHERE message_id = $1`, [bad.id])).rows;
  assert.equal(stored.reporter_id, C.user.id);
  assert.equal(stored.sender_id, B.user.id);
  assert.equal(stored.body_snapshot, 'كلام مسيء');
  assert.equal(stored.status, 'open');
  /* rate limit: 3 an hour in this test (the two above count) */
  await api('POST', `/${o.id}/chat/${bad.id}/report`, C.token, { reason: 'spam' });
  assert.equal((await api('POST', `/${o.id}/chat/${bad.id}/report`, C.token, { reason: 'spam' })).status, 429, 'reports are rate-limited');

  /* --- block: A blocks B (and reports with block:true works the same) --- */
  assert.equal((await api('POST', `/me/blocks/${A.user.id}`, A.token)).body.error, 'cannot_block_self');
  assert.equal((await api('POST', `/me/blocks/00000000-0000-4000-8000-000000000000`, A.token)).status, 404);
  const rb = await api('POST', `/${o.id}/chat/${bad.id}/report`, A.token, { reason: 'harassment', block: true });
  assert.equal(rb.body.blocked, true);
  const list = (await api('GET', '/me/blocks', A.token)).body.blocks;
  assert.deepEqual(list.map((b) => [b.user_id, b.display_name]), [[B.user.id, 'مزعج']]);
  assert.equal((await api('POST', `/me/blocks/${B.user.id}`, A.token)).status, 201, 'idempotent');

  /* history: hidden for A only */
  const histA = (await api('GET', `/${o.id}/chat/group`, A.token)).body.messages;
  assert.ok(!histA.some((m) => m.sender_id === B.user.id), 'blocked sender is gone from my history');
  const histC = (await api('GET', `/${o.id}/chat/group`, C.token)).body.messages;
  assert.ok(histC.some((m) => m.sender_id === B.user.id), 'others still see it');
  assert.equal((await api('GET', `/${o.id}/chat`, A.token)).body.unread_total, 0, 'no unread badge from a blocked sender');

  /* DMs: refused both ways */
  assert.equal((await api('POST', `/${o.id}/chat/${A.user.id}`, B.token, { client_id: 'b-dm', text: 'هاه' })).body.error, 'blocked');
  assert.equal((await api('POST', `/${o.id}/chat/${B.user.id}`, A.token, { client_id: 'a-dm', text: 'هاه' })).body.error, 'blocked');

  /* realtime + push: not delivered to A, still to C */
  const la = live(A.token, o.id);
  const lc = live(C.token, o.id);
  await Promise.all([la.ready, lc.ready]);
  pushed.length = 0;
  await api('POST', `/${o.id}/chat/group`, B.token, { client_id: 'b-2', text: 'مرة ثانية' });
  await lc.until((m) => m.type === 'chat_message' && m.message.client_id === 'b-2');
  await settle(300);
  assert.ok(!la.inbox.some((m) => m.type === 'chat_message' && m.message.client_id === 'b-2'), 'no live frame for the blocker');

  /* SOS from the blocked person still reaches the blocker (safety beats blocking) */
  assert.equal((await api('POST', `/${o.id}/sos`, B.token, { fix: null })).status, 200);
  const sos = await la.until((m) => m.type === 'sos');
  assert.equal(sos.user_id || sos.sos?.user_id, B.user.id);

  /* voice notes: the list skips a blocked sender (no auto-play, no listing) */
  await pool.query(
    `INSERT INTO sary.ptt_voice_notes (outing_id, channel, sender_id, client_id, mime, duration_ms, bytes, audio)
     VALUES ($1, '1', $2, 'vn-1', 'audio/mp4', 1500, 3, '\\x000102')`,
    [o.id, B.user.id],
  );
  const notesA = (await api('GET', `/${o.id}/voice-notes?channel=1`, A.token)).body.notes;
  const notesC = (await api('GET', `/${o.id}/voice-notes?channel=1`, C.token)).body.notes;
  assert.equal(notesA.length, 0, 'blocked sender: no voice notes for me');
  assert.equal(notesC.length, 1);

  /* unblock: back to normal */
  assert.equal((await api('DELETE', `/me/blocks/${B.user.id}`, A.token)).body.blocked, false);
  assert.equal((await api('GET', '/me/blocks', A.token)).body.blocks.length, 0);
  assert.ok((await api('GET', `/${o.id}/chat/group`, A.token)).body.messages.some((m) => m.sender_id === B.user.id));
  assert.equal((await api('POST', `/${o.id}/chat/${A.user.id}`, B.token, { client_id: 'b-dm2', text: 'آسف' })).status, 201);
  void pushed;
});
