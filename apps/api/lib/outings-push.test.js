'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const express = require('express');
const http = require('http');
const { createPushNotifier, createWebPushSender, pushConfigFromEnv, parseSubscription, pushPayloadFor } = require('./outings/push');
const createOutingsRouter = require('../routes/outings');

function browserKeys() {
  const ecdh = crypto.createECDH('prime256v1');
  ecdh.generateKeys();
  return { p256dh: ecdh.getPublicKey().toString('base64url'), auth: crypto.randomBytes(16).toString('base64url') };
}

const ON = { enabled: true, publicKey: 'BPub', privateKey: 'priv' };

/* A pool that answers the notifier's queries from fixed rows and records every call. */
function fakePool(rows) {
  const calls = [];
  return {
    calls,
    query: async (text, params) => {
      calls.push({ text: text.replace(/\s+/g, ' ').trim(), params });
      if (/^SELECT s\.id/.test(calls.at(-1).text)) return { rows };
      return { rows: [] };
    },
  };
}

test('push config: off unless all three VAPID values are set', () => {
  assert.equal(pushConfigFromEnv({}).enabled, false);
  assert.equal(pushConfigFromEnv({ VAPID_PUBLIC_KEY: 'a', VAPID_PRIVATE_KEY: 'b' }).enabled, false);
  assert.equal(pushConfigFromEnv({ VAPID_PUBLIC_KEY: 'a', VAPID_PRIVATE_KEY: 'b', VAPID_SUBJECT: 'nope' }).enabled, false, 'subject must be mailto: or https:');
  const on = pushConfigFromEnv({ VAPID_PUBLIC_KEY: ' a ', VAPID_PRIVATE_KEY: 'b', VAPID_SUBJECT: 'mailto:ops@example.com' });
  assert.deepEqual([on.enabled, on.publicKey], [true, 'a']);
  assert.equal(pushConfigFromEnv({ VAPID_PRIVATE_KEY: 'b', VAPID_SUBJECT: 'mailto:x@y' }).privateKey, null, 'no half-config leaks the private key');
});

test('disabled notifier: public config says off, nothing is queried or sent', async () => {
  const pool = fakePool([]);
  let sent = 0;
  const n = createPushNotifier({ pool, config: { enabled: false }, sender: { send: async () => { sent += 1; } } });
  assert.equal(n.enabled, false);
  assert.deepEqual(n.publicConfig(), { enabled: false, public_key: null });
  assert.deepEqual(await n.subscribe({ id: 'u' }, {}), { ok: false, error: 'push_disabled' });
  const r = await n.notifyMembers('o', 'u', { type: 'note', title: 't', body: 'b' });
  assert.equal(r.sent, 0);
  assert.equal(pool.calls.length, 0);
  assert.equal(sent, 0);
});

test('disabled router: /push/config is public and off, subscribe is 503', async (t) => {
  const service = { authenticate: async () => ({ id: '00000000-0000-4000-8000-000000000001' }) };
  const push = createPushNotifier({ pool: fakePool([]), config: pushConfigFromEnv({}) });
  const app = express();
  app.use('/api/outings', createOutingsRouter({ service, hub: null, push }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const base = `http://127.0.0.1:${server.address().port}/api/outings`;
  const cfg = await (await fetch(`${base}/push/config`)).json();
  assert.deepEqual(cfg, { ok: true, enabled: false, public_key: null });
  const res = await fetch(`${base}/push/subscribe`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${'x'.repeat(43)}` },
    body: JSON.stringify({ subscription: { endpoint: 'https://fcm.googleapis.com/fcm/send/abc', keys: browserKeys() } }),
  });
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error, 'push_disabled');
});

test('subscriptions: only real push services, only well-formed keys', () => {
  const keys = browserKeys();
  const ok = parseSubscription({ endpoint: 'https://fcm.googleapis.com/fcm/send/abc123', keys });
  assert.equal(ok.endpoint, 'https://fcm.googleapis.com/fcm/send/abc123');
  assert.ok(parseSubscription({ endpoint: 'https://web.push.apple.com/QABC', keys }), 'iOS / Safari');
  assert.ok(parseSubscription({ endpoint: 'https://updates.push.services.mozilla.com/wpush/v2/x', keys }), 'Firefox');
  for (const endpoint of [
    'http://fcm.googleapis.com/fcm/send/abc',
    'https://evil.example.com/hook',
    'https://fcm.googleapis.com.evil.com/x',
    'https://user:pw@fcm.googleapis.com/x',
    'https://fcm.googleapis.com:8443/x',
    'https://127.0.0.1/x',
    'not a url',
  ]) assert.equal(parseSubscription({ endpoint, keys }), null, endpoint);
  const ep = 'https://fcm.googleapis.com/fcm/send/abc';
  assert.equal(parseSubscription({ endpoint: ep, keys: { ...keys, auth: 'short' } }), null);
  assert.equal(parseSubscription({ endpoint: ep, keys: { ...keys, p256dh: Buffer.alloc(65, 1).toString('base64url') } }), null, 'not an uncompressed point');
  assert.equal(parseSubscription({ endpoint: ep }), null);
  assert.equal(parseSubscription(null), null);
});

test('notifyMembers: sends to everyone but the sender, skips viewers, deletes 404/410, survives errors', async () => {
  const rows = [
    { id: 'id-ok', user_id: 'u-ok', endpoint: 'https://fcm.googleapis.com/fcm/send/ok', p256dh: 'p', auth: 'a' },
    { id: 'id-gone', user_id: 'u-gone', endpoint: 'https://fcm.googleapis.com/fcm/send/gone', p256dh: 'p', auth: 'a' },
    { id: 'id-404', user_id: 'u-404', endpoint: 'https://fcm.googleapis.com/fcm/send/404', p256dh: 'p', auth: 'a' },
    { id: 'id-500', user_id: 'u-500', endpoint: 'https://fcm.googleapis.com/fcm/send/500', p256dh: 'p', auth: 'a' },
    { id: 'id-view', user_id: 'u-view', endpoint: 'https://fcm.googleapis.com/fcm/send/view', p256dh: 'p', auth: 'a' },
  ];
  const pool = fakePool(rows);
  const sent = [];
  const sender = {
    async send(sub, body, opts) {
      sent.push({ sub, body: JSON.parse(body), opts });
      if (sub.endpoint.endsWith('/gone')) throw Object.assign(new Error('gone'), { statusCode: 410 });
      if (sub.endpoint.endsWith('/404')) throw Object.assign(new Error('nf'), { statusCode: 404 });
      if (sub.endpoint.endsWith('/500')) throw Object.assign(new Error('boom'), { statusCode: 500 });
      return { statusCode: 201 };
    },
  };
  const logs = [];
  const n = createPushNotifier({ pool, config: ON, sender, viewers: () => new Set(['u-view']), log: (...a) => logs.push(a.join(' ')) });
  const r = await n.notifyMembers('o-1', 'u-sender', { type: 'note', title: 'سعد · الثمامة', body: 'بوقف عند المحطة', ttl: 900 });
  assert.deepEqual(r, { sent: 1, removed: 2, failed: 1, skipped: 1 });
  assert.equal(sent.length, 4, 'the viewer is not pushed');
  assert.deepEqual(pool.calls[0].params, ['o-1', 'u-sender'], 'sender excluded in SQL, scoped to the outing');
  assert.match(pool.calls[0].text, /m\.status = 'active' AND o\.status <> 'ended'/, 'active members of an open outing only');
  const del = pool.calls.find((c) => c.text.startsWith('DELETE'));
  assert.deepEqual(del.params[0].sort(), ['id-404', 'id-gone']);
  const p = sent[0].body;
  assert.equal(p.type, 'note');
  assert.equal(p.url, '/outings/o-1');
  assert.equal(p.body, 'بوقف عند المحطة');
  assert.equal(sent[0].opts.ttl, 900);
  assert.ok(logs.every((l) => !l.includes('fcm.googleapis.com')), 'endpoints never logged');

  const sos = await n.notifyMembers('o-1', 'u-sender', { type: 'sos', title: 'x', body: 'y', always: true, urgency: 'high' });
  assert.equal(sos.skipped, 0, 'SOS reaches viewers too');
  assert.equal(sent.at(-1).opts.urgency, 'high');
});

test('notifyMembers never throws when the database does', async () => {
  const n = createPushNotifier({ pool: { query: async () => { throw new Error('down'); } }, config: ON, sender: { send: async () => ({}) }, log: () => {} });
  const r = await n.notifyMembers('o', null, { type: 'note' });
  assert.equal(r.sent, 0);
});

test('event → push payload: notes and SOS, nothing else', () => {
  const note = pushPayloadFor({ type: 'member_note', user_id: 'u', note: { text: 'وصلنا' } }, { senderName: 'سعد', outingName: 'الثمامة' });
  assert.deepEqual([note.type, note.title, note.body, note.tag], ['note', 'سعد · الثمامة', 'وصلنا', 'sary-note-u']);
  assert.equal(pushPayloadFor({ type: 'member_note', user_id: 'u', note: null }), null, 'a cleared note is not pushed');
  const sos = pushPayloadFor({ type: 'sos', user_id: 'u', text: 'علقنا بالرمل' }, { senderName: 'سعد' });
  assert.equal(sos.type, 'sos');
  assert.equal(sos.always, true);
  assert.equal(sos.urgency, 'high');
  assert.match(sos.title, /سعد/);
  assert.equal(sos.body, 'علقنا بالرمل');
  assert.ok(pushPayloadFor({ type: 'sos', user_id: 'u' }).body, 'SOS without text still says something');
  /* The shape outing-safety (#24) emits: raise → alarm; refresh → nothing; «أنا بخير» → quiet replacement. */
  const raised = pushPayloadFor({ type: 'sos', user_id: 'u', sos: { at: 'x', fix: null } }, { senderName: 'سعد' });
  assert.equal(raised.type, 'sos');
  assert.equal(raised.urgency, 'high');
  assert.equal(pushPayloadFor({ type: 'sos', user_id: 'u', sos: { at: 'x', fix: null }, refresh: true }), null, 'a refresh is not a second alarm');
  const clear = pushPayloadFor({ type: 'sos', user_id: 'u', sos: null }, { senderName: 'سعد' });
  assert.equal(clear.type, 'sos_clear');
  assert.equal(clear.tag, raised.tag, 'replaces the SOS notification');
  assert.equal(clear.urgency, 'normal');
  assert.match(clear.title, /سعد بخير/);
  for (const type of ['position', 'member_link', 'presence', 'outing_status']) assert.equal(pushPayloadFor({ type }), null, type);
});

test('the real sender: VAPID-signed, aes128gcm-encrypted, TTL and urgency set', () => {
  const webpush = require('web-push');
  const vapid = webpush.generateVAPIDKeys();
  const sender = createWebPushSender({ publicKey: vapid.publicKey, privateKey: vapid.privateKey, subject: 'mailto:ops@example.com' });
  const plain = JSON.stringify({ title: 'سعد', body: 'بوقف عند المحطة' });
  const req = sender.describe({ endpoint: 'https://fcm.googleapis.com/fcm/send/abc', keys: browserKeys() }, plain, { ttl: 900, urgency: 'high' });
  assert.equal(req.method, 'POST');
  assert.equal(req.endpoint, 'https://fcm.googleapis.com/fcm/send/abc');
  assert.equal(req.headers['Content-Encoding'], 'aes128gcm');
  assert.equal(req.headers.TTL, 900);
  assert.equal(req.headers.Urgency, 'high');
  assert.match(req.headers.Authorization, new RegExp(`^vapid t=[^,]+, k=${vapid.publicKey}$`));
  assert.ok(!req.body.includes(Buffer.from('بوقف')), 'payload is encrypted on the wire');
});
