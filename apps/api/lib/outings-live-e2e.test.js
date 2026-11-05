'use strict';

/**
 * «قناة الطلعة» end to end over real WebSockets, no database: two phones on the live
 * socket (lib/outings/ws.js + hub + ptt relay), A holds the floor and talks, B must
 * receive every audio frame, in order, byte for byte — including the pre-roll burst a
 * phone sends the moment it is granted, a listener that reconnects mid-sentence, and the
 * auth timing that used to close sockets with 4401 (which phones treat as "signed out").
 *
 *   node --test apps/api/lib/outings-live-e2e.test.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const WebSocket = require('ws');
const { attachOutingsSocket, AUTH_TIMEOUT_CODE } = require('./outings/ws');
const { createHub } = require('./outings/hub');
const { createPttRelay } = require('./outings/ptt');

const OUTING = '47ba65dc-0000-4000-8000-000000000001';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function until(pred, ms = 3000, what = 'condition') {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (pred()) return;
    await sleep(10);
  }
  throw new Error(`timeout waiting for ${what}`);
}

async function lab({ authDelayMs = 0, authTimeoutMs = 300 } = {}) {
  const users = { 'tok-a': { id: 'ua', display_name: 'فهد' }, 'tok-b': { id: 'ub', display_name: 'سعد' } };
  const service = {
    async authenticate(token) {
      if (authDelayMs) await sleep(authDelayMs);
      return users[token] || null;
    },
    async membership(outingId, userId) {
      return outingId === OUTING && ['ua', 'ub'].includes(userId) ? { status: 'active', outing_status: 'active', role: 'member' } : null;
    },
    async getOuting(user) {
      return { outing: { id: OUTING, status: 'active' }, me: { user_id: user.id }, members: [], positions: [] };
    },
  };
  const hub = createHub();
  const ptt = createPttRelay({ hub, service, log: () => {} });
  const server = http.createServer();
  const socket = attachOutingsSocket(server, { service, hub, ptt, authTimeoutMs, heartbeatMs: 60_000 });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;

  function phone(token, { auth = true } = {}) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    const inbox = [];
    const bin = [];
    let closeCode = null;
    let closeReason = null;
    ws.on('message', (d, isBinary) => (isBinary ? bin.push(Buffer.from(d)) : inbox.push(JSON.parse(String(d)))));
    ws.on('close', (c, r) => {
      closeCode = c;
      closeReason = String(r);
    });
    const opened = new Promise((r) => ws.on('open', r)).then(() => {
      if (auth) ws.send(JSON.stringify({ type: 'auth', token, outing_id: OUTING }));
    });
    const next = async (type, ms = 3000) => {
      await until(() => inbox.some((m) => m.type === type), ms, type);
      return inbox.splice(inbox.findIndex((m) => m.type === type), 1)[0];
    };
    return {
      ws,
      inbox,
      bin,
      opened,
      next,
      send: (m) => ws.send(JSON.stringify(m)),
      get closeCode() {
        return closeCode;
      },
      get closeReason() {
        return closeReason;
      },
    };
  }

  return {
    hub,
    ptt,
    socket,
    phone,
    async close() {
      socket.close();
      await new Promise((r) => server.close(r));
    },
  };
}

/** A PTT frame as the iOS app sends it: [v=1][burst][seq u16 BE][codec + AAC-ELD packet]. */
function frame(burst, seq, size = 96) {
  const f = Buffer.alloc(size, seq % 251);
  f[0] = 1;
  f[1] = burst;
  f.writeUInt16BE(seq & 0xffff, 2);
  return f;
}

test('A talks, B hears every frame in order (pre-roll burst + 2 s of 30 ms frames)', async () => {
  const L = await lab();
  try {
    const a = L.phone('tok-a');
    const b = L.phone('tok-b');
    await Promise.all([a.opened, b.opened]);
    await a.next('ready');
    await b.next('ready');
    a.send({ type: 'ptt_join' });
    b.send({ type: 'ptt_join' });
    await a.next('ptt_state');
    assert.equal((await b.next('ptt_state')).talker, null);

    a.send({ type: 'ptt_start', id: 1 });
    const grant = await a.next('ptt_grant');
    const talker = await b.next('ptt_talker');
    assert.equal(talker.user_id, 'ua');
    assert.equal(talker.burst, grant.burst);

    /* The phone flushes what it recorded while waiting for the grant (≤ 20 frames) at once. */
    const sent = [];
    for (let i = 0; i < 20; i++) sent.push(frame(grant.burst, i));
    for (const f of sent) a.ws.send(f);
    /* …then real time: 30 ms packets for ~2 s. */
    for (let i = 20; i < 86; i++) {
      const f = frame(grant.burst, i, 80 + (i % 40));
      sent.push(f);
      a.ws.send(f);
      await sleep(30);
    }
    await until(() => b.bin.length === sent.length, 3000, 'all frames at B');
    assert.deepEqual(b.bin, sent, 'byte for byte, in order, nothing dropped');
    assert.equal(a.bin.length, 0, 'never echoed to the talker');
    assert.equal(L.ptt.stats.dropped, 0);

    a.send({ type: 'ptt_stop' });
    assert.equal((await b.next('ptt_idle')).reason, 'released');
    a.ws.close();
    b.ws.close();
  } finally {
    await L.close();
  }
});

test('B reconnects mid-sentence: the new socket gets the talker and the catch-up frames', async () => {
  const L = await lab();
  try {
    const a = L.phone('tok-a');
    const b1 = L.phone('tok-b');
    await Promise.all([a.opened, b1.opened]);
    await a.next('ready');
    await b1.next('ready');
    a.send({ type: 'ptt_join' });
    b1.send({ type: 'ptt_join' });
    await b1.next('ptt_state');
    a.send({ type: 'ptt_start', id: 1 });
    const { burst } = await a.next('ptt_grant');
    const early = [0, 1, 2, 3, 4].map((i) => frame(burst, i));
    for (const f of early) a.ws.send(f);
    await until(() => b1.bin.length === 5);

    b1.ws.terminate(); // the tunnel
    const b2 = L.phone('tok-b');
    await b2.opened;
    await b2.next('ready');
    b2.send({ type: 'ptt_join' });
    const st = await b2.next('ptt_state');
    assert.equal(st.talker?.user_id, 'ua', 'floor state restored after the reconnect');
    await until(() => b2.bin.length === 5, 2000, 'catch-up');
    assert.deepEqual(b2.bin, early);
    const more = frame(burst, 5);
    a.ws.send(more);
    await until(() => b2.bin.length === 6);
    assert.deepEqual(b2.bin[5], more);
    a.ws.close();
    b2.ws.close();
  } finally {
    await L.close();
  }
});

test('a slow auth is waited for, not closed with 4401; a silent socket gets 4408', async () => {
  /* The database takes longer than the auth timeout: the socket must still become ready. */
  const slow = await lab({ authDelayMs: 450, authTimeoutMs: 200 });
  try {
    const a = slow.phone('tok-a');
    await a.opened;
    await a.next('ready', 3000);
    assert.equal(a.closeCode, null);
    a.ws.close();

    /* Never sends auth: closed with a code phones retry on (not 4401 «unauthorized»). */
    const mute = slow.phone('tok-a', { auth: false });
    await mute.opened;
    await until(() => mute.closeCode !== null, 2000, 'auth timeout close');
    assert.equal(mute.closeCode, AUTH_TIMEOUT_CODE);
    assert.equal(mute.closeReason, 'auth_timeout');

    /* A real bad token is still 4401. */
    const bad = slow.phone('tok-x');
    await bad.opened;
    await until(() => bad.closeCode !== null, 3000, 'unauthorized');
    assert.equal(bad.closeCode, 4401);
  } finally {
    await slow.close();
  }
});

test('a phone that gives up during auth is never seated in the room', async () => {
  const L = await lab({ authDelayMs: 200, authTimeoutMs: 1000 });
  try {
    const a = L.phone('tok-a');
    await a.opened;
    a.ws.terminate(); // gone before the auth answer
    await sleep(400);
    assert.equal(L.hub.connectionsOf(OUTING, 'ua').length, 0, 'no ghost socket');
    assert.equal(L.hub.onlineUsers(OUTING).has('ua'), false, 'not shown online');
    const st = L.socket.stats();
    assert.equal(st.ready, 0);
    assert.ok(st.closes['1006'] >= 1);
  } finally {
    await L.close();
  }
});
