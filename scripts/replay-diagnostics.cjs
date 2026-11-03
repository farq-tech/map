#!/usr/bin/env node
'use strict';

/**
 * Summarise exported field-test files («وضع الاختبار الميداني») into one table.
 *
 *   node scripts/replay-diagnostics.cjs car1.json car2.json …
 *   node scripts/replay-diagnostics.cjs results/            # every *.json inside
 *   node scripts/replay-diagnostics.cjs --md results/       # Markdown, to paste in the results table
 *   node scripts/replay-diagnostics.cjs --check results/    # exit 1 if a hard threshold fails
 *   node scripts/replay-diagnostics.cjs --json results/     # machine-readable
 *
 * Thresholds are the ones in docs/field-test-outings.md, derived from the
 * constants in apps/web/src/lib/outings/{policy,live}.ts. Keep them in step.
 */

const fs = require('fs');
const path = require('path');

const SCHEMA = 'sary.field-diagnostics/1';

/**
 * Hard checks (✗ fails --check) and soft ones (! only warns).
 *   LIVE_MOVING_MS 15 s, fast tier 2.5 s → a fix must be acknowledged well inside the gap.
 *   FAILS_BEFORE_POLLING 3 with BACKOFF_BASE 1 s → a socket that never comes up polls within ~10 s.
 */
const CHECKS = [
  { id: 'ack_p95', label: 'ack p95 ≤ 2000 ms', hard: true, test: (r) => r.ack_latency_ms.p95 == null || r.ack_latency_ms.p95 <= 2000 },
  { id: 'ack_p99', label: 'ack p99 ≤ 5000 ms', hard: true, test: (r) => r.ack_latency_ms.p99 == null || r.ack_latency_ms.p99 <= 5000 },
  { id: 'unacked', label: 'unacked ≤ 2% of sends', hard: true, test: (r) => ratio(r.sends.unacked, r.sends.attempts) <= 0.02 },
  { id: 'refused', label: 'refused ≤ 2% of sends', hard: true, test: (r) => ratio(r.sends.refused, r.sends.attempts) <= 0.02 },
  { id: 'connect', label: 'first connect p95 ≤ 10 s', hard: true, test: (r) => r.connect_ms.p95 == null || r.connect_ms.p95 <= 10_000 },
  { id: 'glitch', label: 'glitch rejects ≤ 1% of fixes', hard: true, test: (r) => ratio(r.fixes.rejected.glitch, r.fixes.seen) <= 0.01 },
  { id: 'wake', label: 'no wake-lock loss', hard: true, test: (r) => !r.wake_lock.lost },
  { id: 'reconnect', label: 'reconnect p50 ≤ 10 s', hard: false, test: (r) => r.reconnects.p50 == null || r.reconnects.p50 <= 10_000 },
  { id: 'accuracy', label: 'accuracy p95 ≤ 30 m', hard: false, test: (r) => r.accuracy_m.p95 == null || r.accuracy_m.p95 <= 30 },
  { id: 'battery', label: 'battery ≤ 15 %/h', hard: false, test: (r) => r.battery.drain_pct_per_hour == null || r.battery.drain_pct_per_hour <= 15 },
];

function ratio(a, b) {
  return b > 0 ? (a || 0) / b : 0;
}

function pct(a, b) {
  return b > 0 ? `${Math.round((100 * (a || 0)) / b)}%` : '—';
}

function secs(ms) {
  if (ms == null) return '—';
  if (ms < 10_000) return `${(ms / 1000).toFixed(1)}s`;
  if (ms < 120_000) return `${Math.round(ms / 1000)}s`;
  if (ms < 3_600_000) return `${Math.round(ms / 60_000)}m`;
  return `${(ms / 3_600_000).toFixed(1)}h`;
}

function msOrDash(v) {
  return v == null ? '—' : String(Math.round(v));
}

function collect(args) {
  const files = [];
  for (const a of args) {
    const st = fs.statSync(a);
    if (st.isDirectory()) {
      for (const f of fs.readdirSync(a).sort()) if (f.endsWith('.json')) files.push(path.join(a, f));
    } else files.push(a);
  }
  return files;
}

function load(file) {
  const r = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!r || r.schema !== SCHEMA) throw new Error(`${file}: not a ${SCHEMA} file`);
  return r;
}

function row(name, r) {
  const linkTotal = Object.values(r.link_ms).reduce((a, v) => a + (v || 0), 0);
  const checks = CHECKS.map((c) => ({ id: c.id, label: c.label, hard: c.hard, ok: c.test(r) }));
  return {
    file: name,
    device: `${r.app.platform}/${r.app.browser}${r.app.standalone ? '+pwa' : ''}`,
    mode: r.mode || '—',
    duration: secs(r.duration_ms),
    hidden: pct(r.hidden_ms, r.duration_ms),
    live: pct(r.link_ms.live, linkTotal),
    polling: pct(r.link_ms.polling, linkTotal),
    offline: pct(r.link_ms.offline + r.link_ms.connecting, linkTotal),
    sends: String(r.sends.attempts),
    http: pct(r.sends.http, r.sends.attempts),
    acked: pct(r.sends.acked_ok, r.sends.attempts),
    unacked: String(r.sends.unacked),
    'ack p50': msOrDash(r.ack_latency_ms.p50),
    'ack p95': msOrDash(r.ack_latency_ms.p95),
    'ack p99': msOrDash(r.ack_latency_ms.p99),
    connect: secs(r.connect_ms.p95),
    reconn: String(r.reconnects.count),
    'reconn p50': secs(r.reconnects.p50),
    'reconn max': secs(r.reconnects.max),
    accepted: pct(r.fixes.accepted, r.fixes.seen),
    'rej acc/glitch/ooo/old': [r.fixes.rejected.accuracy, r.fixes.rejected.glitch, r.fixes.rejected.out_of_order, r.fixes.rejected.too_old].join('/'),
    'acc p50/p95 m': `${msOrDash(r.accuracy_m.p50)}/${msOrDash(r.accuracy_m.p95)}`,
    'batt %/h': r.battery.drain_pct_per_hour == null ? (r.battery.supported ? 'short' : 'n/a') : String(r.battery.drain_pct_per_hour),
    'wake lost': r.wake_lock.supported ? String(r.wake_lock.lost) : 'n/a',
    cars: String(r.peers.max_members + 1),
    'others live': r.peers.live_share == null ? '—' : `${Math.round(r.peers.live_share * 100)}%`,
    verdict: checks.some((c) => c.hard && !c.ok) ? 'FAIL' : checks.some((c) => !c.ok) ? 'WARN' : 'PASS',
    _checks: checks,
    _refused: r.sends.refused_by_reason || {},
  };
}

function table(rows, md) {
  const cols = Object.keys(rows[0]).filter((k) => !k.startsWith('_'));
  const width = cols.map((c) => Math.max(c.length, ...rows.map((r) => String(r[c]).length)));
  const line = (vals) =>
    md ? `| ${vals.join(' | ')} |` : vals.map((v, i) => String(v).padEnd(width[i])).join('  ');
  const out = [line(cols)];
  out.push(md ? `|${cols.map(() => '---').join('|')}|` : width.map((w) => '-'.repeat(w)).join('  '));
  for (const r of rows) out.push(line(cols.map((c) => r[c])));
  return out.join('\n');
}

function main(argv) {
  const flags = new Set(argv.filter((a) => a.startsWith('--')));
  const args = argv.filter((a) => !a.startsWith('--'));
  if (!args.length || flags.has('--help')) {
    console.log('usage: node scripts/replay-diagnostics.cjs [--md|--json] [--check] <file.json|dir> …');
    return 2;
  }
  const files = collect(args);
  if (!files.length) {
    console.error('no .json files found');
    return 2;
  }
  const rows = files.map((f) => row(path.basename(f), load(f)));
  if (flags.has('--json')) {
    console.log(JSON.stringify(rows.map(({ _checks, _refused, ...r }) => ({ ...r, checks: _checks, refused_by_reason: _refused })), null, 2));
  } else {
    console.log(table(rows, flags.has('--md')));
    console.log('');
    for (const r of rows) {
      const failed = r._checks.filter((c) => !c.ok);
      const refused = Object.entries(r._refused).map(([k, v]) => `${k}×${v}`).join(', ');
      if (failed.length || refused) {
        console.log(`${r.file}: ${failed.map((c) => `${c.hard ? '✗' : '!'} ${c.label}`).join('; ')}${refused ? `${failed.length ? '; ' : ''}refused: ${refused}` : ''}`);
      }
    }
    console.log(`\nChecks: ${CHECKS.map((c) => `${c.hard ? '' : '(soft) '}${c.label}`).join(' · ')}`);
  }
  const anyHardFail = rows.some((r) => r._checks.some((c) => c.hard && !c.ok));
  return flags.has('--check') && anyHardFail ? 1 : 0;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    process.exitCode = 2;
  }
}

module.exports = { CHECKS, row, table, main };
