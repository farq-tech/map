'use strict';

/**
 * «مباشر / متأخر / منقطع» — one presence state per member, with the reason.
 *
 * Built from the last position's *timestamp* (when the fix was taken), never
 * from the socket alone: a socket can stay open while iOS has stopped the GPS,
 * and a locked phone can send over HTTP with no socket at all.
 *
 *   live     the last fix was taken ≤ LIVE_MS ago
 *   stale    LIVE_MS < age ≤ OFFLINE_MS — shown with the reason, never as live
 *   offline  age > OFFLINE_MS (or no fix ever)
 *   hidden   the member chose «أخفِ موقعي» (their position is not sent at all)
 *
 * The reason is the most specific thing we know, in this order:
 *   hidden          they hid their location themselves
 *   location_off    the phone says location permission is off (heartbeat gps=denied / hint)
 *   app_closed      the app told us it was being closed (applicationWillTerminate)
 *   when_in_use     the app went to the background with «أثناء الاستخدام» only
 *   web             they follow from a browser (stops when the screen locks)
 *   no_gps          we still hear the phone, but it has no GPS fix
 *   low_power       Low Power Mode (iOS slows the GPS and the uploads)
 *   no_network      nothing at all reaches us (no network, or the phone is off)
 *
 * Hints are memory only (`noteHint` / `noteClient`): after a restart they are
 * rebuilt as the phones heartbeat again; until then the generic reason applies.
 *
 *   ← { type: 'member_presence', user_id, state, reason, last_fix_at, since }
 */

const LIVE_MS = 75_000;
const OFFLINE_MS = 10 * 60_000;
/* We "still hear" a phone whose heartbeat / request is this recent. */
const HEARD_MS = 90_000;

/* `web_hidden`: the web page went to the background (apps/web live.ts, PR #117). */
const HINTS = new Set(['fg', 'bg_always', 'bg_when_in_use', 'low_power', 'terminated', 'location_off', 'web_hidden']);
const REASONS = ['hidden', 'location_off', 'app_closed', 'when_in_use', 'web', 'no_gps', 'low_power', 'no_network'];

/** The short Najdi line for each reason (the app has the same table: PresenceReason). */
const REASON_TEXT = {
  hidden: 'مخفي موقعه',
  location_off: 'جواله مقفل الموقع',
  app_closed: 'سرى مسكّر عنده',
  when_in_use: 'الموقع «أثناء الاستخدام» بس',
  web: 'يتابع من المتصفح',
  no_gps: 'ما فيه إشارة GPS',
  low_power: 'وضع توفير الطاقة',
  no_network: 'ما فيه شبكة',
};

function reasonText(r) {
  return (r && REASON_TEXT[r]) || null;
}

function cleanHint(h) {
  return typeof h === 'string' && HINTS.has(h) ? h : null;
}

/** 'ios' for our app (User-Agent "SaryAlbarq/<build> …"), 'web' for a browser, null when unknown. */
function clientOf(ua) {
  if (typeof ua !== 'string' || !ua) return null;
  if (/^SaryAlbarq\//.test(ua)) return 'ios';
  if (/Mozilla\//.test(ua)) return 'web';
  return null;
}

/**
 * Pure: the state and reason for one member.
 * @param {object} o
 * @param {number} o.nowMs
 * @param {number|null} o.fixAtMs      when the last fix was taken (recorded_at)
 * @param {number|null} o.heardAtMs    last heartbeat / request from this member
 * @param {string|null} o.gps          'ok' | 'weak' | 'unavailable' | 'denied'
 * @param {{hint:string, at:number}|null} o.hint
 * @param {string|null} o.client       'ios' | 'web'
 * @param {boolean} o.hidden
 */
function presenceOf({ nowMs, fixAtMs = null, heardAtMs = null, gps = null, hint = null, client = null, hidden = false, lowPower = false }) {
  if (hidden) return { state: 'hidden', reason: 'hidden' };
  const age = fixAtMs == null ? Infinity : nowMs - fixAtMs;
  if (age <= LIVE_MS) return { state: 'live', reason: null };
  const state = age <= OFFLINE_MS ? 'stale' : 'offline';
  /* A hint counts only if it came after the last fix (the fix proves it no longer holds). */
  const h = hint && (fixAtMs == null || hint.at >= fixAtMs - 5_000) ? hint.hint : null;
  const heard = heardAtMs != null && nowMs - heardAtMs <= HEARD_MS;
  let reason;
  if (gps === 'denied' || h === 'location_off') reason = 'location_off';
  else if (h === 'terminated') reason = 'app_closed';
  else if (h === 'bg_when_in_use') reason = 'when_in_use';
  else if (client === 'web' || h === 'web_hidden') reason = 'web';
  else if (heard) reason = h === 'low_power' || lowPower ? 'low_power' : 'no_gps';
  else if (h === 'low_power' || lowPower) reason = 'low_power';
  else reason = 'no_network';
  return { state, reason };
}

function createPresence({ now = () => Date.now(), events = () => ({ emit() {} }) } = {}) {
  const hints = new Map(); // `${o}:${u}` → { hint, at, lowPower }
  const clients = new Map(); // `${o}:${u}` → 'ios' | 'web'
  const lastSent = new Map(); // `${o}:${u}` → 'state|reason'
  const key = (o, u) => `${o}:${u}`;

  function noteHint(outingId, userId, hint, { lowPower } = {}) {
    const h = cleanHint(hint);
    const k = key(outingId, userId);
    const prev = hints.get(k);
    if (h) hints.set(k, { hint: h, at: now(), lowPower: lowPower === true || (h === 'low_power') });
    else if (typeof lowPower === 'boolean' && prev) prev.lowPower = lowPower;
    else if (typeof lowPower === 'boolean') hints.set(k, { hint: null, at: now(), lowPower });
    return h;
  }

  function noteClient(outingId, userId, ua) {
    const c = clientOf(ua);
    if (c) clients.set(key(outingId, userId), c);
    return c;
  }

  function forget(outingId, userId) {
    if (!userId) {
      for (const m of [hints, clients, lastSent]) for (const k of [...m.keys()]) if (k.startsWith(`${outingId}:`)) m.delete(k);
      return;
    }
    const k = key(outingId, userId);
    hints.delete(k);
    clients.delete(k);
    lastSent.delete(k);
  }

  /**
   * @param {string} outingId
   * @param {{user_id:string, hidden?:boolean, hidden_at?:any}} member
   * @param {{recorded_at:any}|null} position
   * @param {{at:number, gps:string|null}|null} link
   */
  function compute(outingId, member, position, link) {
    const k = key(outingId, member.user_id);
    const h = hints.get(k) || null;
    const fixAtMs = position?.recorded_at ? new Date(position.recorded_at).getTime() : null;
    const p = presenceOf({
      nowMs: now(),
      fixAtMs,
      heardAtMs: link?.at ?? null,
      gps: link?.gps ?? null,
      hint: h && h.hint ? h : null,
      lowPower: h?.lowPower === true,
      client: clients.get(k) || null,
      hidden: member.hidden === true,
    });
    return {
      state: p.state,
      reason: p.reason,
      last_fix_at: fixAtMs == null ? null : new Date(fixAtMs).toISOString(),
      since: member.hidden && member.hidden_at ? new Date(member.hidden_at).toISOString() : null,
    };
  }

  /** Emit `member_presence` for every member whose state or reason changed since the last time. */
  function publish(outingId, list) {
    let n = 0;
    for (const { user_id, presence } of list) {
      const k = key(outingId, user_id);
      const sig = `${presence.state}|${presence.reason || ''}`;
      if (lastSent.get(k) === sig) continue;
      const first = !lastSent.has(k);
      lastSent.set(k, sig);
      /* The first computation after a restart is not news (the snapshot already says it). */
      if (first && presence.state === 'live') continue;
      events().emit(outingId, { type: 'member_presence', user_id, ...presence }, { exceptUser: user_id });
      n += 1;
    }
    return n;
  }

  return { noteHint, noteClient, compute, publish, forget, _hints: hints, _clients: clients };
}

module.exports = { REASON_TEXT, reasonText, createPresence, presenceOf, clientOf, cleanHint, LIVE_MS, OFFLINE_MS, HEARD_MS, REASONS };
