'use strict';

/**
 * Product analytics ingest — what people do on the map, and nothing else.
 *
 * Every decision about this map is currently a guess: we do not know whether
 * people pick districts, ask the copilot, switch list↔map or press "search
 * here". This module turns a batch of client events into one parameterised
 * INSERT into public.analytics_events, and refuses everything it was not
 * explicitly told to store.
 *
 * PRIVACY RULE (enforced below, not documented elsewhere and hoped for):
 * we never store free text a person typed. No search query, no copilot
 * question, no place name, no email/phone/token, no precise coordinates.
 * Only an opaque session id, a route path, a language/device bucket, and a
 * short allowlist of scalar `meta` keys per event type. Anything else is
 * dropped silently — a client bug must never become a privacy incident.
 *
 * ALLOWLIST SOURCE OF TRUTH: apps/web/src/lib/farqAnalytics.ts holds the same
 * list for the client. The two cannot import across workspaces, so
 * lib/analytics.test.js asserts this copy still matches the one in the web
 * lib. Change one, change both.
 */

/** The only event names that may ever reach the table. Mirror of ANALYTICS_EVENTS in apps/web/src/lib/farqAnalytics.ts. */
const ALLOWED_EVENT_TYPES = Object.freeze([
  'map_view',
  'district_select',
  'district_clear',
  'place_select',
  'list_open',
  'map_open',
  'sort_change',
  'search_submit',
  'search_here',
  'copilot_ask',
  'copilot_action',
  'legend_open',
  'locate_click',
  'open_menu_click',
  'lens_change',
]);

const ALLOWED_TYPE_SET = new Set(ALLOWED_EVENT_TYPES);

/**
 * Which `meta` keys each event may carry. Anything outside its event's set is
 * dropped — so a new key has to be thought about here before it can be stored.
 * Keys are counts, buckets and ids of *things*, never of people.
 */
const META_KEYS_BY_TYPE = Object.freeze({
  map_view: ['zoom', 'lens', 'result_count', 'source'],
  district_select: ['district_id', 'result_count', 'source'],
  district_clear: ['source'],
  place_select: ['district_id', 'rank', 'source'],
  list_open: ['result_count', 'sort', 'source'],
  map_open: ['result_count', 'source'],
  sort_change: ['sort', 'result_count', 'source'],
  search_submit: ['has_query', 'result_count', 'source'],
  search_here: ['zoom', 'result_count', 'source'],
  copilot_ask: ['intent', 'has_query', 'result_count', 'source'],
  copilot_action: ['action', 'intent', 'source'],
  legend_open: ['lens', 'source'],
  locate_click: ['source'],
  open_menu_click: ['source', 'rank'],
  lens_change: ['lens', 'source'],
});

const MAX_EVENTS_PER_REQUEST = 20;
const MAX_META_KEYS = 10;
const MAX_META_STRING = 64;
const MAX_PATH = 128;
const RATE_LIMIT_PER_MINUTE = 60;

/**
 * Second line of defence over the per-event allowlist: a key that looks like a
 * person, a secret or a raw location is refused even if someone later adds it
 * to a list above. Cheaper to say no twice than to leak once.
 */
const FORBIDDEN_META_KEY = /(mail|phone|tel|token|secret|key|auth|user|person|name|query|text|term|prompt|message|question|address|lat|lng|lon|coord|ip)/i;

/** Slug-shaped values only: ids, enums, buckets. Anything with a space or an Arabic letter is free text — dropped. */
const SAFE_META_STRING = /^[A-Za-z0-9_.:-]+$/;

/** Routes are ASCII in this app; an Arabic or spaced segment means user content got into the URL. */
const SAFE_PATH = /^\/[A-Za-z0-9/_.-]*$/;

/** Opaque client id only (a UUID or similar). Anything else becomes null rather than being stored. */
const SESSION_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

function sanitizeSessionId(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  return SESSION_ID_RE.test(s) ? s : null;
}

/**
 * Route only. The query string is where typed text ends up (?q=...), so it is
 * cut off here along with the hash — we keep the shape of the journey, not its
 * contents.
 */
function sanitizePath(raw) {
  if (typeof raw !== 'string') return null;
  const cut = raw.split('?')[0].split('#')[0].trim().slice(0, MAX_PATH);
  if (!SAFE_PATH.test(cut)) return null;
  return cut;
}

function sanitizeLanguage(raw) {
  return raw === 'ar' || raw === 'en' ? raw : null;
}

function sanitizeDevice(raw) {
  return raw === 'mobile' || raw === 'desktop' ? raw : null;
}

/**
 * Flat object of scalars, keys allowlisted per event type, ≤10 keys, strings
 * ≤64 chars and slug-shaped, numbers rounded to 3 decimals so a coordinate can
 * never arrive at street precision. Everything else is dropped silently.
 */
function sanitizeMeta(raw, eventType) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const allowed = META_KEYS_BY_TYPE[eventType];
  if (!allowed) return null;
  const out = {};
  let kept = 0;
  for (const key of allowed) {
    if (kept >= MAX_META_KEYS) break;
    if (!Object.prototype.hasOwnProperty.call(raw, key)) continue;
    const value = raw[key];
    // A `has_*` boolean carries presence, never content, so it survives the
    // backstop (that is how `has_query` can exist without storing the query).
    const presenceFlag = typeof value === 'boolean' && key.startsWith('has_');
    if (!presenceFlag && FORBIDDEN_META_KEY.test(key)) continue;
    if (typeof value === 'boolean') {
      out[key] = value;
    } else if (typeof value === 'number') {
      if (!Number.isFinite(value)) continue;
      out[key] = Math.round(value * 1000) / 1000;
    } else if (typeof value === 'string') {
      const s = value.trim().slice(0, MAX_META_STRING);
      if (!s || !SAFE_META_STRING.test(s)) continue; // free text never lands here
      out[key] = s;
    } else {
      continue; // nested objects, arrays, null, functions
    }
    kept += 1;
  }
  return kept ? out : null;
}

/**
 * Validate a batch. A disallowed event type is a hard 400 and nothing is
 * inserted: an unknown name means the client and this file have drifted, and
 * we would rather notice than quietly collect junk.
 */
function normalizeBatch(body) {
  const src = body && typeof body === 'object' ? body : {};
  const events = Array.isArray(src.events) ? src.events : null;
  if (!events) return { error: 'events_required' };
  if (!events.length) return { rows: [] };
  if (events.length > MAX_EVENTS_PER_REQUEST) return { error: 'too_many_events' };

  const rows = [];
  for (const raw of events) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return { error: 'invalid_event' };
    }
    const type = typeof raw.type === 'string' ? raw.type.trim() : '';
    if (!ALLOWED_TYPE_SET.has(type)) return { error: 'invalid_event_type' };
    rows.push({
      event_type: type,
      session_id: sanitizeSessionId(raw.session_id ?? src.session_id),
      path: sanitizePath(raw.path ?? src.path),
      language: sanitizeLanguage(raw.language ?? src.language),
      device: sanitizeDevice(raw.device ?? src.device),
      meta: sanitizeMeta(raw.meta, type),
    });
  }
  return { rows };
}

/** One parameterised multi-row INSERT — values are never concatenated into SQL. */
function buildInsert(rows) {
  const values = [];
  const tuples = rows.map((row, i) => {
    const base = i * 6;
    values.push(
      row.event_type,
      row.session_id,
      row.path,
      row.language,
      row.device,
      row.meta ? JSON.stringify(row.meta) : null,
    );
    return `($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4}, $${base + 5}, $${base + 6}::jsonb)`;
  });
  return {
    text:
      'INSERT INTO public.analytics_events (event_type, session_id, path, language, device, meta) VALUES ' +
      tuples.join(', '),
    values,
  };
}

/**
 * Crude in-memory rate limit per session: a loop or a stuck effect must not be
 * able to flood a live product table. Per process, per minute bucket; losing
 * the counters on restart is fine for this purpose.
 */
const buckets = new Map();

function rateLimit(sessionId, count, now) {
  const key = sessionId || 'anon';
  const minute = Math.floor(now / 60_000);
  const entry = buckets.get(key);
  if (buckets.size > 5000) buckets.clear(); // bounded memory; counters are disposable
  if (!entry || entry.minute !== minute) {
    buckets.set(key, { minute, count });
    return count <= RATE_LIMIT_PER_MINUTE;
  }
  entry.count += count;
  return entry.count <= RATE_LIMIT_PER_MINUTE;
}

function __resetRateLimitForTests() {
  buckets.clear();
}

function writeEnabled(env = process.env) {
  return env.ANALYTICS_WRITE_ENABLED === '1';
}

/**
 * Ingest a batch. Returns { status, error? }: 400 only for a client that sent
 * something we refuse to store, 204 for everything else — including a DB
 * failure, a disabled flag and a rate-limited session. Analytics must never
 * break the app or tell the client anything about the database.
 */
async function ingestEvents({ body, query, now = Date.now(), env = process.env }) {
  const { rows, error } = normalizeBatch(body);
  if (error) return { status: 400, error };
  if (!rows.length) return { status: 204 };
  if (!writeEnabled(env)) return { status: 204, skipped: 'disabled' };
  if (!rateLimit(rows[0].session_id, rows.length, now)) {
    return { status: 204, skipped: 'rate_limited' };
  }
  const { text, values } = buildInsert(rows);
  try {
    await query(text, values);
    return { status: 204, inserted: rows.length };
  } catch (err) {
    // Fail soft: log here, say nothing to the client.
    console.warn('[analytics] insert failed:', err.message);
    return { status: 204, skipped: 'db_error' };
  }
}

module.exports = {
  ALLOWED_EVENT_TYPES,
  META_KEYS_BY_TYPE,
  MAX_EVENTS_PER_REQUEST,
  MAX_META_KEYS,
  RATE_LIMIT_PER_MINUTE,
  buildInsert,
  ingestEvents,
  normalizeBatch,
  sanitizeMeta,
  sanitizePath,
  sanitizeSessionId,
  writeEnabled,
  __resetRateLimitForTests,
};
