'use strict';

/**
 * «ترددات» — walkie-talkie channels: the channel ids, the private-channel
 * routes and who may use them (over a real Postgres, router and WebSockets),
 * the server-side isolation of private channels (join, floor, relay, pushes),
 * and what happens when a member leaves or the trip ends.
 *
 *   node --test apps/api/lib/outings-ptt-channels.test.js                    (pure parts)
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-ptt-channels.test.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { channelId, publicName, canManageOuting, PTT_PUBLIC_CHANNELS, PTT_DEPUTY_CAN_MANAGE, PTT_MAX_PRIVATE } = require('./outings/ptt-channels');
const { createPttRelay } = require('./outings/ptt');
const { createHub } = require('./outings/hub');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- pure ---------------- */

test('channel ids: «تردد ١…٥» are 1–5; a private one is a uuid; anything else is refused', () => {
  assert.deepEqual(PTT_PUBLIC_CHANNELS, ['1', '2', '3', '4', '5']);
  assert.equal(publicName('3'), 'تردد ٣');
  assert.equal(channelId(3), '3');
  assert.equal(channelId('5'), '5');
  for (const bad of ['0', '6', '', null, undefined, {}, '1; drop', 'ABC']) assert.equal(channelId(bad), null, String(bad));
  assert.equal(channelId('9B2F0C1E-7A6D-4C3B-8E2A-5D4C3B2A1F00'), '9b2f0c1e-7a6d-4c3b-8e2a-5d4c3b2a1f00');
  assert.equal(PTT_MAX_PRIVATE, 5);
});

test('who opens private channels: «أمير الرحلة» only (a co-leader too only if the constant says so)', () => {
  assert.equal(PTT_DEPUTY_CAN_MANAGE, false);
  assert.equal(canManageOuting({ status: 'active', role: 'owner' }), true);
  assert.equal(canManageOuting({ status: 'active', role: 'member', co_leader: true }), false);
  assert.equal(canManageOuting({ status: 'active', role: 'member' }), false);
  assert.equal(canManageOuting({ status: 'left', role: 'owner' }), false);
  assert.equal(canManageOuting(null), false);
});

test('pushes for a channel: only members whose radio is on it (and, private, invited); others are never woken', async () => {
  const hub = createHub();
  const calls = [];
  const apns = { enabled: true, notifyPtt: async (_o, _t, opts) => (calls.push(opts), { sent: 0 }) };
  const PRIV = '9b2f0c1e-7a6d-4c3b-8e2a-5d4c3b2a1f00';
  const invited = new Set(['A', 'B']);
  const channels = {
    load: async () => {},
    loaded: () => true,
    isAllowed: (_o, id, u) => ['1', '2', '3', '4', '5'].includes(id) || (id === PRIV && invited.has(u)),
    view: () => [],
  };
  const ptt = createPttRelay({ hub, service: { membership: async () => ({ status: 'active', outing_status: 'active' }) }, apns, channels, log: () => {} });
  const O = '11111111-1111-4111-8111-111111111111';
  const fake = (id) => {
    const c = { ws: { readyState: 1, bufferedAmount: 0, send() {} }, userId: id, user: { id, display_name: id }, outingId: null, window: [] };
    hub.join(O, c);
    return c;
  };
  const [a, b, c, d] = ['A', 'B', 'C', 'D'].map(fake);
  await ptt.handle(a, { type: 'ptt_join', channel: PRIV });
  await ptt.handle(b, { type: 'ptt_join', channel: PRIV });
  await ptt.handle(c, { type: 'ptt_join', channel: '2' });
  await ptt.handle(d, { type: 'ptt_join' });
  /* Everyone's phone goes to the background; B's socket even dies. */
  for (const u of ['B', 'C', 'D']) hub.setAway(O, u, true);
  ptt.drop(b);
  await ptt.handle(a, { type: 'ptt_start', id: 1 });
  await sleep(5);
  const p = calls.at(-1);
  assert.equal(p.channel, PRIV);
  assert.deepEqual(['B', 'C', 'D', 'E'].filter((u) => p.include(u)), ['B'], 'only B: invited and last tuned to it');
  await ptt.handle(a, { type: 'ptt_stop' });
  await ptt.handle(a, { type: 'ptt_join_channel', channel: '1' });
  await ptt.handle(a, { type: 'ptt_start', id: 2 });
  await sleep(5);
  assert.deepEqual(['B', 'C', 'D', 'E'].filter((u) => calls.at(-1).include(u)), ['D', 'E'], '«تردد ١»: D, and E whose channel we never heard');
  ptt.close();
});

/* ---------------- database: routes, authorization, isolation, membership ---------------- */

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_pttch`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('private channels end to end: leader-only routes, invited-only join/listen/talk/push, removal kicks at once, leave & end clean up', { skip, timeout: 60_000 }, async (t) => {
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
    ptt: { silenceMs: 1500, maxTalkMs: 5000 },
    apns: {
      config: { enabled: true, bundleId: 'sa.sary.albarq', key: {} },
      sender: {
        async send(device, req) {
          const body = JSON.parse(req.body);
          (req.headers['apns-push-type'] === 'pushtotalk' ? pttPushes : alerts).push({ token: device.token, body });
          return { status: 200 };
        },
      },
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
    outings.close();
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
        await sleep(10);
      }
      throw new Error('timeout waiting for message');
    };
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    return { ws, inbox, bin, next, opened, send: (m) => ws.send(JSON.stringify(m)) };
  }
  const until = async (pred, ms = 3000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (pred()) return;
      await sleep(10);
    }
    throw new Error('timeout');
  };
  const hex = () => crypto.randomBytes(32).toString('hex');
  const frame = (burst, seq) => {
    const f = Buffer.alloc(90, seq + 1);
    f[0] = 1;
    f[1] = burst;
    f.writeUInt16BE(seq, 2);
    return f;
  };

  const mk = async (name) => (await api('POST', '/me', null, { display_name: name })).body;
  const [A, B, C, D, X] = [await mk('أبو فهد'), await mk('سعد'), await mk('نورة'), await mk('ريم'), await mk('غريب')];
  const created = await api('POST', '/', A.token, { name: 'طلعة النفود' });
  const O = created.body.outing_id;
  for (const p of [B, C, D]) assert.equal((await api('POST', '/invites/join', p.token, { token: created.body.invite.token })).status, 200);
  await api('POST', `/${O}/status`, A.token, { action: 'start' });
  /* C is a co-leader: still not allowed to open private channels (PTT_DEPUTY_CAN_MANAGE = false). */
  assert.equal((await api('POST', `/${O}/members/${C.user.id}/co-leader`, A.token, { co_leader: true })).status, 200);
  const otherTrip = (await api('POST', '/', X.token, { name: 'طلعة ثانية' })).body.outing_id;

  /* ---- GET: five public channels for everyone ---- */
  assert.equal((await api('GET', `/${O}/ptt/channels`, null)).status, 401);
  assert.equal((await api('GET', `/${O}/ptt/channels`, X.token)).status, 404, 'outsider');
  const g0 = (await api('GET', `/${O}/ptt/channels`, B.token)).body;
  assert.deepEqual(g0.channels.map((c) => [c.id, c.kind, c.name]), [
    ['1', 'public', 'تردد ١'],
    ['2', 'public', 'تردد ٢'],
    ['3', 'public', 'تردد ٣'],
    ['4', 'public', 'تردد ٤'],
    ['5', 'public', 'تردد ٥'],
  ]);
  assert.equal(g0.current, '1');
  assert.equal(g0.can_create, false);
  assert.equal((await api('GET', `/${O}/ptt/channels`, A.token)).body.can_create, true);

  /* ---- POST: leader only, active members only, sane names ---- */
  assert.equal((await api('POST', `/${O}/ptt/channels`, B.token, { name: 'خاص', members: [] })).body.error, 'leader_only');
  assert.equal((await api('POST', `/${O}/ptt/channels`, C.token, { name: 'خاص', members: [] })).status, 403, 'co-leader: not by default');
  assert.equal((await api('POST', `/${O}/ptt/channels`, A.token, { name: '   ', members: [] })).body.error, 'invalid_name');
  assert.equal((await api('POST', `/${O}/ptt/channels`, A.token, { name: 'خاص', members: [X.user.id] })).body.error, 'invalid_members', 'not in this trip');
  assert.equal((await api('POST', `/${O}/ptt/channels`, A.token, { name: 'خاص', members: ['not-a-uuid'] })).body.error, 'invalid_members');
  assert.equal((await api('POST', `/${otherTrip}/ptt/channels`, A.token, { name: 'خاص' })).status, 404);

  /* Phones: A, B, C, D new (channel-aware); B is on screen; D is in the background with a PTT token. */
  const tokD = hex();
  const tokC = hex();
  assert.equal((await api('POST', `/${O}/ptt/token`, D.token, { token: tokD, environment: 'sandbox' })).status, 201);
  assert.equal((await api('POST', `/${O}/ptt/token`, C.token, { token: tokC, environment: 'sandbox' })).status, 201);
  const [la, lb, lc, ld] = [live(A.token, O), live(B.token, O), live(C.token, O), live(D.token, O)];
  await Promise.all([la.opened, lb.opened, lc.opened, ld.opened]);
  for (const l of [la, lb, lc, ld]) {
    await l.next((m) => m.type === 'ready');
    l.send({ type: 'ptt_join', channel: '1', channels: true });
    await l.next((m) => m.type === 'ptt_state');
  }

  const made = await api('POST', `/${O}/ptt/channels`, A.token, { name: '‮الأمامية\u0000', members: [B.user.id, D.user.id] });
  assert.equal(made.status, 201);
  const P = made.body.channel.id;
  assert.equal(made.body.channel.name, 'الأمامية', 'bidi overrides and controls stripped');
  assert.equal(made.body.channel.kind, 'private');
  assert.deepEqual(made.body.channel.members.sort(), [A.user.id, B.user.id, D.user.id].sort(), 'the leader is always in it');
  assert.equal(made.body.channel.can_manage, true);

  /* Invited: live «دعاك» on the socket, and an alert push (to D, not on screen… B is on screen, so live only). */
  assert.deepEqual(await lb.next((m) => m.type === 'ptt_channel_invite'), { type: 'ptt_channel_invite', channel: P, name: 'الأمامية', by: A.user.id });
  await ld.next((m) => m.type === 'ptt_channel_invite');
  await sleep(80);
  assert.equal(lc.inbox.some((m) => m.type === 'ptt_channel_invite'), false);
  /* No APNs device tokens registered for alerts in this test: the alert path is covered by its own payload check below. */

  /* Lists: B sees it, C (not invited, even as co-leader) does not, over REST and the socket. */
  assert.ok((await api('GET', `/${O}/ptt/channels`, B.token)).body.channels.some((c) => c.id === P));
  assert.ok(!(await api('GET', `/${O}/ptt/channels`, C.token)).body.channels.some((c) => c.id === P));
  await lc.next((m) => m.type === 'ptt_channels');
  await sleep(60);
  const seenByC = [...lc.inbox].filter((m) => m.type === 'ptt_channels' || m.type === 'ptt_channel_invite');
  assert.ok(!seenByC.some((m) => m.channel === P || m.channels?.some((c) => c.id === P)), 'not on the socket either');
  /* C cannot touch it, and learns nothing about it existing. */
  assert.equal((await api('PATCH', `/${O}/ptt/channels/${P}`, C.token, { add: [C.user.id] })).body.error, 'channel_not_found');
  assert.equal((await api('DELETE', `/${O}/ptt/channels/${P}`, C.token)).body.error, 'channel_not_found');
  assert.equal((await api('PATCH', `/${O}/ptt/channels/${P}`, B.token, { name: 'x' })).body.error, 'leader_only', 'invited is not manager');
  assert.equal((await api('PATCH', `/${O}/ptt/channels/2`, A.token, { name: 'x' })).body.error, 'channel_not_found', 'public ones are fixed');

  /* ---- isolation on the socket: join / floor / relay ---- */
  la.send({ type: 'ptt_join_channel', channel: P });
  lb.send({ type: 'ptt_join_channel', channel: P });
  lc.send({ type: 'ptt_join_channel', channel: P });
  assert.equal((await la.next((m) => m.type === 'ptt_state')).channel, P);
  assert.equal((await lb.next((m) => m.type === 'ptt_state')).channel, P);
  assert.equal((await lc.next((m) => m.type === 'ptt_channel_kicked')).reason, 'not_invited');
  assert.equal((await lc.next((m) => m.type === 'ptt_state')).channel, '1');
  /* D tunes in, then goes to the background (the push must find it on P). */
  ld.send({ type: 'ptt_join_channel', channel: P });
  await ld.next((m) => m.type === 'ptt_state');
  ld.send({ type: 'presence', away: true });
  lc.send({ type: 'presence', away: true });
  await sleep(60);

  la.send({ type: 'ptt_start', id: 1 });
  const g = await la.next((m) => m.type === 'ptt_grant');
  assert.equal(g.channel, P);
  assert.equal((await lb.next((m) => m.type === 'ptt_talker')).channel, P);
  const fs = [0, 1, 2].map((i) => frame(g.burst, i));
  for (const f of fs) la.ws.send(f);
  await until(() => lb.bin.length === 3 && ld.bin.length === 3);
  await sleep(60);
  assert.equal(lc.bin.length, 0, 'C hears nothing of P');
  assert.equal(lc.inbox.some((m) => m.type === 'ptt_talker'), false);
  /* The pushtotalk wake-up went to D (invited, on P, in the background) and never to C. */
  await until(() => pttPushes.length >= 1);
  await sleep(50);
  assert.deepEqual(pttPushes.map((p) => p.token), [tokD]);
  assert.equal(pttPushes[0].body.channel, P);

  /* ---- PATCH remove: B is off the air before the next frame ---- */
  const patched = await api('PATCH', `/${O}/ptt/channels/${P}`, A.token, { remove: [B.user.id], name: 'الأمامية ٢' });
  assert.equal(patched.status, 200);
  assert.equal(patched.body.channel.name, 'الأمامية ٢');
  assert.equal((await lb.next((m) => m.type === 'ptt_channel_kicked')).reason, 'removed');
  assert.equal((await lb.next((m) => m.type === 'ptt_state')).channel, '1');
  la.ws.send(frame(g.burst, 3));
  await until(() => ld.bin.length === 4);
  await sleep(60);
  assert.equal(lb.bin.length, 3, 'not one more frame for B');
  lb.send({ type: 'ptt_join_channel', channel: P });
  assert.equal((await lb.next((m) => m.type === 'ptt_channel_kicked')).reason, 'not_invited');
  assert.equal((await api('PATCH', `/${O}/ptt/channels/${P}`, A.token, { remove: [A.user.id] })).body.error, 'cannot_remove_self');
  la.send({ type: 'ptt_stop' });
  await ld.next((m) => m.type === 'ptt_idle');

  /* Add back C: invited live; C can now join. */
  assert.equal((await api('PATCH', `/${O}/ptt/channels/${P}`, A.token, { add: [C.user.id] })).status, 200);
  await lc.next((m) => m.type === 'ptt_channel_invite');
  lc.send({ type: 'ptt_join_channel', channel: P });
  assert.equal((await lc.next((m) => m.type === 'ptt_state')).channel, P);

  /* ---- limits: five private channels a trip ---- */
  for (let i = 0; i < 4; i++) assert.equal((await api('POST', `/${O}/ptt/channels`, A.token, { name: `خاص ${i}` })).status, 201);
  assert.equal((await api('POST', `/${O}/ptt/channels`, A.token, { name: 'سادس' })).body.error, 'too_many_channels');

  /* ---- leaving the trip takes you off every private channel ---- */
  assert.equal((await api('POST', `/${O}/leave`, D.token)).status, 200);
  const rowsD = await pool.query(`SELECT 1 FROM sary.ptt_channel_members WHERE user_id = $1`, [D.user.id]);
  assert.equal(rowsD.rows.length, 0);
  assert.ok(!(await api('GET', `/${O}/ptt/channels`, A.token)).body.channels.find((c) => c.id === P).members.includes(D.user.id));

  /* ---- DELETE: closes it, everyone on it back to ١ ---- */
  assert.equal((await api('DELETE', `/${O}/ptt/channels/${P}`, A.token)).status, 200);
  assert.equal((await la.next((m) => m.type === 'ptt_channel_kicked')).reason, 'closed');
  assert.equal((await lc.next((m) => m.type === 'ptt_channel_kicked')).reason, 'closed');
  assert.equal((await api('DELETE', `/${O}/ptt/channels/${P}`, A.token)).status, 404);

  /* ---- ending the trip deletes its private channels ---- */
  await api('POST', `/${O}/status`, A.token, { action: 'end' });
  assert.equal((await pool.query(`SELECT count(*)::int AS n FROM sary.ptt_channels WHERE outing_id = $1`, [O])).rows[0].n, 0);
  assert.equal((await pool.query(`SELECT count(*)::int AS n FROM sary.ptt_channel_members`)).rows[0].n, 0);
  /* No audio anywhere. */
  const bytea = (await pool.query(`SELECT table_name FROM information_schema.columns WHERE table_schema = 'sary' AND data_type = 'bytea'`)).rows;
  assert.ok(!bytea.some((c) => /ptt/.test(c.table_name)));
  for (const l of [la, lb, lc, ld]) l.ws.close();
});

test('invite alert: «أمير الرحلة دعاك إلى تردد خاص: …» to the invited person only, with the channel id', async () => {
  const { createPttChannels } = require('./outings/ptt-channels');
  const sent = [];
  const rows = [];
  const O = '11111111-1111-4111-8111-111111111111';
  const L = '00000000-0000-4000-8000-00000000000a';
  const M = '00000000-0000-4000-8000-00000000000b';
  const q = async (text) => {
    if (/FROM sary\.outing_members WHERE outing_id/.test(text)) return [{ user_id: M }];
    if (/COALESCE\(m\.invited_name/.test(text)) return [{ outing_name: 'طلعة النفود', name: 'أبو فهد' }];
    if (/FROM sary\.ptt_channels c/.test(text)) return rows;
    return [];
  };
  const tx = async (fn) =>
    fn(async (text) => {
      if (/count\(\*\)/.test(text)) return [{ n: 0 }];
      if (/INSERT INTO sary\.ptt_channels/.test(text)) return [{ id: '9b2f0c1e-7a6d-4c3b-8e2a-5d4c3b2a1f00', name: 'الأمامية', created_by: L, created_at: new Date() }];
      return [];
    });
  const reg = createPttChannels({
    q,
    tx,
    err: (code, status) => Object.assign(new Error(code), { code, status }),
    requireMember: async () => ({ status: 'active', role: 'owner', outing_status: 'active' }),
    push: { enabled: true, notifyMembers: async (o, except, p) => (sent.push({ o, except, p }), { sent: 1 }) },
  });
  const r = await reg.api.createPttChannel({ id: L }, O, { name: 'الأمامية', members: [M] });
  assert.equal(r.channel.id, '9b2f0c1e-7a6d-4c3b-8e2a-5d4c3b2a1f00');
  await sleep(5);
  assert.equal(sent.length, 1, 'the leader is not told about his own channel');
  assert.equal(sent[0].p.to_user, M);
  assert.equal(sent[0].p.type, 'ptt_channel_invite');
  assert.equal(sent[0].p.body, 'أبو فهد (أمير الرحلة) دعاك إلى تردد خاص: الأمامية');
  assert.equal(sent[0].p.channel_id, r.channel.id);
  assert.equal(reg.isAllowed(O, r.channel.id, M), true);
  assert.equal(reg.isAllowed(O, r.channel.id, '00000000-0000-4000-8000-00000000000c'), false);
  assert.equal(reg.isAllowed('22222222-2222-4222-8222-222222222222', r.channel.id, M), false, 'scoped to its own trip');

  const { apnsRequestFor } = require('./outings/apns');
  const req = apnsRequestFor(sent[0].p, O, { bundleId: 'sa.sary.albarq' });
  const body = JSON.parse(req.body);
  assert.equal(body.type, 'ptt_channel_invite');
  assert.equal(body.channel_id, r.channel.id);
  assert.equal(body.aps['interruption-level'], 'active', 'an invitation is worth a sound');
  assert.equal(body.aps.alert.body, 'أبو فهد (أمير الرحلة) دعاك إلى تردد خاص: الأمامية');
});
