'use strict';

/**
 * Load-test server: the REAL outings stack (lib/outings: hub + service + ws + router), nothing of it
 * mocked, on a LOCAL Postgres, with numbers-only instrumentation. Never point it at production.
 *
 *   LT_DB_URL=postgres://lt@127.0.0.1:54329/lt LT_PORT=4400 LT_DB_LATENCY_MS=0 node scripts/loadtest/server.js
 *
 * GET /__metrics returns what the runner samples: event-loop delay, CPU, memory, pool state, per-kind
 * query counts and timings, hub and socket stats. `LT_DB_LATENCY_MS` adds a fixed delay in front of
 * every query, to stand in for a remote database (Supabase is not on this machine).
 */

const http = require('http');
const express = require('express');
const { monitorEventLoopDelay, performance } = require('perf_hooks');
const { createPool, migrate } = require('../../lib/outings/db');
const { setupOutings } = require('../../lib/outings');

const URL = process.env.LT_DB_URL;
if (!URL || !/@(127\.0\.0\.1|localhost)[:/]/.test(URL)) {
  console.error('LT_DB_URL must point at a LOCAL database');
  process.exit(2);
}
const PORT = Number(process.env.LT_PORT || 4400);
const LAT = Number(process.env.LT_DB_LATENCY_MS || 0);
const POOL_MAX = Number(process.env.SARY_DB_POOL_MAX || 8);
process.env.SARY_DB_POOL_MAX = String(POOL_MAX);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const kinds = new Map(); // kind -> { n, ms, max, samples[] }
function kindOf(text) {
  const s = String(typeof text === 'string' ? text : text?.text || '').replace(/\s+/g, ' ').trim();
  const verb = s.split(' ', 1)[0].toUpperCase();
  const m = /(?:FROM|INTO|UPDATE|JOIN)\s+(sary\.[a-z_]+)/i.exec(s);
  return `${verb} ${m ? m[1] : s.slice(0, 24)}`;
}
function record(text, ms) {
  const k = kindOf(text);
  let r = kinds.get(k);
  if (!r) kinds.set(k, (r = { n: 0, ms: 0, max: 0, samples: [] }));
  r.n += 1;
  r.ms += ms;
  if (ms > r.max) r.max = ms;
  if (r.samples.length < 4000) r.samples.push(ms);
  else r.samples[Math.floor(Math.random() * 4000)] = ms;
}

const pool = createPool(URL);
const rawQuery = pool.query.bind(pool);
pool.query = async (...a) => {
  const t0 = performance.now();
  try {
    if (LAT) await sleep(LAT);
    return await rawQuery(...a);
  } finally {
    record(a[0], performance.now() - t0);
  }
};
const rawConnect = pool.connect.bind(pool);
pool.connect = async (...a) => {
  if (typeof a[0] === 'function') return rawConnect(...a); // pg's own pool.query path
  const t0 = performance.now();
  const client = await rawConnect(...a);
  record('POOLWAIT connect', performance.now() - t0);
  if (!client.__lt) {
    client.__lt = true;
    const cq = client.query.bind(client);
    client.query = async (...b) => {
      const q0 = performance.now();
      try {
        if (LAT) await sleep(LAT);
        return await cq(...b);
      } finally {
        record(b[0], performance.now() - q0);
      }
    };
  }
  return client;
};

const h = monitorEventLoopDelay({ resolution: 10 });
h.enable();
let cpuPrev = process.cpuUsage();
let cpuPrevAt = performance.now();
let seq = 0;

function pct(arr, p) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(2);
}

async function main() {
  await migrate(pool);
  /* Registration and invites are rate-limited per address in production (10 users/hour, 30 invites/10 min):
   * one machine registering thousands of people would only measure that limit, so lift it here. */
  const outings = setupOutings({ pool, autoMigrate: false, limits: { identityPerHour: 1e9, invitePer10Min: 1e9 } });
  const app = express();
  app.set('trust proxy', true);
  app.get('/__metrics', (_req, res) => {
    const t = performance.now();
    const cpu = process.cpuUsage(cpuPrev);
    const cpuPct = ((cpu.user + cpu.system) / 1000 / (t - cpuPrevAt)) * 100;
    cpuPrev = process.cpuUsage();
    cpuPrevAt = t;
    const mem = process.memoryUsage();
    const q = {};
    for (const [k, r] of kinds) q[k] = { n: r.n, avg_ms: +(r.ms / r.n).toFixed(2), p50: pct(r.samples, 50), p95: pct(r.samples, 95), p99: pct(r.samples, 99), max: +r.max.toFixed(1) };
    res.json({
      seq: (seq += 1),
      loop: { mean: +(h.mean / 1e6).toFixed(2), p50: +(h.percentile(50) / 1e6).toFixed(2), p99: +(h.percentile(99) / 1e6).toFixed(2), max: +(h.max / 1e6).toFixed(1) },
      cpu_pct: +cpuPct.toFixed(1),
      cpu_ms_total: Math.round((process.cpuUsage().user + process.cpuUsage().system) / 1000),
      rss_mb: Math.round(mem.rss / 1048576),
      heap_mb: Math.round(mem.heapUsed / 1048576),
      pool: { total: pool.totalCount, idle: pool.idleCount, waiting: pool.waitingCount, max: POOL_MAX },
      queries: q,
      hub: outings.hub.stats(),
      ws: outings.socketStats(),
    });
    h.reset();
    for (const r of kinds.values()) {
      /* per-interval timings: keep totals, reset samples */
      r.samples = [];
    }
  });
  app.get('/__reset', (_req, res) => {
    kinds.clear();
    res.json({ ok: true });
  });
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  server.listen(PORT, '127.0.0.1', () => console.log(`[loadtest-server] :${PORT} db_latency=${LAT}ms pool=${POOL_MAX}`));
  outings.attach(server);
  const stop = async () => {
    await outings.close().catch(() => {});
    process.exit(0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}
main().catch((e) => {
  console.error(e);
  process.exit(1);
});
