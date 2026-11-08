'use strict';

/**
 * «انقطع الإرسال» — a member whose sharing is on stopped reaching the server.
 *
 * During an active outing, a member who is active, has sharing ON and has a
 * last position, but whose last fix reached the server more than 10 minutes
 * ago, is "silent". The other active members get one alert (live event +
 * time-sensitive push) at 10 minutes, and one more at 30 minutes if the
 * silence goes on. A fresh fix clears it with a quiet `member_resumed`.
 *
 * Never alerted: sharing paused (the fix is deleted), left / removed, outing
 * paused or ended (fixes are deleted / the outing is not active), or the
 * member said beforehand that they are going offline («بطلع من التغطية»)
 * — until their next fix or the notice's end.
 *
 * State is memory only, per member. After a restart it is rebuilt from the
 * last position times in Postgres: a threshold crossed well before this
 * process started (more than BOOT_GRACE_MS before) is assumed to have been
 * alerted by the previous process, so a redeploy does not wake everyone a
 * second time; one crossed while the server was briefly down still fires.
 *
 *   ← { type: 'member_silent', user_id, since, last: { lat, lng, at } | null, level: 10 | 30 }
 *   ← { type: 'member_resumed', user_id, reason? }   (no reason = a fresh fix arrived)
 *   ← { type: 'member_going_offline', user_id, until }
 */

const LEVELS = [
  { level: 30, ms: 30 * 60_000 },
  { level: 10, ms: 10 * 60_000 },
];
const FIRST_MS = 10 * 60_000;
/* One sweep interval plus slack. */
const BOOT_GRACE_MS = 2 * 60_000;
const OFFLINE_DEFAULT_MIN = 120;
const OFFLINE_MAX_MIN = 12 * 60;

function iso(ms) {
  return ms == null ? null : new Date(ms).toISOString();
}

function levelFor(silentMs) {
  for (const l of LEVELS) if (silentMs >= l.ms) return l.level;
  return 0;
}

/** Minutes from a duration, whole, never under 1. */
function minutesOf(ms) {
  return Math.max(1, Math.floor(ms / 60_000));
}

/**
 * @param {object} o
 * @param {Function} o.q            (sql, params) → rows
 * @param {() => number} o.now
 * @param {() => object} o.events   the live hub (emit)
 * @param {(outingId:string) => Map|undefined} o.latest  in-memory freshest fix per member
 * @param {(outingId:string, userId:string, info:object) => any} o.notify  push, best effort
 * @param {number} [o.bootAt]
 */
function createSilenceWatch({ q, now, events, latest = () => undefined, notify = () => null, reasonOf = () => null, bootAt = now() }) {
  const state = new Map(); // `${o}:${u}` → { outingId, userId, since, level, last }
  const notices = new Map(); // `${o}:${u}` → until (ms)
  const key = (o, u) => `${o}:${u}`;

  function reason(s) {
    try {
      return reasonOf(s.outingId, s.userId, s.last?.at || null) || null;
    } catch {
      return null;
    }
  }

  /* `reason` (presence.js): why we think it went quiet — never a vague «انقطع». */
  function out(s) {
    return { user_id: s.userId, since: iso(s.since), level: s.level, last: s.last, reason: reason(s) };
  }

  function list(outingId) {
    const res = [];
    for (const s of state.values()) if (s.outingId === outingId && s.level > 0) res.push(out(s));
    return res;
  }

  function isSilent(outingId, userId) {
    return (state.get(key(outingId, userId))?.level || 0) > 0;
  }

  function noticeActive(k) {
    const until = notices.get(k);
    if (until == null) return false;
    if (now() >= until) {
      notices.delete(k);
      return false;
    }
    return true;
  }

  /** A fresh fix from this member: clear silence (quietly) and any going-offline notice. */
  function onFix(outingId, userId) {
    const k = key(outingId, userId);
    notices.delete(k);
    const s = state.get(k);
    if (!s) return false;
    state.delete(k);
    if (s.level > 0) events().emit(outingId, { type: 'member_resumed', user_id: userId });
    return true;
  }

  /**
   * Forget silence for one member (with a reason the clients can show or
   * ignore) or for a whole outing (paused / ended: no per-member event, the
   * outing_status event says it all).
   */
  function drop(outingId, userId, reason) {
    if (!userId) {
      for (const [k, s] of [...state]) if (s.outingId === outingId) state.delete(k);
      for (const k of [...notices.keys()]) if (k.startsWith(`${outingId}:`)) notices.delete(k);
      return;
    }
    const k = key(outingId, userId);
    notices.delete(k);
    const s = state.get(k);
    state.delete(k);
    if (s && s.level > 0 && reason) events().emit(outingId, { type: 'member_resumed', user_id: userId, reason });
  }

  /** «بطلع من التغطية»: no silence alert for this member until their next fix or `minutes` pass. */
  function goingOffline(outingId, userId, minutes) {
    const m = Number.isFinite(Number(minutes)) && Number(minutes) > 0 ? Math.min(OFFLINE_MAX_MIN, Math.round(Number(minutes))) : OFFLINE_DEFAULT_MIN;
    const until = now() + m * 60_000;
    const k = key(outingId, userId);
    notices.set(k, until);
    const s = state.get(k);
    state.delete(k);
    if (s && s.level > 0) events().emit(outingId, { type: 'member_resumed', user_id: userId, reason: 'going_offline' });
    events().emit(outingId, { type: 'member_going_offline', user_id: userId, until: iso(until) }, { exceptUser: userId });
    return { until: iso(until) };
  }

  /**
   * Every 60 s. One query for every member who could be silent right now:
   * outing active, member active and sharing, last fix in the DB older than
   * 10 minutes. The fresher in-memory fix (ahead of the throttled DB write)
   * wins. Everyone else in `state` no longer qualifies and is forgotten.
   */
  async function sweep() {
    const t = now();
    const rows = await q(
      `SELECT p.outing_id, p.user_id, p.lat, p.lng, p.recorded_at, p.received_at
       FROM sary.member_positions p
       JOIN sary.outing_members m ON m.outing_id = p.outing_id AND m.user_id = p.user_id
       JOIN sary.outings o ON o.id = p.outing_id
       WHERE o.status = 'active' AND m.status = 'active' AND m.sharing AND m.hidden_at IS NULL AND p.received_at <= $1
       LIMIT 2000`,
      [new Date(t - FIRST_MS)],
    );
    const seen = new Set();
    const fired = [];
    for (const r of rows) {
      const k = key(r.outing_id, r.user_id);
      seen.add(k);
      let lastRecv = new Date(r.received_at).getTime();
      let last = { lat: r.lat, lng: r.lng, at: new Date(r.recorded_at).toISOString() };
      const mem = latest(r.outing_id)?.get(r.user_id);
      if (mem && new Date(mem.received_at).getTime() > lastRecv) {
        lastRecv = new Date(mem.received_at).getTime();
        last = { lat: mem.lat, lng: mem.lng, at: new Date(mem.recorded_at).toISOString() };
      }
      const silentMs = t - lastRecv;
      const level = levelFor(silentMs);
      if (!level || noticeActive(k)) {
        state.delete(k);
        continue;
      }
      let s = state.get(k);
      if (s && s.since !== lastRecv) {
        /* A fix arrived that we did not see (another path): a new silence starts. */
        state.delete(k);
        s = null;
      }
      if (!s) {
        /* Rebuilt after a restart: what the previous process should already have sent. */
        const assumed = levelFor(bootAt - BOOT_GRACE_MS - lastRecv);
        s = { outingId: r.outing_id, userId: r.user_id, since: lastRecv, level: assumed, last };
        state.set(k, s);
      }
      s.last = last;
      if (level > s.level) {
        s.level = level;
        const event = { type: 'member_silent', user_id: r.user_id, since: iso(lastRecv), last, level, reason: reason(s) };
        events().emit(r.outing_id, event);
        fired.push(event);
        void notify(r.outing_id, r.user_id, {
          level,
          silentMinutes: minutesOf(silentMs),
          lastMinutes: minutesOf(t - Date.parse(last.at)),
          reason: event.reason,
        });
      }
    }
    for (const k of [...state.keys()]) if (!seen.has(k)) state.delete(k);
    for (const [k, until] of [...notices]) if (t >= until) notices.delete(k);
    return { fired: fired.length, silent: state.size };
  }

  return { sweep, onFix, drop, goingOffline, list, isSilent, _state: state };
}

module.exports = { createSilenceWatch, levelFor, BOOT_GRACE_MS, OFFLINE_MAX_MIN };
