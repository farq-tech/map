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
/* When each text message arrived (performance.now()), without changing its shape. */
const arrivedAt = new WeakMap();

async function until(pred, ms = 3000, what = 'condition') {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (pred()) return;
    await sleep(10);
  }
  throw new Error(`timeout waiting for ${what}`);
}

async function lab({ authDelayMs = 0, authTimeoutMs = 300, channels, membershipDelayMs = 0 } = {}) {
  const users = {
    'tok-a': { id: 'ua', display_name: 'فهد' },
    'tok-b': { id: 'ub', display_name: 'سعد' },
    'tok-c': { id: 'uc', display_name: 'نورة' },
    'tok-d': { id: 'ud', display_name: 'ريم' },
  };
  const service = {
    async authenticate(token) {
      if (authDelayMs) await sleep(authDelayMs);
      return users[token] || null;
    },
    membershipCalls: 0,
    async membership(outingId, userId) {
      service.membershipCalls += 1;
      /* A real database answers in a few ms… or, from a phone on a weak link, much later. */
      if (membershipDelayMs) await sleep(membershipDelayMs);
      if (outingId !== OUTING || !['ua', 'ub', 'uc', 'ud'].includes(userId)) return null;
      return { status: 'active', outing_status: 'active', role: userId === 'ua' ? 'owner' : 'member' };
    },
    async getOuting(user) {
      return { outing: { id: OUTING, status: 'active' }, me: { user_id: user.id }, members: [], positions: [] };
    },
    /* «المحادثات» / «إذاعة الطلعة», just enough to answer: each awaits like the real ones. */
    async chatSocketFrame(user, outingId, msg) {
      if (membershipDelayMs) await sleep(membershipDelayMs);
      return { type: 'chat_ack', id: msg.id ?? null, ok: true, message: { from: user.id, outing_id: outingId, text: msg.text } };
    },
    async groupAudioCommand(user, outingId, cmd) {
      if (membershipDelayMs) await sleep(membershipDelayMs);
      return { group_audio: { cmd: cmd?.op || null, by: user.id }, server_now: new Date().toISOString() };
    },
    async getGroupAudio() {
      if (membershipDelayMs) await sleep(membershipDelayMs);
      return { group_audio: null, server_now: new Date().toISOString() };
    },
  };
  const hub = createHub();
  const ptt = createPttRelay({ hub, service, ...(channels ? { channels } : {}), log: () => {} });
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
    ws.on('message', (d, isBinary) => {
      if (isBinary) return bin.push(Buffer.from(d));
      const m = JSON.parse(String(d));
      arrivedAt.set(m, performance.now());
      inbox.push(m);
    });
    ws.on('close', (c, r) => {
      closeCode = c;
      closeReason = String(r);
    });
    const opened = new Promise((r) => ws.on('open', r)).then(() => {
      if (auth) ws.send(JSON.stringify({ type: 'auth', token, outing_id: OUTING }));
    });
    const next = async (type, ms = 3000, pred = () => true) => {
      const hit = (m) => m.type === type && pred(m);
      await until(() => inbox.some(hit), ms, type);
      return inbox.splice(inbox.findIndex(hit), 1)[0];
    };
    /* When each binary frame arrived (performance.now()), for the latency budget. */
    const binAt = [];
    ws.on('message', (_d, isBinary) => {
      if (isBinary) binAt.push(performance.now());
    });
    return {
      ws,
      inbox,
      bin,
      binAt,
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

/* ---------------- «ترددات»: channels over the same two-phone lab ---------------- */

const PRIVATE = '9b2f0c1e-7a6d-4c3b-8e2a-5d4c3b2a1f00';

/** The registry's contract (lib/outings/ptt-channels.js), in memory: one private channel. */
function fakeChannels(members) {
  let relay = null;
  const pub = ['1', '2', '3', '4', '5'];
  return {
    members,
    async load() {},
    loaded: () => true,
    isAllowed: (_o, id, u) => pub.includes(id) || (id === PRIVATE && members.has(u)),
    view: (_o, u, _m, live) => [
      ...pub.map((id) => ({ id, kind: 'public', name: `تردد ${id}`, ...live(id) })),
      ...(members.has(u) ? [{ id: PRIVATE, kind: 'private', name: 'الأمامية', members: [...members], ...live(PRIVATE) }] : []),
    ],
    setRelay(r) {
      relay = r;
    },
    get relay() {
      return relay;
    },
  };
}

async function seated(L, tokens) {
  const ps = tokens.map((t) => L.phone(t));
  await Promise.all(ps.map((p) => p.opened));
  for (const p of ps) await p.next('ready');
  return ps;
}

test('channels: two talkers at once on «تردد ١» and «تردد ٣», each heard only on their own channel; an old phone stays on ١', async () => {
  const L = await lab();
  try {
    const [a, b, c, d] = await seated(L, ['tok-a', 'tok-b', 'tok-c', 'tok-d']);
    a.send({ type: 'ptt_join', channel: '1', channels: true });
    b.send({ type: 'ptt_join' }); // build 9–12: no channel, no `channels` flag
    c.send({ type: 'ptt_join', channel: '3', channels: true });
    d.send({ type: 'ptt_join', channel: '3', channels: true });
    assert.equal((await a.next('ptt_state')).channel, '1');
    assert.equal((await b.next('ptt_state')).channel, '1', 'an old client lands on «تردد ١»');
    assert.equal((await c.next('ptt_state')).channel, '3');
    await d.next('ptt_state');
    const list = await c.next('ptt_channels', 3000, (m) => m.channels.find((x) => x.id === '3').listeners.length === 2);
    assert.deepEqual(list.channels.map((x) => x.id), ['1', '2', '3', '4', '5']);
    assert.equal(list.current, '3');

    /* Both floors at once: one talker per channel, not per trip. */
    a.send({ type: 'ptt_start', id: 1 });
    c.send({ type: 'ptt_start', id: 2 });
    const ga = await a.next('ptt_grant');
    const gc = await c.next('ptt_grant');
    assert.equal(ga.channel, '1');
    assert.equal(gc.channel, '3');
    assert.notEqual(ga.burst, gc.burst, 'bursts stay unique across the trip');
    assert.equal((await b.next('ptt_talker')).user_id, 'ua');
    assert.equal((await d.next('ptt_talker')).user_id, 'uc');
    d.send({ type: 'ptt_start', id: 3 });
    assert.deepEqual((await d.next('ptt_deny')).talker_id, 'uc', '«تردد ٣» is busy with C');

    const fa = [0, 1, 2, 3].map((i) => frame(ga.burst, i));
    const fc = [0, 1, 2].map((i) => frame(gc.burst, i, 70));
    for (const f of fa) a.ws.send(f);
    for (const f of fc) c.ws.send(f);
    await until(() => b.bin.length === 4 && d.bin.length === 3, 3000, 'both channels relayed');
    await sleep(60);
    assert.deepEqual(b.bin, fa, '«تردد ١» hears A only');
    assert.deepEqual(d.bin, fc, '«تردد ٣» hears C only');
    assert.equal(a.bin.length + c.bin.length, 0);
    assert.equal(b.inbox.some((m) => m.type === 'ptt_channels'), false, 'old clients never get channel lists');
    assert.equal(b.inbox.some((m) => m.type === 'ptt_talker' && m.user_id === 'uc'), false);
    a.send({ type: 'ptt_stop' });
    c.send({ type: 'ptt_stop' });
    assert.equal((await b.next('ptt_idle')).channel, '1');
    assert.equal((await d.next('ptt_idle')).channel, '3');
    for (const p of [a, b, c, d]) p.ws.close();
  } finally {
    await L.close();
  }
});

test('channels: switching mid-sentence ends the old one quietly and tunes into the new one from its start', async () => {
  const L = await lab();
  try {
    const [a, b, c] = await seated(L, ['tok-a', 'tok-b', 'tok-c']);
    a.send({ type: 'ptt_join', channel: '2', channels: true });
    b.send({ type: 'ptt_join', channel: '1', channels: true });
    c.send({ type: 'ptt_join', channel: '1', channels: true });
    for (const p of [a, b, c]) await p.next('ptt_state');
    a.send({ type: 'ptt_start', id: 1 });
    c.send({ type: 'ptt_start', id: 1 });
    const ga = await a.next('ptt_grant');
    const gc = await c.next('ptt_grant');
    const fa = [0, 1, 2].map((i) => frame(ga.burst, i));
    for (const f of fa) a.ws.send(f);
    c.ws.send(frame(gc.burst, 0));
    await until(() => b.bin.length === 1);

    const t0 = performance.now();
    b.send({ type: 'ptt_join_channel', channel: '2' });
    const idle = await b.next('ptt_idle');
    const idleMs = arrivedAt.get(idle) - t0;
    assert.deepEqual([idle.user_id, idle.reason, idle.channel], ['uc', 'switched', '1'], 'what we heard on ١ ends for us only');
    const st = await b.next('ptt_state');
    assert.equal(st.channel, '2');
    assert.equal(st.talker.user_id, 'ua');
    await until(() => b.bin.length === 4, 2000, 'catch-up on ٢');
    const switchMs = b.binAt[1] - t0;
    test.diagnostic?.(`switch → old channel silenced: ${idleMs.toFixed(1)} ms`);
    assert.deepEqual(b.bin.slice(1), fa, 'the sentence on ٢ from its start');
    assert.ok(switchMs < 150, `switch → audio of the new channel in ${switchMs.toFixed(1)} ms`);
    test.diagnostic?.(`switch → first frame of the new channel: ${switchMs.toFixed(1)} ms`);
    assert.equal(L.ptt.state(OUTING, '1').user_id, 'uc', 'C still talks on ١');

    /* The talker switching away gives up the floor. */
    c.send({ type: 'ptt_join_channel', channel: '4' });
    assert.equal((await c.next('ptt_idle')).reason, 'left');
    assert.equal(L.ptt.state(OUTING, '1'), null);
    for (const p of [a, b, c]) p.ws.close();
  } finally {
    await L.close();
  }
});

test('private channel: only invited sockets join, hear or talk; a removed member is off the air at once; closing kicks everyone', async () => {
  const reg = fakeChannels(new Set(['ua', 'ub']));
  const L = await lab({ channels: reg });
  try {
    const [a, b, c, d] = await seated(L, ['tok-a', 'tok-b', 'tok-c', 'tok-d']);
    a.send({ type: 'ptt_join', channel: PRIVATE, channels: true });
    b.send({ type: 'ptt_join', channel: PRIVATE, channels: true });
    c.send({ type: 'ptt_join', channel: PRIVATE, channels: true }); // not invited
    d.send({ type: 'ptt_join' }); // old phone
    assert.equal((await a.next('ptt_state')).channel, PRIVATE);
    assert.equal((await b.next('ptt_state')).channel, PRIVATE);
    assert.deepEqual(await c.next('ptt_channel_kicked'), { type: 'ptt_channel_kicked', channel: PRIVATE, reason: 'not_invited' });
    assert.equal((await c.next('ptt_state')).channel, '1', 'refused → «تردد ١»');
    c.send({ type: 'ptt_join_channel', channel: PRIVATE });
    await c.next('ptt_channel_kicked');
    await d.next('ptt_state');
    const cl = await c.next('ptt_channels');
    assert.equal(cl.channels.some((x) => x.id === PRIVATE), false, 'C does not even see it');

    a.send({ type: 'ptt_start', id: 1 });
    const g = await a.next('ptt_grant');
    assert.equal(g.channel, PRIVATE);
    await b.next('ptt_talker');
    const fs = [0, 1, 2, 3, 4].map((i) => frame(g.burst, i));
    for (const f of fs.slice(0, 3)) a.ws.send(f);
    await until(() => b.bin.length === 3);
    await sleep(80);
    assert.equal(c.bin.length + d.bin.length, 0, 'nothing reaches anyone not invited');
    assert.equal(c.inbox.concat(d.inbox).some((m) => m.type === 'ptt_talker'), false, 'not even who talks');

    /* The leader removes B mid-sentence: B is moved to ١ before the next frame. */
    reg.members.delete('ub');
    reg.relay.kick(OUTING, PRIVATE, new Set(['ub']), 'removed');
    assert.equal((await b.next('ptt_channel_kicked')).reason, 'removed');
    assert.equal((await b.next('ptt_state')).channel, '1');
    for (const f of fs.slice(3)) a.ws.send(f);
    await sleep(120);
    assert.equal(b.bin.length, 3, 'not one more frame after the removal');

    /* B, kicked, cannot sneak back. */
    b.send({ type: 'ptt_join_channel', channel: PRIVATE });
    await b.next('ptt_channel_kicked');

    /* Close: the talker is cut and moved too. */
    reg.members.clear();
    reg.relay.kick(OUTING, PRIVATE, null, 'closed');
    assert.equal((await a.next('ptt_idle', 3000, (m) => m.channel === PRIVATE)).reason, 'closed');
    assert.equal((await a.next('ptt_channel_kicked')).reason, 'closed');
    assert.equal(L.ptt.state(OUTING, PRIVATE), null);
    for (const p of [a, b, c, d]) p.ws.close();
  } finally {
    await L.close();
  }
});

test('latency budget: the first audio frame reaches the listener in ≤ 10 ms (p50) / 50 ms (p95) of the talker sending it (loopback)', async () => {
  const L = await lab();
  try {
    const [a, b] = await seated(L, ['tok-a', 'tok-b']);
    a.send({ type: 'ptt_join', channel: '3', channels: true });
    b.send({ type: 'ptt_join', channel: '3', channels: true });
    await a.next('ptt_state');
    await b.next('ptt_state');
    const samples = { grant: [], talker: [], first: [], frame: [] };
    for (let round = 0; round < 12; round++) { // ≤ 40 text frames per 10 s per socket (ws.js)
      const t0 = performance.now();
      a.send({ type: 'ptt_start', id: round });
      const g = await a.next('ptt_grant');
      samples.grant.push(arrivedAt.get(g) - t0);
      samples.talker.push(arrivedAt.get(await b.next('ptt_talker')) - t0);
      const n0 = b.bin.length;
      const sentAt = [];
      for (let i = 0; i < 5; i++) {
        sentAt.push(performance.now());
        a.ws.send(frame(g.burst, i));
        await sleep(30);
      }
      await until(() => b.bin.length === n0 + 5);
      samples.first.push(b.binAt[n0] - sentAt[0]);
      for (let i = 0; i < 5; i++) samples.frame.push(b.binAt[n0 + i] - sentAt[i]);
      a.send({ type: 'ptt_stop' });
      await b.next('ptt_idle');
    }
    const pct = (xs, p) => [...xs].sort((x, y) => x - y)[Math.min(xs.length - 1, Math.floor(xs.length * p))];
    const line = Object.entries(samples).map(([k, xs]) => `${k} p50=${pct(xs, 0.5).toFixed(2)} p95=${pct(xs, 0.95).toFixed(2)} ms`).join(' · ');
    test.diagnostic?.(line);
    console.log(`[ptt latency] ${line}`);
    /* The server's share of the ≤ 150 ms press-to-ear budget (the phone's jitter buffer + squelch take the rest). */
    assert.ok(pct(samples.first, 0.5) < 10, `first frame p50 ${pct(samples.first, 0.5).toFixed(2)} ms`);
    assert.ok(pct(samples.first, 0.95) < 50, `first frame p95 ${pct(samples.first, 0.95).toFixed(2)} ms`);
    assert.ok(pct(samples.talker, 0.95) < 50, 'listener learns who is on air within 50 ms of the press');
    a.ws.close();
    b.ws.close();
  } finally {
    await L.close();
  }
});

/* ---------------- order: a socket's frames are handled in the order they arrived ---------------- */

test('reconnect: ptt_join + the deferred ptt_start sent back to back (slow membership check) → granted, not «مكتوم»', async () => {
  const L = await lab({ membershipDelayMs: 60 });
  try {
    const [a, b] = await seated(L, ['tok-a', 'tok-b']);
    b.send({ type: 'ptt_join', channels: true });
    await b.next('ptt_state');
    /* A drops (tunnel) and comes back: the app re-joins and replays the press it held back. */
    a.ws.terminate();
    await sleep(50);
    const a2 = L.phone('tok-a');
    await a2.opened;
    await a2.next('ready');
    a2.send({ type: 'ptt_join', channels: true });
    a2.send({ type: 'ptt_start', id: 7 });
    const g = await a2.next('ptt_grant', 3000);
    assert.equal(g.id, 7);
    assert.equal(g.channel, '1');
    assert.equal(a2.inbox.some((m) => m.type === 'ptt_deny'), false, 'never denied not_joined');
    /* The join's answer came before the grant, as sent. */
    assert.equal((await b.next('ptt_talker')).user_id, 'ua');
    a2.ws.send(frame(g.burst, 0));
    a2.ws.send(frame(g.burst, 1));
    await until(() => b.bin.length === 2, 3000, 'audio after the raced grant');
    a2.send({ type: 'ptt_stop' });
    assert.equal((await b.next('ptt_idle')).reason, 'released');
    a2.ws.close();
    b.ws.close();
  } finally {
    await L.close();
  }
});

test('reconnect: auth + ptt_join + ptt_start in one burst (before `ready`) → seated, joined, granted in that order', async () => {
  const L = await lab({ membershipDelayMs: 40 });
  try {
    const [b] = await seated(L, ['tok-b']);
    b.send({ type: 'ptt_join' }); // build 9–12 listener
    await b.next('ptt_state');
    const a = L.phone('tok-a', { auth: false });
    await a.opened;
    a.send({ type: 'auth', token: 'tok-a', outing_id: OUTING });
    a.send({ type: 'ptt_join' }); // an old build: no channels flag
    a.send({ type: 'ptt_start', id: 1 });
    const g = await a.next('ptt_grant', 3000);
    const order = a.inbox.map((m) => m.type);
    assert.equal(order.includes('ptt_deny'), false, order.join(','));
    assert.ok(order.indexOf('ready') !== -1 && order.indexOf('ready') < order.indexOf('ptt_state'), `ready, then the join's state: ${order.join(',')}`);
    assert.equal((await b.next('ptt_talker')).user_id, 'ua');
    a.ws.close();
    b.ws.close();
  } finally {
    await L.close();
  }
});

test('switch channel + ptt_start back to back → granted on the NEW channel, heard only there', async () => {
  const L = await lab({ membershipDelayMs: 60 });
  try {
    const [a, b, c] = await seated(L, ['tok-a', 'tok-b', 'tok-c']);
    a.send({ type: 'ptt_join', channel: '1', channels: true });
    b.send({ type: 'ptt_join', channel: '3', channels: true });
    c.send({ type: 'ptt_join', channel: '1', channels: true });
    await a.next('ptt_state');
    await b.next('ptt_state');
    await c.next('ptt_state');
    a.send({ type: 'ptt_join_channel', channel: '3' });
    a.send({ type: 'ptt_start', id: 2 });
    const g = await a.next('ptt_grant', 3000);
    assert.equal(g.channel, '3', 'the floor is on the channel just switched to');
    assert.equal(a.inbox.some((m) => m.type === 'ptt_deny'), false);
    assert.equal((await b.next('ptt_talker')).channel, '3');
    a.ws.send(frame(g.burst, 0));
    await until(() => b.bin.length === 1, 3000, 'heard on ٣');
    await sleep(80);
    assert.equal(c.bin.length, 0, 'nothing on ١');
    assert.equal(c.inbox.some((m) => m.type === 'ptt_talker'), false);
    assert.equal(L.ptt.state(OUTING, '1'), null);
    for (const p of [a, b, c]) p.ws.close();
  } finally {
    await L.close();
  }
});

test('private channel isolation holds when join + start race: an uninvited socket is moved to ١ and talks there only', async () => {
  const reg = fakeChannels(new Set(['ua', 'ub']));
  const L = await lab({ channels: reg, membershipDelayMs: 60 });
  try {
    const [a, b, c] = await seated(L, ['tok-a', 'tok-b', 'tok-c']);
    a.send({ type: 'ptt_join', channel: PRIVATE, channels: true });
    b.send({ type: 'ptt_join', channel: '1', channels: true });
    await a.next('ptt_state');
    await b.next('ptt_state');
    /* C (not invited) asks for the private channel and presses at once. */
    c.send({ type: 'ptt_join', channel: PRIVATE, channels: true });
    c.send({ type: 'ptt_start', id: 3 });
    assert.equal((await c.next('ptt_channel_kicked')).reason, 'not_invited');
    const g = await c.next('ptt_grant', 3000);
    assert.equal(g.channel, '1', 'refused → its floor is on «تردد ١», never the private one');
    assert.equal(L.ptt.state(OUTING, PRIVATE), null);
    c.ws.send(frame(g.burst, 0));
    await until(() => b.bin.length === 1, 3000, 'B on ١ hears C');
    await sleep(80);
    assert.equal(a.bin.length, 0, 'the private channel hears nothing');
    assert.equal(a.inbox.some((m) => m.type === 'ptt_talker'), false);
    /* And a switch to it + press, back to back, is still refused. */
    c.send({ type: 'ptt_stop' });
    await b.next('ptt_idle');
    c.send({ type: 'ptt_join_channel', channel: PRIVATE });
    c.send({ type: 'ptt_start', id: 4 });
    await c.next('ptt_channel_kicked');
    const g2 = await c.next('ptt_grant', 3000);
    assert.equal(g2.channel, '1');
    assert.equal(L.ptt.state(OUTING, PRIVATE), null);
    for (const p of [a, b, c]) p.ws.close();
  } finally {
    await L.close();
  }
});

test('chat_* and group_audio_* sent right after auth (before `ready`) are answered, in order, not dropped', async () => {
  const L = await lab({ membershipDelayMs: 40 });
  try {
    const a = L.phone('tok-a', { auth: false });
    await a.opened;
    a.send({ type: 'auth', token: 'tok-a', outing_id: OUTING });
    a.send({ type: 'chat_message', id: 'c1', with: 'group', client_id: 'x1', kind: 'text', text: 'وصلت' });
    a.send({ type: 'group_audio_cmd', id: 'g1', cmd: { op: 'play' } });
    a.send({ type: 'group_audio_sync' });
    a.send({ type: 'chat_message', id: 'c2', with: 'group', client_id: 'x2', kind: 'text', text: 'تمام' });
    await a.next('ready');
    await until(() => a.inbox.filter((m) => /^(chat_ack|group_audio_ack|group_audio_state)$/.test(m.type)).length === 4, 3000, 'all four answered');
    const seen = a.inbox.filter((m) => /^(chat_ack|group_audio_ack|group_audio_state)$/.test(m.type)).map((m) => `${m.type}:${m.id ?? ''}`);
    assert.deepEqual(seen, ['chat_ack:c1', 'group_audio_ack:g1', 'group_audio_state:', 'chat_ack:c2']);
    a.ws.close();
  } finally {
    await L.close();
  }
});

test('one socket stuck on a slow frame never delays another socket’s audio, and its own ping still answers', async () => {
  const L = await lab();
  try {
    const [a, b, c] = await seated(L, ['tok-a', 'tok-b', 'tok-c']);
    a.send({ type: 'ptt_join' });
    b.send({ type: 'ptt_join' });
    await a.next('ptt_state');
    await b.next('ptt_state');
    a.send({ type: 'ptt_start', id: 1 });
    const g = await a.next('ptt_grant');
    /* C's next frame hangs on the "database" for 1.5 s. */
    let release;
    const slow = new Promise((r) => (release = r));
    const orig = L.ptt.handle;
    L.ptt.handle = async (conn, msg) => {
      if (conn.userId === 'uc' && msg.type === 'ptt_join') await slow;
      return orig(conn, msg);
    };
    c.send({ type: 'ptt_join' });
    const t0 = performance.now();
    c.send({ type: 'ping' });
    await c.next('pong', 1000);
    assert.ok(performance.now() - t0 < 200, 'ping is not queued behind the slow frame');
    for (let i = 0; i < 3; i++) a.ws.send(frame(g.burst, i));
    await until(() => b.bin.length === 3, 1000, 'A→B audio while C is stuck');
    release();
    await c.next('ptt_state', 3000);
    L.ptt.handle = orig;
    for (const p of [a, b, c]) p.ws.close();
  } finally {
    await L.close();
  }
});
