'use strict';

/**
 * Native iOS push (APNs) for the same outing events web push carries: a note
 * over a car, a voice clip, an SOS and «أنا بخير». Positions are never pushed.
 *
 *   APNS_KEY_ID       the 10-character Key ID of the .p8 key (Apple Developer → Keys)
 *   APNS_TEAM_ID      the 10-character Team ID (MH7J92HV9N)
 *   APNS_PRIVATE_KEY  the .p8 file contents (PEM); `\n` escapes are accepted
 *   APNS_BUNDLE_ID    the app's bundle id, used as apns-topic (sa.sary.albarq)
 *
 * Without all four (or with a key that is not a P-256 private key) APNs is
 * off: it says so once in the log, POST /push/apns answers 503 apns_disabled
 * and notifyMembers() is a no-op — exactly like web push without VAPID.
 *
 * Token-based auth: an ES256 JWT signed with the .p8 key, cached and renewed
 * every 50 minutes (Apple rejects one older than 60, and dislikes renewing
 * more often than every 20). HTTP/2 via Node's built-in http2 and crypto only.
 * Production tokens go to api.push.apple.com, sandbox tokens (Xcode builds)
 * to api.sandbox.push.apple.com. A token APNs calls gone (410, BadDeviceToken,
 * Unregistered) is deleted.
 *
 * Who receives a push is decided at send time exactly as for web push: active
 * members of an open outing, never the sender, and members looking at the
 * outing right now only for an SOS (`always`).
 */

const http2 = require('http2');
const crypto = require('crypto');

const MAX_PER_USER = 5;
const SEND_CONCURRENCY = 8;
const JWT_MAX_AGE_MS = 50 * 60_000;
const REQUEST_TIMEOUT_MS = 10_000;

const APNS_ORIGINS = Object.freeze({
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
});
const TIME_SENSITIVE = new Set(['sos', 'member_stuck', 'return_timer_overdue']);
const ACTIVE = new Set(['stuck_reply']);
const ENVIRONMENTS = new Set(['sandbox', 'production']);
const TOKEN_RE = /^[0-9a-f]{64,200}$/;
const BUNDLE_RE = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;
const APPLE_ID_RE = /^[A-Z0-9]{10}$/;
/* APNs answers these when a token will never be deliverable again. */
const GONE_REASONS = new Set(['BadDeviceToken', 'Unregistered']);
const JWT_REASONS = new Set(['ExpiredProviderToken', 'InvalidProviderToken']);

let loggedOff = false;

/** The .p8 contents as an env var: real newlines, `\n` escapes, or a bare base64 body. */
function normalizePem(raw) {
  let s = String(raw || '').trim().replace(/^["']|["']$/g, '').replace(/\\r/g, '').replace(/\\n/g, '\n').replace(/\r/g, '').trim();
  if (!s) return '';
  if (!/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(s)) {
    const b64 = s.replace(/\s+/g, '');
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) return '';
    s = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----`;
  }
  return s;
}

function apnsConfigFromEnv(env = process.env) {
  const keyId = String(env.APNS_KEY_ID || '').trim();
  const teamId = String(env.APNS_TEAM_ID || '').trim();
  const bundleId = String(env.APNS_BUNDLE_ID || '').trim();
  const pem = normalizePem(env.APNS_PRIVATE_KEY);
  const missing = [
    !keyId && 'APNS_KEY_ID',
    !teamId && 'APNS_TEAM_ID',
    !pem && 'APNS_PRIVATE_KEY',
    !bundleId && 'APNS_BUNDLE_ID',
  ].filter(Boolean);
  const off = (reason) => ({ enabled: false, reason, missing, keyId: null, teamId: null, bundleId: null, key: null });
  if (missing.length) return off('missing');
  if (!APPLE_ID_RE.test(keyId) || !APPLE_ID_RE.test(teamId) || !BUNDLE_RE.test(bundleId)) return off('invalid');
  let key;
  try {
    key = crypto.createPrivateKey({ key: pem, format: 'pem' });
  } catch {
    return off('invalid_key');
  }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') return off('invalid_key');
  return { enabled: true, reason: null, missing: [], keyId, teamId, bundleId, key };
}

/** A provider token: ES256 JWT, header {alg, kid}, claims {iss, iat}. */
function signApnsJwt({ keyId, teamId, key }, iatSeconds = Math.floor(Date.now() / 1000)) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input = `${enc({ alg: 'ES256', kid: keyId })}.${enc({ iss: teamId, iat: iatSeconds })}`;
  /* JOSE wants the raw r||s signature (64 bytes), not DER. */
  const sig = crypto.sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' });
  return `${input}.${sig.toString('base64url')}`;
}

/** { token, environment, bundle_id? } from the app → clean row, or { error }. */
function parseApnsRegistration(raw, { bundleId } = {}) {
  if (!raw || typeof raw !== 'object') return { error: 'invalid_token' };
  const token = typeof raw.token === 'string' ? raw.token.trim().toLowerCase() : '';
  if (!TOKEN_RE.test(token)) return { error: 'invalid_token' };
  const environment = typeof raw.environment === 'string' ? raw.environment.trim().toLowerCase() : '';
  if (!ENVIRONMENTS.has(environment)) return { error: 'invalid_environment' };
  if (raw.bundle_id != null && raw.bundle_id !== bundleId) return { error: 'invalid_bundle_id' };
  return { token, environment, bundle_id: bundleId };
}

function utf8Cut(s, maxBytes) {
  const b = Buffer.from(String(s));
  if (b.length <= maxBytes) return String(s);
  return b.subarray(0, maxBytes).toString('utf8').replace(/�+$/, '');
}

/**
 * A web-push payload (from pushPayloadFor) → an APNs request for one outing.
 * SOS is time-sensitive with the default sound (never `critical`: that needs
 * an Apple entitlement); everything else is passive — no sound, no screen wake —
 * the way web push delivers notes quietly. The web `tag` becomes the
 * apns-collapse-id, so «أنا بخير» replaces the SOS on the lock screen.
 */
function apnsRequestFor(payload = {}, outingId, { now = Date.now(), bundleId } = {}) {
  const type = payload.type || 'event';
  /* Someone in trouble (SOS, «غرّزت», a missed return time) breaks through Focus; a reply
   * to the stuck person is an ordinary alert; everything else stays passive. */
  const sos = TIME_SENSITIVE.has(type);
  const ttl = Math.max(0, Math.round(Number(payload.ttl ?? 900)));
  const tag = payload.tag || `sary-${type}-${outingId}`;
  const aps = {
    alert: { title: String(payload.title || 'سَرى البارق'), body: String(payload.body || '') },
    'thread-id': `sary-outing-${outingId}`,
    'interruption-level': sos ? 'time-sensitive' : ACTIVE.has(type) ? 'active' : 'passive',
  };
  if (sos || ACTIVE.has(type)) aps.sound = 'default';
  if (sos) {
    aps['relevance-score'] = 1;
  }
  const body = JSON.stringify({
    aps,
    v: 1,
    type,
    outing_id: outingId,
    url: `/outings/${outingId}`,
    at: new Date(now).toISOString(),
  });
  const headers = {
    'apns-push-type': 'alert',
    'apns-priority': payload.urgency === 'high' ? '10' : '5',
    'apns-expiration': String(Math.floor(now / 1000) + ttl),
    'apns-collapse-id': utf8Cut(tag, 64),
  };
  if (bundleId) headers['apns-topic'] = bundleId;
  return { headers, body };
}

/**
 * The real sender: one HTTP/2 session per APNs host, kept open and reopened
 * after an error or GOAWAY. `origins` / `connect` are for tests (an h2c server).
 * send() resolves { status, reason, apnsId } and only rejects on transport errors.
 */
function createApnsSender(cfg, { origins = APNS_ORIGINS, connect = http2.connect, now = () => Date.now(), timeoutMs = REQUEST_TIMEOUT_MS, log = console.warn } = {}) {
  const sessions = new Map();
  let jwt = null;
  let jwtAt = 0;
  const stats = { jwtSigned: 0 };

  function providerToken({ force = false, stale } = {}) {
    /* Several requests failing with the same old token renew it once. */
    if (force && stale && stale !== jwt) return jwt;
    if (!jwt || force || now() - jwtAt >= JWT_MAX_AGE_MS) {
      jwtAt = now();
      jwt = signApnsJwt(cfg, Math.floor(jwtAt / 1000));
      stats.jwtSigned += 1;
    }
    return jwt;
  }

  function session(origin) {
    const have = sessions.get(origin);
    if (have && !have.closed && !have.destroyed) return have;
    const s = connect(origin);
    sessions.set(origin, s);
    const drop = () => {
      if (sessions.get(origin) === s) sessions.delete(origin);
    };
    s.on('error', (e) => {
      drop();
      log('[outings-apns] connection', e?.code || e?.message);
    });
    s.on('goaway', drop);
    s.on('close', drop);
    s.unref?.();
    return s;
  }

  function request(origin, token, headers, body, bearer) {
    return new Promise((resolve, reject) => {
      let req;
      try {
        req = session(origin).request({
          ':method': 'POST',
          ':path': `/3/device/${token}`,
          authorization: `bearer ${bearer}`,
          'content-type': 'application/json',
          ...headers,
        });
      } catch (e) {
        reject(e);
        return;
      }
      let status = 0;
      let apnsId = null;
      let data = '';
      req.setEncoding('utf8');
      req.on('response', (h) => {
        status = Number(h[':status']) || 0;
        apnsId = h['apns-id'] || null;
      });
      req.on('data', (c) => {
        if (data.length < 4096) data += c;
      });
      req.on('end', () => {
        let reason = null;
        if (data) {
          try {
            reason = JSON.parse(data).reason || null;
          } catch {
            reason = null;
          }
        }
        resolve({ status, reason, apnsId });
      });
      req.on('error', reject);
      req.setTimeout(timeoutMs, () => {
        req.close(http2.constants.NGHTTP2_CANCEL);
        reject(Object.assign(new Error('apns timeout'), { code: 'ETIMEDOUT' }));
      });
      req.end(body);
    });
  }

  async function send(device, { headers, body }) {
    const origin = origins[device.environment] || origins.production;
    const h = { 'apns-topic': cfg.bundleId, ...headers };
    let bearer = providerToken();
    let r = await request(origin, device.token, h, body, bearer);
    if (r.status === 403 && JWT_REASONS.has(r.reason)) {
      bearer = providerToken({ force: true, stale: bearer });
      r = await request(origin, device.token, h, body, bearer);
    }
    return r;
  }

  function close() {
    for (const s of sessions.values()) s.close();
    sessions.clear();
  }

  return { send, close, providerToken, stats };
}

function isGone(r) {
  return r?.status === 410 || GONE_REASONS.has(r?.reason);
}

/**
 * @param {object} o
 * @param {import('pg').Pool} o.pool
 * @param {object} [o.config]  defaults to env (apnsConfigFromEnv)
 * @param {{send:Function, close?:Function}} [o.sender]  defaults to the HTTP/2 sender when enabled
 * @param {(outingId:string)=>Set<string>} [o.viewers]  users looking at the outing right now
 */
function createApnsNotifier({ pool, config = apnsConfigFromEnv(), sender, viewers = () => new Set(), maxPerUser = MAX_PER_USER, log = console.warn, info = console.log, now = () => Date.now() } = {}) {
  const enabled = Boolean(config.enabled && pool && config.bundleId && (sender || config.key));
  if (!enabled && !loggedOff) {
    loggedOff = true;
    const why = config.reason === 'missing' && config.missing?.length ? `${config.missing.join(', ')} not set` : config.reason || 'not configured';
    info(`[outings-apns] off (${why})`);
  }
  const out = enabled ? sender || createApnsSender(config, { log }) : null;
  const q = (text, params) => pool.query(text, params).then((r) => r.rows);
  const stats = { sent: 0, removed: 0, failed: 0 };

  function publicConfig() {
    return enabled ? { enabled: true, bundle_id: config.bundleId } : { enabled: false, bundle_id: null };
  }

  async function register(user, raw) {
    if (!enabled) return { ok: false, error: 'apns_disabled' };
    const reg = parseApnsRegistration(raw, { bundleId: config.bundleId });
    if (reg.error) return { ok: false, error: reg.error };
    /* A phone that signs in under a new device identity takes its token along. */
    await q(
      `INSERT INTO sary.apns_tokens (user_id, token, environment, bundle_id) VALUES ($1, $2, $3, $4)
       ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, environment = EXCLUDED.environment,
         bundle_id = EXCLUDED.bundle_id, updated_at = now(), last_used_at = now()`,
      [user.id, reg.token, reg.environment, reg.bundle_id],
    );
    await q(
      `DELETE FROM sary.apns_tokens WHERE id IN (
         SELECT id FROM sary.apns_tokens WHERE user_id = $1
         ORDER BY updated_at DESC, created_at DESC OFFSET $2)`,
      [user.id, maxPerUser],
    );
    return { ok: true };
  }

  async function unregister(user, rawToken) {
    const token = typeof rawToken === 'string' ? rawToken.trim().toLowerCase() : '';
    if (!TOKEN_RE.test(token)) return { removed: 0 };
    const rows = await q(`DELETE FROM sary.apns_tokens WHERE user_id = $1 AND token = $2 RETURNING id`, [user.id, token]);
    return { removed: rows.length };
  }

  /** Same contract as web push notifyMembers(); never throws. */
  async function notifyMembers(outingId, exceptUserId, payload = {}) {
    const result = { sent: 0, removed: 0, failed: 0, skipped: 0 };
    if (!enabled || !outingId) return result;
    try {
      const rows = await q(
        `SELECT t.id, t.user_id, t.token, t.environment
         FROM sary.apns_tokens t
         JOIN sary.outing_members m ON m.user_id = t.user_id
         JOIN sary.outings o ON o.id = m.outing_id
         WHERE m.outing_id = $1 AND m.status = 'active' AND ($4::boolean OR o.status <> 'ended')
           AND t.bundle_id = $3
           AND ($2::uuid IS NULL OR t.user_id <> $2::uuid)
           AND ($5::uuid IS NULL OR t.user_id = $5::uuid)`,
        [outingId, exceptUserId || null, config.bundleId, payload.include_ended === true, payload.to_user || null],
      );
      const watching = payload.always ? new Set() : viewers(outingId) || new Set();
      const targets = rows.filter((r) => {
        if (watching.has(r.user_id)) {
          result.skipped += 1;
          return false;
        }
        return true;
      });
      if (!targets.length) return result;
      const req = apnsRequestFor(payload, outingId, { now: now(), bundleId: config.bundleId });
      const dead = [];
      const used = [];
      let i = 0;
      async function worker() {
        while (i < targets.length) {
          const t = targets[i++];
          try {
            const r = await out.send({ token: t.token, environment: t.environment }, req);
            if (r.status === 200) {
              result.sent += 1;
              used.push(t.id);
            } else if (isGone(r)) {
              dead.push(t.id);
              result.removed += 1;
            } else {
              result.failed += 1;
              /* Never log the device token. */
              log('[outings-apns] send failed', r.status, r.reason || '');
            }
          } catch (e) {
            result.failed += 1;
            log('[outings-apns] send failed', e?.code || e?.message);
          }
        }
      }
      await Promise.all(Array.from({ length: Math.min(SEND_CONCURRENCY, targets.length) }, worker));
      if (dead.length) await q(`DELETE FROM sary.apns_tokens WHERE id = ANY($1::uuid[])`, [dead]);
      if (used.length) await q(`UPDATE sary.apns_tokens SET last_used_at = now() WHERE id = ANY($1::uuid[])`, [used]);
    } catch (e) {
      log('[outings-apns]', e?.code || e?.message);
    }
    stats.sent += result.sent;
    stats.removed += result.removed;
    stats.failed += result.failed;
    return result;
  }

  function close() {
    out?.close?.();
  }

  return { enabled, publicConfig, register, unregister, notifyMembers, close, stats };
}

/**
 * Web push and APNs behind the one notifyMembers() the service calls, so every
 * place that pushes today reaches both with the same recipients and rules.
 */
function combineNotifiers(...notifiers) {
  const list = notifiers.filter(Boolean);
  return {
    get enabled() {
      return list.some((n) => n.enabled);
    },
    async notifyMembers(outingId, exceptUserId, payload) {
      const parts = await Promise.all(list.map((n) => (n.enabled ? n.notifyMembers(outingId, exceptUserId, payload) : null)));
      const sum = { sent: 0, removed: 0, failed: 0, skipped: 0 };
      for (const p of parts) if (p) for (const k of Object.keys(sum)) sum[k] += p[k] || 0;
      return sum;
    },
  };
}

function _resetLoggedOffForTests() {
  loggedOff = false;
}

module.exports = {
  apnsConfigFromEnv,
  signApnsJwt,
  parseApnsRegistration,
  apnsRequestFor,
  createApnsSender,
  createApnsNotifier,
  combineNotifiers,
  normalizePem,
  APNS_ORIGINS,
  MAX_PER_USER,
  _resetLoggedOffForTests,
};
