'use strict';

/**
 * «قناة الطلعة» — the outing's shared YouTube channel. MEMORY ONLY (no table,
 * no migration): one small state per outing, gone when the outing ends, when it
 * sits untouched for MEDIA_TTL_MS, or when the server restarts.
 *
 * The server never sees, fetches or relays any video. Every phone plays the
 * official YouTube embedded player itself; we only share WHAT is playing and
 * WHERE (video id, position, rate, play/pause). `title` is whatever the client
 * read from YouTube's oEmbed — display only, cleaned like any other text.
 *
 *   state = { video_id, title, controller_user_id, position_s, playing, rate,
 *             updated_at, at, queue: [video_id…≤20] }   or null (idle)
 *
 * `position_s` is valid at `at` (server time). A client computes the position
 * now as  position_s + (now − at) × rate  while playing  (see positionAt).
 *
 * Who may do what:
 *   idle    → any active member may `load` (they become the controller)
 *   active  → the controller, the owner or a co-leader control it;
 *             any member may `queue_add` (a suggestion, playback unchanged)
 *   takeover → owner / co-leader become the controller
 *   controller leaves / is removed → hand to the owner, or clear
 */

const { createRateLimiter } = require('./rate-limit');

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const TITLE_MAX = 100;
const QUEUE_MAX = 20;
const POSITION_MAX_S = 24 * 3600;
/* The rates the YouTube IFrame player offers. */
const RATES = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
const ACTIONS = ['play', 'pause', 'seek', 'load', 'next', 'queue_add', 'stop'];
const MEDIA_TTL_MS = 12 * 3600_000;

function videoId(raw) {
  return typeof raw === 'string' && VIDEO_ID.test(raw) ? raw : null;
}

function cleanTitle(raw) {
  if (raw == null || raw === '') return '';
  if (typeof raw !== 'string') return null;
  const t = raw
    .replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return [...t].slice(0, TITLE_MAX).join('');
}

/** undefined = not given, null = invalid. */
function position(raw) {
  if (raw === undefined || raw === null) return undefined;
  const n = typeof raw === 'number' ? raw : NaN;
  if (!Number.isFinite(n) || n < 0 || n > POSITION_MAX_S) return null;
  return Math.round(n * 1000) / 1000;
}

function rate(raw) {
  if (raw === undefined || raw === null) return undefined;
  return RATES.includes(raw) ? raw : null;
}

/** Pure: where the video is at time `t` (ms). */
function positionAt(state, t) {
  if (!state) return 0;
  if (!state.playing) return state.position_s;
  const p = state.position_s + (Math.max(0, t - state.at) / 1000) * state.rate;
  return Math.min(POSITION_MAX_S, Math.round(p * 1000) / 1000);
}

/** Parse a POST /media body. Returns { ok, value } or { ok:false, reason }. */
function parseAction(raw) {
  const b = raw && typeof raw === 'object' ? raw : {};
  if (!ACTIONS.includes(b.action)) return { ok: false, reason: 'invalid_action' };
  const out = { action: b.action };
  const p = position(b.position_s);
  if (p === null) return { ok: false, reason: 'invalid_position' };
  if (p !== undefined) out.position_s = p;
  const r = rate(b.rate);
  if (r === null) return { ok: false, reason: 'invalid_rate' };
  if (r !== undefined) out.rate = r;
  if (b.action === 'load' || b.action === 'queue_add') {
    const id = videoId(b.video_id);
    if (!id) return { ok: false, reason: 'invalid_video_id' };
    out.video_id = id;
  }
  if (b.action === 'load') {
    const t = cleanTitle(b.title);
    if (t === null) return { ok: false, reason: 'invalid_title' };
    out.title = t;
  }
  if (b.action === 'seek' && out.position_s === undefined) return { ok: false, reason: 'invalid_position' };
  return { ok: true, value: out };
}

function createMedia({ q, now, err, events, requireMember, canLead, limit = { n: 60, windowMs: 60_000 } }) {
  const hub = () => events();
  const states = new Map(); // outingId → { video_id, title, controller_user_id, position_s, playing, rate, at, updated_at, queue }
  const actionLimit = createRateLimiter({ limit: limit.n, windowMs: limit.windowMs, now });

  function live(outingId) {
    const s = states.get(outingId);
    if (!s) return null;
    if (now() - s.updated_at > MEDIA_TTL_MS) {
      states.delete(outingId);
      return null;
    }
    return s;
  }

  /** The wire shape, rebased to now so `at` is the server's current time. */
  function out(s) {
    if (!s) return null;
    const t = now();
    return {
      video_id: s.video_id,
      title: s.title,
      controller_user_id: s.controller_user_id,
      position_s: positionAt(s, t),
      playing: s.playing,
      rate: s.rate,
      queue: [...s.queue],
      updated_at: new Date(s.updated_at).toISOString(),
      at: new Date(t).toISOString(),
    };
  }

  function emit(outingId) {
    /* Everyone, the sender's other devices included. */
    hub().emit(outingId, { type: 'media_state', state: out(live(outingId)) });
  }

  function mediaOf(outingId) {
    return out(live(outingId));
  }

  function mayControl(m, s, userId) {
    return s.controller_user_id === userId || canLead(m);
  }

  /** Move the clock: fold elapsed play time into position_s. */
  function rebase(s, t) {
    s.position_s = positionAt(s, t);
    s.at = t;
  }

  async function getMedia(user, outingId) {
    const m = await requireMember(user, outingId);
    return { media: m.outing_status === 'ended' ? null : mediaOf(outingId), server_now: new Date(now()).toISOString() };
  }

  async function mediaAction(user, outingId, raw) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const parsed = parseAction(raw);
    if (!parsed.ok) throw err(parsed.reason, 400);
    if (!actionLimit(`${outingId}:${user.id}`)) throw err('rate_limited', 429);
    const a = parsed.value;
    const t = now();
    const s = live(outingId);

    if (!s) {
      if (a.action === 'load') {
        states.set(outingId, {
          video_id: a.video_id,
          title: a.title,
          controller_user_id: user.id,
          position_s: a.position_s ?? 0,
          playing: true,
          rate: a.rate ?? 1,
          at: t,
          updated_at: t,
          queue: [],
        });
        emit(outingId);
        return { media: mediaOf(outingId) };
      }
      if (a.action === 'stop') return { media: null };
      throw err('media_idle', 409);
    }

    if (a.action === 'queue_add') {
      if (s.queue.length >= QUEUE_MAX) throw err('queue_full', 409);
      s.queue.push(a.video_id);
      s.updated_at = t;
      emit(outingId);
      return { media: mediaOf(outingId) };
    }

    if (!mayControl(m, s, user.id)) throw err('not_controller', 403);
    rebase(s, t);
    switch (a.action) {
      case 'play':
        s.playing = true;
        break;
      case 'pause':
        s.playing = false;
        break;
      case 'seek':
        break;
      case 'load':
        s.video_id = a.video_id;
        s.title = a.title;
        s.position_s = 0;
        s.playing = true;
        break;
      case 'next': {
        const nextId = s.queue.shift();
        if (!nextId) {
          states.delete(outingId);
          emit(outingId);
          return { media: null };
        }
        s.video_id = nextId;
        s.title = '';
        s.position_s = 0;
        s.playing = true;
        break;
      }
      case 'stop':
        states.delete(outingId);
        emit(outingId);
        return { media: null };
      default:
        throw err('invalid_action', 400);
    }
    if (a.position_s !== undefined) s.position_s = a.position_s;
    if (a.rate !== undefined) s.rate = a.rate;
    s.at = t;
    s.updated_at = t;
    emit(outingId);
    return { media: mediaOf(outingId) };
  }

  async function takeoverMedia(user, outingId) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    if (!canLead(m)) throw err('leader_only', 403);
    const s = live(outingId);
    if (!s) throw err('media_idle', 409);
    if (s.controller_user_id !== user.id) {
      rebase(s, now());
      s.controller_user_id = user.id;
      s.updated_at = now();
      emit(outingId);
    }
    return { media: mediaOf(outingId) };
  }

  /** The outing ended: the channel goes with it (sockets are closing anyway). */
  function dropMedia(outingId) {
    return states.delete(outingId);
  }

  /**
   * A member left or was removed (or deleted their account). If they were the
   * controller, the owner takes over; with no active owner left the channel stops.
   */
  async function memberGone(outingId, userId) {
    const s = live(outingId);
    if (!s || s.controller_user_id !== userId) return;
    let heir = null;
    try {
      const [row] = await q(
        `SELECT o.owner_id FROM sary.outings o
         JOIN sary.outing_members m ON m.outing_id = o.id AND m.user_id = o.owner_id AND m.status = 'active'
         WHERE o.id = $1 AND o.status <> 'ended'`,
        [outingId],
      );
      heir = row?.owner_id && row.owner_id !== userId ? row.owner_id : null;
    } catch {
      heir = null;
    }
    if (states.get(outingId) !== s) return; // changed meanwhile
    if (heir) {
      rebase(s, now());
      s.controller_user_id = heir;
      s.updated_at = now();
    } else {
      states.delete(outingId);
    }
    emit(outingId);
  }

  function sweepMedia() {
    for (const id of [...states.keys()]) live(id);
  }

  return {
    api: { getMedia, mediaAction, takeoverMedia },
    mediaOf,
    dropMedia,
    memberGone,
    sweepMedia,
  };
}

module.exports = { createMedia, parseAction, positionAt, videoId, cleanTitle, QUEUE_MAX, RATES, MEDIA_TTL_MS };
