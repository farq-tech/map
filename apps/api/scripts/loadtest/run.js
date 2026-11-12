'use strict';

/**
 * Orchestrates one load step against a LOCAL Postgres:
 *   node scripts/loadtest/run.js --outings 500 --label o500 [--dbLatency 0] [--poolMax 8] [--durationS 90]
 *        [--workers 2] [--fixMs 2000] [--storm 1] [--min 3] [--max 6] [--chatMs 30000]
 * Needs: a Postgres on 127.0.0.1:54329 (user lt, trust auth, roles anon/authenticated/service_role)
 * and `ulimit -n` ≥ 20000. Writes docs/loadtest-results/<label>.json (numbers only). Never touches production.
 */

const { fork, spawn, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const arg = (k, d) => {
  const i = process.argv.indexOf(`--${k}`);
  return i > 0 ? process.argv[i + 1] : d;
};
const OUTINGS = Number(arg('outings', 100));
const LABEL = arg('label', `o${OUTINGS}`);
const LAT = Number(arg('dbLatency', 0));
const POOL = Number(arg('poolMax', 8));
const DUR = Number(arg('durationS', 90));
const WORKERS = Number(arg('workers', 2));
const FIX = Number(arg('fixMs', 2000));
const STORM = Number(arg('storm', 0));
const MINM = Number(arg('min', 3));
const MAXM = Number(arg('max', 6));
const CHAT = Number(arg('chatMs', 30000));
const PGB = process.env.PGB || '/opt/homebrew/opt/postgresql@16/bin';
const PORT = 4400 + Math.floor(Math.random() * 400);
const DBNAME = `lt_${LABEL}`.replace(/[^a-z0-9_]/gi, '_');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const psql = (sql) => execFileSync(`${PGB}/psql`, ['-h', '127.0.0.1', '-p', '54329', '-U', 'lt', 'postgres', '-c', sql], { stdio: 'pipe' });

async function metrics() {
  try {
    return await (await fetch(`http://127.0.0.1:${PORT}/__metrics`)).json();
  } catch {
    return null;
  }
}

function sum(arr, f) {
  return arr.reduce((a, x) => a + (f(x) || 0), 0);
}
function mergeSnap(snaps) {
  /* percentiles of percentiles are wrong in general; the workers are statistically identical, so report the worst. */
  const w = (f) => Math.max(...snaps.map((s) => f(s) ?? 0));
  return {
    ack_p50: w((s) => s.ack.p50), ack_p95: w((s) => s.ack.p95), ack_p99: w((s) => s.ack.p99), ack_n: sum(snaps, (s) => s.ack.n),
    e2e_p50: w((s) => s.e2e.p50), e2e_p95: w((s) => s.e2e.p95), e2e_p99: w((s) => s.e2e.p99), e2e_n: sum(snaps, (s) => s.e2e.n),
    sent: sum(snaps, (s) => s.sent), recv: sum(snaps, (s) => s.recv), acks: sum(snaps, (s) => s.acks),
    ack_fail: snaps.reduce((o, s) => { for (const [k, v] of Object.entries(s.ack_fail)) o[k] = (o[k] || 0) + v; return o; }, {}),
    closes: snaps.reduce((o, s) => { for (const [k, v] of Object.entries(s.closes)) o[k] = (o[k] || 0) + v; return o; }, {}),
    chat_sent: sum(snaps, (s) => s.chat.sent), chat_ack_p95: w((s) => s.chat.ack_p95),
    errors: sum(snaps, (s) => s.errors), socket_errors: sum(snaps, (s) => s.socket_errors), open_fail: sum(snaps, (s) => s.open_fail),
  };
}

(async () => {
  try { psql(`DROP DATABASE IF EXISTS ${DBNAME}`); } catch {}
  psql(`CREATE DATABASE ${DBNAME}`);
  const logPath = path.join(__dirname, `../../../../../loadtest-${LABEL}.server.log`);
  const out = fs.openSync(logPath, 'w');
  const server = spawn('node', [path.join(__dirname, 'server.js')], {
    env: { ...process.env, LT_DB_URL: `postgres://lt@127.0.0.1:54329/${DBNAME}`, LT_PORT: String(PORT), LT_DB_LATENCY_MS: String(LAT), SARY_DB_POOL_MAX: String(POOL), SARY_DATABASE_SSL: '0' },
    stdio: ['ignore', out, out],
  });
  for (let i = 0; i < 60; i++) { if (await metrics()) break; await sleep(500); }
  if (!(await metrics())) throw new Error('server did not start');
  await fetch(`http://127.0.0.1:${PORT}/__reset`);

  const result = { label: LABEL, config: { outings: OUTINGS, members: [MINM, MAXM], fixMs: FIX, chatMs: CHAT, db_latency_ms: LAT, pool_max: POOL, durationS: DUR, workers: WORKERS }, series: [] };
  const workers = [];
  const per = Math.ceil(OUTINGS / WORKERS);
  const ev = {};
  for (let w = 0; w < WORKERS; w++) {
    const child = fork(path.join(__dirname, 'worker.js'), [], { stdio: 'inherit' });
    child.on('message', (m) => {
      if (m.ev === 'fatal') console.error('worker fatal', m.error);
      (ev[m.ev] ||= []).push({ w, m });
    });
    workers.push(child);
  }
  const waitEv = async (name, n, ms) => { const end = Date.now() + ms; while ((ev[name]?.length || 0) < n && Date.now() < end) await sleep(300); };
  const t0 = Date.now();
  const cfgFor = (w) => ({ cmd: 'start', port: PORT, workerId: w, outings: Math.min(per, OUTINGS - w * per), minMembers: MINM, maxMembers: MAXM, fixMs: FIX, chatEveryMs: CHAT, httpConc: 24, connectConc: 150 });
  workers.forEach((c, w) => c.send(cfgFor(w)));
  await waitEv('setup', WORKERS, 20 * 60_000);
  result.setup = { ms: Date.now() - t0, workers: ev.setup?.map((e) => e.m.s), http: ev.setup?.map((e) => e.m.http) };
  const mSetup = await metrics();
  result.setup_server = mSetup;
  const tc = Date.now();
  await waitEv('connected', WORKERS, 20 * 60_000);
  result.connect = { ms: Date.now() - tc, summaries: ev.connected?.map((e) => e.m.summary), server: await metrics() };
  await waitEv('traffic', WORKERS, 60_000);
  await fetch(`http://127.0.0.1:${PORT}/__reset`);
  await sleep(8000); // warm-up
  /* discard warm-up window */
  let id = 0;
  const snapAll = async (reset) => {
    const my = ++id;
    workers.forEach((c) => c.send({ cmd: 'snap', id: my, reset }));
    const end = Date.now() + 10_000;
    while ((ev.snap || []).filter((e) => e.m.id === my).length < WORKERS && Date.now() < end) await sleep(100);
    return (ev.snap || []).filter((e) => e.m.id === my).map((e) => e.m.s);
  };
  await snapAll(true);
  await metrics();
  const steadyStart = Date.now();
  while (Date.now() - steadyStart < DUR * 1000) {
    await sleep(5000);
    const m = await metrics();
    const s = await snapAll(true);
    const merged = mergeSnap(s);
    result.series.push({ t: Math.round((Date.now() - steadyStart) / 1000), server: m && { loop: m.loop, cpu_pct: m.cpu_pct, rss_mb: m.rss_mb, heap_mb: m.heap_mb, pool: m.pool, hub: m.hub }, clients: merged });
    process.stdout.write(`t=${Math.round((Date.now() - steadyStart) / 1000)}s cpu=${m?.cpu_pct}% loop.p99=${m?.loop.p99}ms rss=${m?.rss_mb}MB pool=${JSON.stringify(m?.pool)} e2e.p95=${merged.e2e_p95} ack.p95=${merged.ack_p95} sent=${merged.sent} recv=${merged.recv}\n`);
  }
  const final = await metrics();
  result.final_server = final;
  if (STORM) {
    /* A restart: every phone's socket drops at once and they all reconnect together. */
    await metrics();
    const ts = Date.now();
    workers.forEach((c) => c.send({ cmd: 'reconnect', conc: 100000 }));
    let peak = { loop: 0, waiting: 0 };
    const end = Date.now() + 10 * 60_000;
    while ((ev.reconnected?.length || 0) < WORKERS && Date.now() < end) {
      await sleep(1000);
      const m = await metrics();
      if (m) { peak.loop = Math.max(peak.loop, m.loop.max); peak.waiting = Math.max(peak.waiting, m.pool.waiting); }
    }
    result.storm = { ms: Date.now() - ts, peak_loop_max_ms: peak.loop, peak_pool_waiting: peak.waiting, summaries: ev.reconnected?.map((e) => e.m.summary), server: await metrics() };
    process.stdout.write(`STORM: all reconnected in ${result.storm.ms} ms; ready p95=${JSON.stringify(result.storm.summaries?.map((s) => s.ready))}; pool waiting peak=${peak.waiting}; loop max=${peak.loop}ms\n`);
  }
  workers.forEach((c) => c.send({ cmd: 'stop' }));
  await sleep(1500);
  server.kill('SIGTERM');
  await sleep(1500);
  try { psql(`DROP DATABASE IF EXISTS ${DBNAME}`); } catch {}
  const dir = path.join(__dirname, '../../../../docs/loadtest-results');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${LABEL}.json`), JSON.stringify(result, null, 1));
  process.stdout.write(`wrote ${LABEL}.json\n`);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
