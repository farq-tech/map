'use strict';

/** node scripts/loadtest/summarize.js docs/loadtest-results/*.json  → a markdown table of what each step measured. */

const fs = require('fs');
const med = (a) => (a.length ? [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)] : null);
const fmt = (n, d = 0) => (n == null ? '–' : Number(n).toFixed(d));

const rows = [];
for (const f of process.argv.slice(2)) {
  const r = JSON.parse(fs.readFileSync(f, 'utf8'));
  const s = r.series;
  const phones = r.setup.workers.reduce((x, w) => x + w.phones, 0);
  const secs = s.length ? s[s.length - 1].t - (s[0].t - 5) : 0;
  const sent = s.reduce((x, y) => x + y.clients.sent, 0);
  const recv = s.reduce((x, y) => x + y.clients.recv, 0);
  const a = r.setup_server.queries;
  const b = r.connect.server.queries;
  let conn = 0;
  for (const k of Object.keys(b)) if (!/BEGIN|COMMIT|POOLWAIT/.test(k)) conn += b[k].n - (a[k]?.n || 0);
  /* Queries in the steady window: final minus connect snapshot (both cumulative since the reset after connect). */
  const fq = r.final_server.queries;
  let steady = 0;
  const byKind = {};
  for (const [k, v] of Object.entries(fq)) {
    if (/BEGIN|COMMIT|POOLWAIT/.test(k)) continue;
    steady += v.n;
    byKind[k.replace(/^(SELECT|INSERT|UPDATE|WITH) /, '$1 ').replace('sary.', '')] = v.n;
  }
  const win = secs + 8; // reset happened 8 s before the first sample
  rows.push({
    label: r.label,
    outings: r.config.outings,
    phones,
    pool: r.config.pool_max,
    cpu: med(s.map((x) => x.server.cpu_pct)),
    loop99: med(s.map((x) => x.server.loop.p99)),
    rss: Math.max(...s.map((x) => x.server.rss_mb)),
    waitMax: Math.max(...s.map((x) => x.server.pool.waiting)),
    e2e50: med(s.map((x) => x.clients.e2e_p50)),
    e2e95: med(s.map((x) => x.clients.e2e_p95)),
    e2e99: med(s.map((x) => x.clients.e2e_p99)),
    ack95: med(s.map((x) => x.clients.ack_p95)),
    fixesPerS: sent / secs,
    recvPerS: recv / secs,
    qps: steady / win,
    qpsPerPhone: steady / win / phones,
    connQ: conn / phones,
    byKind: Object.fromEntries(Object.entries(byKind).map(([k, v]) => [k, +(v / win / phones).toFixed(3)])),
    fails: s.reduce((o, x) => { for (const [k, v] of Object.entries(x.clients.ack_fail)) o[k] = (o[k] || 0) + v; return o; }, {}),
    storm: r.storm && { ms: r.storm.ms, waitPeak: r.storm.peak_pool_waiting, loopMax: r.storm.peak_loop_max_ms },
    slow: r.final_server.hub && { dropped: r.final_server.hub.slow_dropped ?? 0, killed: r.final_server.hub.slow_killed ?? 0 },
    opened: r.final_server.ws?.opened,
  });
}
console.log('| step | outings | phones | pool | DB q/s | q/s per phone | queries per connect | CPU % of 1 core (median) | loop p99 ms | RSS MB | pool queue max | fix→recipient p50 / p95 / p99 ms | fixes/s in · msgs/s out |');
console.log('|---|---|---|---|---|---|---|---|---|---|---|---|---|');
for (const x of rows) {
  console.log(`| ${x.label} | ${x.outings} | ${x.phones} | ${x.pool} | ${fmt(x.qps)} | ${fmt(x.qpsPerPhone, 3)} | ${fmt(x.connQ, 1)} | ${fmt(x.cpu, 1)} | ${fmt(x.loop99)} | ${x.rss} | ${x.waitMax} | ${fmt(x.e2e50)} / ${fmt(x.e2e95)} / ${fmt(x.e2e99)} | ${fmt(x.fixesPerS)} · ${fmt(x.recvPerS)} |`);
}
console.log('\nq/s per phone by statement kind:');
for (const x of rows) console.log(`- ${x.label}: ${JSON.stringify(x.byKind)}  refused-acks: ${JSON.stringify(x.fails)}${x.slow ? `  slow-dropped/killed: ${x.slow.dropped}/${x.slow.killed}` : ''}${x.storm ? `  storm: ${x.storm.ms} ms, pool queue peak ${x.storm.waitPeak}, loop max ${x.storm.loopMax} ms` : ''}`);
