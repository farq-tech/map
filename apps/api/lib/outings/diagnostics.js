'use strict';

/**
 * Field-test diagnostics («وضع الاختبار الميداني») — what a phone saw on a
 * real drive, as numbers only.
 *
 * PRIVACY RULE (enforced here, not hoped for): the stored report is rebuilt
 * from SHAPE below, leaf by leaf. Only finite non-negative numbers, booleans
 * and a few short enum strings survive; every other key — a coordinate, a name,
 * a token, a timestamp, free text — is dropped. No user id is stored, and the
 * outing is kept only as a one-way hashed group key so several cars of the same
 * run can be compared without the row pointing at a person.
 *
 * Why not /api/analytics: that route stores per-session product events in the
 * comparison database under an event allowlist. This is one aggregate per
 * phone per outing, gated by outing membership, and belongs with the outings
 * data (and its retention sweep).
 *
 * Shape source of truth: docs/field-test/sample-diagnostics.json. The web
 * recorder (apps/web/src/lib/outings/fieldDiagnostics.ts) and this validator
 * are both tested against it.
 */

const crypto = require('crypto');

const SCHEMA = 'sary.field-diagnostics/1';
/** A day of driving is < 1e8 ms; anything above this is a bug, not data. */
const MAX_NUM = 1e9;

const N = 'num';
const B = 'bool';
const enumOf = (...v) => ({ enum: v });
const reasonMap = { map: /^[a-z_]{1,32}$/, max: 16 };
const dist = { count: N, p50: N, p90: N, p95: N, p99: N, max: N, mean: N };

const SHAPE = {
  app: {
    platform: enumOf('ios', 'android', 'desktop', 'other'),
    browser: enumOf('safari', 'chrome', 'firefox', 'samsung', 'other'),
    standalone: B,
  },
  mode: enumOf('saver', 'balanced', 'precise'),
  sessions: N,
  duration_ms: N,
  visible_ms: N,
  hidden_ms: N,
  link_ms: { connecting: N, live: N, polling: N, offline: N },
  sends: { attempts: N, ws: N, http: N, acked_ok: N, refused: N, unacked: N, refused_by_reason: reasonMap },
  ack_latency_ms: dist,
  connect_ms: dist,
  reconnects: { ...dist, total_ms: N },
  fixes: { seen: N, accepted: N, sent: N, rejected: { accuracy: N, out_of_order: N, glitch: N, too_old: N } },
  accuracy_m: { buckets: { le10: N, le30: N, le60: N, le150: N, gt150: N, unknown: N }, p50: N, p95: N },
  battery: { supported: B, start_pct: N, end_pct: N, discharge_ms: N, charging_ms: N, drain_pct_per_hour: N },
  wake_lock: { supported: B, acquired: N, lost: N, failed: N },
  peers: { max_members: N, live_ms: N, recent_ms: N, lost_ms: N, live_share: N },
  samples_dropped: N,
};

function cleanNum(v) {
  if (v === null || v === undefined) return null;
  if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > MAX_NUM) return null;
  return Math.round(v * 1000) / 1000;
}

function clean(spec, value) {
  if (spec === N) return cleanNum(value);
  if (spec === B) return typeof value === 'boolean' ? value : null;
  if (spec && spec.enum) return spec.enum.includes(value) ? value : 'other';
  if (spec && spec.map) {
    const out = {};
    if (!value || typeof value !== 'object' || Array.isArray(value)) return out;
    for (const [k, v] of Object.entries(value)) {
      if (Object.keys(out).length >= spec.max) break;
      const n = cleanNum(v);
      if (spec.map.test(k) && n !== null) out[k] = n;
    }
    return out;
  }
  const out = {};
  const src = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  for (const [k, sub] of Object.entries(spec)) out[k] = clean(sub, src[k]);
  return out;
}

/**
 * Validates and rebuilds a client report. Returns { ok: true, report } with
 * only allowlisted numeric leaves, or { ok: false, error }.
 */
function sanitizeDiagnostics(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, error: 'invalid_report' };
  if (raw.schema !== SCHEMA) return { ok: false, error: 'unsupported_schema' };
  const report = { schema: SCHEMA, ...clean(SHAPE, raw) };
  if (report.mode === 'other') report.mode = null;
  if (report.duration_ms === null) return { ok: false, error: 'invalid_report' };
  return { ok: true, report };
}

/** One-way group key: same outing → same key; the row cannot be joined back to sary.outings. */
function outingRef(outingId, salt = process.env.SARY_DIAG_SALT || 'sary-field-diagnostics') {
  return crypto.createHmac('sha256', salt).update(String(outingId)).digest('hex').slice(0, 24);
}

/** Every string leaf in a value, for tests that prove nothing but enums got through. */
function stringLeaves(v, out = []) {
  if (typeof v === 'string') out.push(v);
  else if (v && typeof v === 'object') for (const x of Object.values(v)) stringLeaves(x, out);
  return out;
}

module.exports = { SCHEMA, SHAPE, sanitizeDiagnostics, outingRef, stringLeaves };
