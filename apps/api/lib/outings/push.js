'use strict';

/**
 * Web Push for outing events that matter when the screen is off: a note over
 * a car, and an SOS. Positions are never pushed.
 *
 *   VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT (env, server only)
 *
 * Without all three, push is off: /push/config says { enabled: false }, the
 * subscribe route answers 503 push_disabled and notifyMembers() is a no-op.
 *
 * Who receives a push is decided at send time from active membership of an
 * open outing — a subscription belongs to a device identity, not to an
 * outing, so leaving or being removed stops pushes at once.
 *
 * The push service only ever sees an encrypted payload (RFC 8291). Endpoints
 * are restricted to the known browser push services so the API never POSTs to
 * an address a client chose.
 */

const MAX_PER_USER = 5;
const SEND_CONCURRENCY = 8;

/* Browser push services: Chrome/Edge/Samsung (FCM), Firefox (autopush),
 * Safari incl. iOS 16.4+ home-screen apps (Apple), legacy Edge (WNS). */
const PUSH_HOSTS = [
  /^fcm\.googleapis\.com$/,
  /^android\.googleapis\.com$/,
  /^updates\.push\.services\.mozilla\.com$/,
  /^[a-z0-9-]+\.push\.services\.mozilla\.com$/,
  /^web\.push\.apple\.com$/,
  /^[a-z0-9-]+\.push\.apple\.com$/,
  /^[a-z0-9-]+\.notify\.windows\.com$/,
];

function pushConfigFromEnv(env = process.env) {
  const publicKey = String(env.VAPID_PUBLIC_KEY || '').trim();
  const privateKey = String(env.VAPID_PRIVATE_KEY || '').trim();
  const subject = String(env.VAPID_SUBJECT || '').trim();
  const enabled = Boolean(publicKey && privateKey && /^(mailto:|https:\/\/)/.test(subject));
  return { enabled, publicKey: enabled ? publicKey : null, privateKey: enabled ? privateKey : null, subject: enabled ? subject : null };
}

function b64urlBytes(s) {
  if (typeof s !== 'string' || !/^[A-Za-z0-9_-]+={0,2}$/.test(s)) return null;
  return Buffer.from(s.replace(/=+$/, ''), 'base64url');
}

/** A browser PushSubscription (toJSON shape) → clean row, or null. */
function parseSubscription(raw, { hosts = PUSH_HOSTS } = {}) {
  if (!raw || typeof raw !== 'object') return null;
  const endpoint = typeof raw.endpoint === 'string' ? raw.endpoint.trim() : '';
  if (endpoint.length < 12 || endpoint.length > 1024) return null;
  let url;
  try {
    url = new URL(endpoint);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443')) return null;
  if (!hosts.some((re) => re.test(url.hostname))) return null;
  const p256dh = raw.keys?.p256dh;
  const auth = raw.keys?.auth;
  const pk = b64urlBytes(p256dh);
  const ak = b64urlBytes(auth);
  /* An uncompressed P-256 point (65 bytes, 0x04…) and a 16-byte auth secret. */
  if (!pk || pk.length !== 65 || pk[0] !== 4) return null;
  if (!ak || ak.length !== 16) return null;
  return { endpoint, p256dh, auth };
}

/** The real sender. Tests inject their own with the same send() shape. */
function createWebPushSender(cfg) {
  const webpush = require('web-push');
  const vapidDetails = { subject: cfg.subject, publicKey: cfg.publicKey, privateKey: cfg.privateKey };
  const options = ({ ttl = 900, urgency = 'normal', topic } = {}) => ({ TTL: ttl, urgency, topic, vapidDetails, timeout: 10_000 });
  return {
    /** What would go on the wire (encrypted body, VAPID headers) — for tests. */
    describe: (subscription, body, opts) => webpush.generateRequestDetails(subscription, body, options(opts)),
    /* Rejects with a WebPushError carrying statusCode (404/410 → subscription gone). */
    async send(subscription, body, opts) {
      const r = await webpush.sendNotification(subscription, body, options(opts));
      return { statusCode: r.statusCode };
    },
  };
}

function trimText(s, max) {
  const t = String(s || '').replace(/\s+/g, ' ').trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

/**
 * @param {object} o
 * @param {import('pg').Pool} o.pool
 * @param {{enabled:boolean, publicKey?:string|null}} [o.config]  defaults to env
 * @param {{send:Function}} [o.sender]  defaults to web-push when enabled
 * @param {(outingId:string)=>Set<string>} [o.viewers]  users looking at the outing right now
 */
function createPushNotifier({ pool, config = pushConfigFromEnv(), sender, viewers = () => new Set(), maxPerUser = MAX_PER_USER, hosts = PUSH_HOSTS, log = console.warn } = {}) {
  const enabled = Boolean(config.enabled && pool && (sender || config.privateKey));
  const out = sender || (enabled ? createWebPushSender(config) : null);
  const q = (text, params) => pool.query(text, params).then((r) => r.rows);
  const stats = { sent: 0, removed: 0, failed: 0 };

  function publicConfig() {
    return enabled ? { enabled: true, public_key: config.publicKey } : { enabled: false, public_key: null };
  }

  async function subscribe(user, raw) {
    if (!enabled) return { ok: false, error: 'push_disabled' };
    const sub = parseSubscription(raw, { hosts });
    if (!sub) return { ok: false, error: 'invalid_subscription' };
    /* The same browser under a new device identity moves with it. */
    await q(
      `INSERT INTO sary.push_subscriptions (user_id, endpoint, p256dh, auth) VALUES ($1, $2, $3, $4)
       ON CONFLICT (endpoint) DO UPDATE SET user_id = EXCLUDED.user_id, p256dh = EXCLUDED.p256dh,
         auth = EXCLUDED.auth, last_used_at = now()`,
      [user.id, sub.endpoint, sub.p256dh, sub.auth],
    );
    /* A handful of devices per person; the oldest goes first. */
    await q(
      `DELETE FROM sary.push_subscriptions WHERE id IN (
         SELECT id FROM sary.push_subscriptions WHERE user_id = $1
         ORDER BY last_used_at DESC, created_at DESC OFFSET $2)`,
      [user.id, maxPerUser],
    );
    return { ok: true };
  }

  async function unsubscribe(user, endpoint) {
    if (typeof endpoint !== 'string' || !endpoint) return { removed: 0 };
    const rows = await q(`DELETE FROM sary.push_subscriptions WHERE user_id = $1 AND endpoint = $2 RETURNING id`, [user.id, endpoint]);
    return { removed: rows.length };
  }

  async function count(user) {
    const [r] = await q(`SELECT count(*)::int AS n FROM sary.push_subscriptions WHERE user_id = $1`, [user.id]);
    return r.n;
  }

  /**
   * Push one event to every active member of an open outing except the sender.
   * payload: { type: 'note'|'sos'|…, title, body, tag?, ttl?, urgency?, always? }
   * `always` also reaches members who have the outing on screen (SOS).
   * Never throws: push is best effort, the live socket stays the source of truth.
   */
  async function notifyMembers(outingId, exceptUserId, payload = {}) {
    const result = { sent: 0, removed: 0, failed: 0, skipped: 0 };
    if (!enabled || !outingId) return result;
    try {
      const rows = await q(
        `SELECT s.id, s.user_id, s.endpoint, s.p256dh, s.auth
         FROM sary.push_subscriptions s
         JOIN sary.outing_members m ON m.user_id = s.user_id
         JOIN sary.outings o ON o.id = m.outing_id
         WHERE m.outing_id = $1 AND m.status = 'active' AND ($3::boolean OR o.status <> 'ended')
           AND ($2::uuid IS NULL OR s.user_id <> $2::uuid)
           AND ($4::uuid IS NULL OR s.user_id = $4::uuid)`,
        [outingId, exceptUserId || null, payload.include_ended === true, payload.to_user || null],
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
      const body = JSON.stringify({
        v: 1,
        type: payload.type || 'event',
        outing_id: outingId,
        title: trimText(payload.title, 80),
        body: trimText(payload.body, 240),
        tag: payload.tag || `sary-${payload.type || 'event'}-${outingId}`,
        url: `/outings/${outingId}`,
        at: new Date().toISOString(),
      });
      const opts = { ttl: payload.ttl ?? 900, urgency: payload.urgency || 'normal' };
      const { dead, used } = await deliver(targets, body, opts, result);
      if (dead.length) await q(`DELETE FROM sary.push_subscriptions WHERE id = ANY($1::uuid[])`, [dead]);
      if (used.length) await q(`UPDATE sary.push_subscriptions SET last_used_at = now() WHERE id = ANY($1::uuid[])`, [used]);
    } catch (e) {
      log('[outings-push]', e?.code || e?.message);
    }
    stats.sent += result.sent;
    stats.removed += result.removed;
    stats.failed += result.failed;
    return result;
  }

  /** Send one encrypted body to these rows ({id, endpoint, p256dh, auth}); counts into `result`. */
  async function deliver(targets, body, opts, result) {
    const dead = [];
    const used = [];
    let i = 0;
    async function worker() {
      while (i < targets.length) {
        const t = targets[i++];
        try {
          await out.send({ endpoint: t.endpoint, keys: { p256dh: t.p256dh, auth: t.auth } }, body, opts);
          result.sent += 1;
          used.push(t.id);
        } catch (e) {
          const code = e?.statusCode;
          if (code === 404 || code === 410) {
            dead.push(t.id);
            result.removed += 1;
          } else {
            result.failed += 1;
            /* Never log the endpoint: it is a capability URL. */
            log('[outings-push] send failed', code || e?.code || e?.message);
          }
        }
      }
    }
    await Promise.all(Array.from({ length: Math.min(SEND_CONCURRENCY, targets.length) }, worker));
    return { dead, used };
  }

  /**
   * A return-timer watcher (someone outside the outing who holds the watch
   * link) → web push to the subscriptions registered for that one timer. The
   * body carries no outing id and no names beyond the title/body text; tapping
   * it opens /watch. Never throws.
   */
  async function notifyWatchers(timerId, payload = {}) {
    const result = { sent: 0, removed: 0, failed: 0, skipped: 0 };
    if (!enabled || !timerId) return result;
    try {
      const targets = await q(`SELECT id, endpoint, p256dh, auth FROM sary.watch_subscriptions WHERE timer_id = $1`, [timerId]);
      if (!targets.length) return result;
      const body = JSON.stringify({
        v: 1,
        type: payload.type || 'event',
        title: trimText(payload.title, 80),
        body: trimText(payload.body, 240),
        tag: payload.tag || `sary-watch-${timerId}`,
        url: '/watch',
        at: new Date().toISOString(),
      });
      const opts = { ttl: payload.ttl ?? 6 * 3600, urgency: payload.urgency || 'high' };
      const { dead } = await deliver(targets, body, opts, result);
      if (dead.length) await q(`DELETE FROM sary.watch_subscriptions WHERE id = ANY($1::uuid[])`, [dead]);
    } catch (e) {
      log('[outings-push] watchers', e?.code || e?.message);
    }
    stats.sent += result.sent;
    stats.removed += result.removed;
    stats.failed += result.failed;
    return result;
  }

  return { enabled, publicConfig, subscribe, unsubscribe, count, notifyMembers, notifyWatchers, stats };
}

/** Outing events → push payloads. Returns null for events that are not pushed. */
function pushPayloadFor(event, { senderName, outingName } = {}) {
  const who = senderName || 'أحد أعضاء الطلعة';
  const where = outingName ? ` · ${outingName}` : '';
  if (event?.type === 'member_note' && event.note?.text) {
    return { type: 'note', title: `${who}${where}`, body: event.note.text, tag: `sary-note-${event.user_id}`, ttl: 15 * 60, urgency: 'normal' };
  }
  if (event?.type === 'voice_clip' && event.clip?.id) {
    const secs = Math.max(1, Math.round((Number(event.clip.duration_ms) || 0) / 1000));
    const left = Math.max(60, Math.round((new Date(event.clip.expires_at).getTime() - Date.now()) / 1000) || 600);
    return { type: 'voice_clip', title: `${who}${where}`, body: `🎙️ رسالة صوتية (${secs} ث) — افتح الطلعة لتسمعها.`, tag: `sary-clip-${event.clip.user_id || 'x'}`, ttl: Math.min(left, 600), urgency: 'normal' };
  }
  if (event?.type === 'sos' && event.refresh) return null; // same SOS, newer fix: no second alarm
  if (event?.type === 'sos' && 'sos' in event && event.sos === null) {
    /* «أنا بخير»: replaces the SOS notification (same tag) so a phone in a pocket stops saying "help". */
    return { type: 'sos_clear', title: `${who} بخير${where}`, body: 'ألغى نداء الاستغاثة.', tag: `sary-sos-${event.user_id || 'x'}`, ttl: 60 * 60, urgency: 'normal', always: true };
  }
  if (event?.type === 'sos') {
    const line = trimText(event.text || event.message || event.note?.text || '', 200);
    return {
      type: 'sos',
      title: `🆘 ${who} يطلب المساعدة${where}`,
      body: line || 'افتح الطلعة لترى موقعه على الخريطة.',
      tag: `sary-sos-${event.user_id || 'x'}`,
      ttl: 60 * 60,
      urgency: 'high',
      always: true,
    };
  }
  return null;
}

/**
 * Push payloads for the outing features. `include_ended` reaches members of an
 * outing that has already ended (a return timer outlives the outing);
 * `to_user` narrows to one person; `always` also reaches members on screen.
 */
const STUCK_REPLY_TEXT = {
  coming: (who) => `${who} جاي`,
  have_rope: (who) => `${who} عنده حبل سحب`,
  cant: (who) => `${who} ما يقدر يجي`,
};

function featurePayload(kind, { senderName, outingName, note, title, replyKind, userId, outingId } = {}) {
  const who = senderName || 'أحد أعضاء الطلعة';
  const where = outingName ? ` · ${outingName}` : '';
  switch (kind) {
    case 'return_timer_overdue':
      return {
        type: 'return_timer_overdue',
        title: `⏰ تأخرتوا عن وقت الرجوع${where}`,
        body: 'تأخرتوا عن وقت الرجوع — اضغط وصلت أو مدّد',
        tag: `sary-return-${outingId || 'x'}`,
        ttl: 6 * 3600,
        urgency: 'high',
        always: true,
        include_ended: true,
      };
    case 'member_stuck':
      return {
        type: 'member_stuck',
        title: `🚙 ${who} غرّز${where}`,
        body: trimText(note || '', 200) || 'افتح الطلعة لترى مكانه وتردّ عليه.',
        tag: `sary-stuck-${userId || 'x'}`,
        ttl: 3 * 3600,
        urgency: 'high',
      };
    case 'stuck_reply': {
      const line = (STUCK_REPLY_TEXT[replyKind] || STUCK_REPLY_TEXT.coming)(who);
      return { type: 'stuck_reply', title: `${line}${where}`, body: line, tag: `sary-stuck-reply-${userId || 'x'}`, ttl: 3 * 3600, urgency: 'high', always: true, to_user: userId };
    }
    case 'waypoint_added':
      return { type: 'waypoint_added', title: `${who}${where}`, body: `📍 أضاف نقطة: ${trimText(title || '', 60)}`, tag: `sary-waypoint-${outingId || 'x'}`, ttl: 3600, urgency: 'normal' };
    default:
      return null;
  }
}

/** Pushes to the people holding a watch link. Web push only (the watcher has no app). */
function watcherPayload(kind, { ownerName } = {}) {
  const who = ownerName || 'صاحب الطلعة';
  if (kind === 'overdue') return { type: 'return_timer_overdue', title: `⏰ ${who} تأخروا عن وقت الرجوع`, body: 'تأخروا عن وقت الرجوع. افتح الرابط لترى آخر موقع معروف.', urgency: 'high', ttl: 12 * 3600 };
  if (kind === 'extended') return { type: 'return_timer_extended', title: `${who} مدّدوا وقت الرجوع`, body: 'مدّدوا وقت الرجوع. افتح الرابط لترى الوقت الجديد.', urgency: 'normal', ttl: 12 * 3600 };
  if (kind === 'arrived') return { type: 'return_timer_arrived', title: `✅ ${who} وصلوا بالسلامة`, body: 'وصلوا بالسلامة', urgency: 'normal', ttl: 12 * 3600 };
  return null;
}

module.exports = { featurePayload, watcherPayload, createPushNotifier, createWebPushSender, pushConfigFromEnv, parseSubscription, pushPayloadFor, PUSH_HOSTS, MAX_PER_USER };
