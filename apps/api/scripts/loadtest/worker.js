'use strict';

/**
 * Load generator worker: N outings × 3–6 phones on the real HTTP + WebSocket protocol.
 * Forked by run.js, which sends { cmd: 'start', ... } and polls { cmd: 'snap' }.
 *
 * Latency: each fix encodes a per-sender sequence number in `lng`, so a receiver can match
 * "I got a position from X with seq s" to when X sent it (all phones live in this process,
 * one clock): that is the end-to-end fan-out latency (send → server → receive). `ack` latency is
 * the sender's own round trip.
 */

const WebSocket = require('ws');
const { performance } = require('perf_hooks');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rnd = (a, b) => a + Math.random() * (b - a);

let cfg = null;
let win = null;
function freshWindow() {
  return { ack: [], e2e: [], ready: [], http: {}, closes: {}, errors: 0, acks: 0, ackFail: {}, recv: 0, sent: 0, chatAck: [], chatSent: 0, openFail: 0, cl_err: 0 };
}
win = freshWindow();
const total = { opened: 0, ready: 0, closed: 0, connected: 0 };

async function http(method, path, token, body) {
  const t0 = performance.now();
  let status = 0;
  try {
    const res = await fetch(`http://127.0.0.1:${cfg.port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    status = res.status;
    const j = await res.json().catch(() => ({}));
    return { status, j };
  } catch (e) {
    return { status: 0, j: {} };
  } finally {
    const k = `${method} ${path.replace(/[0-9a-f-]{36}/g, ':id')}`;
    (win.http[k] ||= []).push([performance.now() - t0, status]);
  }
}

class Phone {
  constructor(outing, idx) {
    this.outing = outing;
    this.idx = idx;
    this.seq = 0;
    this.sent = new Map(); // seq -> t
    this.ws = null;
    this.timers = [];
    this.pending = new Map(); // id -> t
    this.alive = false;
  }
  async register(name) {
    const r = await http('POST', '/me', null, { display_name: name });
    if (r.status !== 201) throw new Error(`register ${r.status}`);
    this.token = r.j.token;
    this.id = r.j.user.id;
  }
  connect() {
    return new Promise((resolve) => {
      const t0 = performance.now();
      const ws = new WebSocket(`ws://127.0.0.1:${cfg.port}/api/outings/live`, { perMessageDeflate: false });
      this.ws = ws;
      let ready = false;
      const to = setTimeout(() => {
        if (!ready) {
          win.openFail += 1;
          try { ws.terminate(); } catch {}
          resolve(false);
        }
      }, 60_000);
      ws.on('open', () => {
        total.opened += 1;
        ws.send(JSON.stringify({ type: 'auth', token: this.token, outing_id: this.outing.id }));
      });
      ws.on('message', (data) => this.onMessage(data, () => {
        if (ready) return;
        ready = true;
        clearTimeout(to);
        total.ready += 1;
        this.alive = true;
        win.ready.push(performance.now() - t0);
        resolve(true);
      }));
      ws.on('close', (code) => {
        this.alive = false;
        total.closed += 1;
        win.closes[code] = (win.closes[code] || 0) + 1;
        if (!ready) {
          clearTimeout(to);
          resolve(false);
        }
      });
      ws.on('error', () => { win.cl_err += 1; });
    });
  }
  onMessage(data, onReady) {
    let m;
    try { m = JSON.parse(String(data)); } catch { return; }
    if (m.type === 'ready') return onReady();
    if (m.type === 'ack') {
      const t0 = this.pending.get(m.id);
      if (t0 !== undefined) {
        this.pending.delete(m.id);
        win.ack.push(performance.now() - t0);
      }
      win.acks += 1;
      if (!m.ok) win.ackFail[m.reason] = (win.ackFail[m.reason] || 0) + 1;
      return;
    }
    if (m.type === 'chat_ack') {
      const t0 = this.pending.get(m.id);
      if (t0 !== undefined) { this.pending.delete(m.id); win.chatAck.push(performance.now() - t0); }
      return;
    }
    if (m.type === 'position') {
      win.recv += 1;
      const p = m.position;
      const sender = this.outing.byId.get(p.user_id);
      if (!sender) return;
      const s = Math.round((p.lng - 46) * 1e6);
      const t0 = sender.sent.get(s);
      if (t0 !== undefined) win.e2e.push(performance.now() - t0);
    }
  }
  startTraffic() {
    const first = rnd(0, cfg.fixMs);
    this.timers.push(setTimeout(() => {
      this.timers.push(setInterval(() => this.sendFix(), cfg.fixMs));
    }, first));
    this.timers.push(setInterval(() => this.alive && this.ws.send(JSON.stringify({ type: 'heartbeat', gps: 'ok' })), 15_000 + rnd(0, 5000)));
    this.timers.push(setInterval(() => this.alive && this.ws.send(JSON.stringify({ type: 'ping' })), 20_000 + rnd(0, 5000)));
    if (cfg.chatEveryMs) {
      this.timers.push(setInterval(() => this.sendChat(), cfg.chatEveryMs + rnd(0, cfg.chatEveryMs)));
    }
  }
  sendFix() {
    if (!this.alive) return;
    this.seq += 1;
    const id = `${this.idx}:${this.seq}`;
    const t = performance.now();
    this.sent.set(this.seq, t);
    this.pending.set(id, t);
    if (this.sent.size > 12) this.sent.delete(this.sent.keys().next().value);
    if (this.pending.size > 200) this.pending.delete(this.pending.keys().next().value);
    win.sent += 1;
    this.ws.send(JSON.stringify({ type: 'position', id, fix: { lat: 24.7 + ((this.num ||= 1 + Math.floor(Math.random() * 50)) % 50) * 1e-4, lng: 46 + this.seq * 1e-6, accuracy: 8, speed: 12, heading: 90, age_ms: 0, mode: 'precise' } }));
  }
  sendChat() {
    if (!this.alive) return;
    const id = `c${this.idx}:${++this.seq}`;
    this.pending.set(id, performance.now());
    win.chatSent += 1;
    this.ws.send(JSON.stringify({ type: 'chat_message', id, with: 'group', client_id: id, kind: 'text', text: 'وين وصلتوا؟' }));
  }
  stop() {
    for (const t of this.timers) { clearTimeout(t); clearInterval(t); }
    try { this.ws?.terminate(); } catch {}
  }
}

async function pool(items, n, fn) {
  let i = 0;
  const run = async () => {
    while (i < items.length) {
      const k = i++;
      await fn(items[k], k).catch(() => { win.errors += 1; });
    }
  };
  await Promise.all(Array.from({ length: n }, run));
}

const outings = [];
const phones = [];

async function setup() {
  const sizes = Array.from({ length: cfg.outings }, () => cfg.minMembers + Math.floor(Math.random() * (cfg.maxMembers - cfg.minMembers + 1)));
  const t0 = performance.now();
  await pool(sizes, cfg.httpConc, async (size, k) => {
    const owner = new Phone(null, phones.length);
    owner.idx = `${cfg.workerId}.${k}.0`;
    await owner.register(`م${k}-0`);
    const c = await http('POST', '/', owner.token, { name: `طلعة ${k}`, ttl_hours: 24 });
    if (c.status !== 201) throw new Error(`create ${c.status}`);
    const o = { id: c.j.outing_id, members: [owner], byId: new Map([[owner.id, owner]]) };
    owner.outing = o;
    for (let i = 1; i < size; i++) {
      const p = new Phone(o, `${cfg.workerId}.${k}.${i}`);
      await p.register(`م${k}-${i}`);
      const j = await http('POST', '/invites/join', p.token, { token: c.j.invite.token });
      if (j.status !== 200) throw new Error(`join ${j.status}`);
      o.members.push(p);
      o.byId.set(p.id, p);
    }
    const st = await http('POST', `/${o.id}/status`, owner.token, { action: 'start' });
    if (st.status !== 200) throw new Error(`start ${st.status}`);
    outings.push(o);
    phones.push(...o.members);
  });
  return { ms: performance.now() - t0, outings: outings.length, phones: phones.length };
}

async function connectAll(conc) {
  const t0 = performance.now();
  await pool(phones, conc, async (p) => { if (await p.connect()) { total.connected += 1; } });
  return { ms: performance.now() - t0 };
}

function summarize(w) {
  const pct = (a, p) => (a.length ? +[...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor((p / 100) * a.length))].toFixed(1) : null);
  const h = {};
  for (const [k, v] of Object.entries(w.http)) {
    const ms = v.map((x) => x[0]);
    const bad = v.filter((x) => x[1] >= 400 || x[1] === 0).length;
    h[k] = { n: v.length, p50: pct(ms, 50), p95: pct(ms, 95), p99: pct(ms, 99), bad };
  }
  return {
    ack: { n: w.ack.length, p50: pct(w.ack, 50), p95: pct(w.ack, 95), p99: pct(w.ack, 99) },
    e2e: { n: w.e2e.length, p50: pct(w.e2e, 50), p95: pct(w.e2e, 95), p99: pct(w.e2e, 99) },
    ready: { n: w.ready.length, p50: pct(w.ready, 50), p95: pct(w.ready, 95), p99: pct(w.ready, 99), max: w.ready.length ? +Math.max(...w.ready).toFixed(0) : null },
    chat: { sent: w.chatSent, ack_p95: pct(w.chatAck, 95) },
    http: h,
    closes: w.closes,
    sent: w.sent,
    acks: w.acks,
    ack_fail: w.ackFail,
    recv: w.recv,
    open_fail: w.openFail,
    errors: w.errors,
    socket_errors: w.cl_err,
    total: { ...total },
  };
}

process.on('message', async (m) => {
  try {
    if (m.cmd === 'start') {
      cfg = m;
      const s = await setup();
      process.send({ ev: 'setup', s, http: summarize(win).http });
      win = freshWindow();
      const c = await connectAll(cfg.connectConc);
      process.send({ ev: 'connected', c, summary: summarize(win) });
      win = freshWindow();
      for (const p of phones) if (p.alive) p.startTraffic();
      process.send({ ev: 'traffic' });
    } else if (m.cmd === 'snap') {
      const s = summarize(win);
      if (m.reset) win = freshWindow();
      process.send({ ev: 'snap', id: m.id, s });
    } else if (m.cmd === 'stop') {
      for (const p of phones) p.stop();
      process.send({ ev: 'stopped' });
      setTimeout(() => process.exit(0), 200);
    } else if (m.cmd === 'reconnect') {
      /* a restart: drop every socket at once and reconnect them all together (the storm) */
      win = freshWindow();
      for (const p of phones) { p.timers.forEach((t) => { clearTimeout(t); clearInterval(t); }); p.timers = []; try { p.ws.terminate(); } catch {} p.alive = false; }
      const c = await connectAll(m.conc);
      for (const p of phones) if (p.alive) p.startTraffic();
      process.send({ ev: 'reconnected', c, summary: summarize(win) });
    }
  } catch (e) {
    process.send({ ev: 'fatal', error: String(e && e.stack || e) });
  }
});
