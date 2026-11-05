'use strict';

/**
 * «إذاعة الطلعة» — what the whole trip listens to, in sync, while driving.
 *
 * The server never fetches, proxies or relays audio. It keeps one small state
 * per trip — WHAT plays and WHERE it is — and every phone plays the source
 * itself (AVPlayer, background audio, car speakers):
 *
 *   radio  — a live station from group-audio-catalog.js (by id; the URL comes
 *            from the catalog). Live, so every phone is naturally in sync.
 *   quran  — one surah file from mp3quran.net's CDN (URL pattern checked).
 *   audius — an Audius track id (the phone asks Audius for the stream).
 *
 *   state = { allow_all, item|null, playing, position_s, at, started_at, by,
 *             queue: [item…≤20], seq, updated_at }
 *
 * `position_s` is true at `at` (server time); a phone computes the position now
 * as position_s + (now − at) while playing (positionAt). A phone measures its
 * clock offset from `server_now` (HTTP), `pong.server_now` or `at` itself.
 *
 * Who may do what:
 *   leader (owner / co-leader) → everything, and `allow_all` («الكل يقدر يشغّل»)
 *   any active member          → everything except `allow_all`, while allow_all is on
 *                                `queue_add` (a suggestion) at any time
 *   everyone                   → mute locally (phone only; the server never knows)
 *
 * Kept in memory, written through to sary.group_audio (migration 014) so a
 * restart or a phone joining late still finds what plays. Ending the trip
 * clears it. An older client simply never asks for it.
 */

const { createRateLimiter } = require('./rate-limit');
const { station, quranUrl, audiusId } = require('./group-audio-catalog');

const SOURCES = ['radio', 'quran', 'audius'];
const ACTIONS = ['play_item', 'play', 'pause', 'seek', 'next', 'stop', 'queue_add', 'allow_all'];
const TEXT_MAX = 100;
const QUEUE_MAX = 20;
const POSITION_MAX_S = 24 * 3600;
const TTL_MS = 12 * 3600_000;

function cleanText(raw) {
  if (raw == null || raw === '') return '';
  if (typeof raw !== 'string') return null;
  const t = raw
    .replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return [...t].slice(0, TEXT_MAX).join('');
}

/** undefined = not given, null = invalid. */
function position(raw) {
  if (raw === undefined || raw === null) return undefined;
  const n = typeof raw === 'number' ? raw : NaN;
  if (!Number.isFinite(n) || n < 0 || n > POSITION_MAX_S) return null;
  return Math.round(n * 1000) / 1000;
}

/** An item from a phone → the canonical item, or { reason }. */
function parseItem(raw) {
  const b = raw && typeof raw === 'object' ? raw : null;
  if (!b || !SOURCES.includes(b.source)) return { reason: 'invalid_source' };
  if (b.source === 'radio') {
    const s = station(b.id);
    if (!s) return { reason: 'unknown_station' };
    return { item: { source: 'radio', id: s.id, title: s.name, subtitle: s.subtitle, url: s.url, live: true, duration_s: null } };
  }
  const title = cleanText(b.title);
  const subtitle = cleanText(b.subtitle);
  if (title === null || subtitle === null) return { reason: 'invalid_title' };
  const d = position(b.duration_s);
  if (d === null) return { reason: 'invalid_duration' };
  if (b.source === 'quran') {
    const url = quranUrl(b.url);
    if (!url) return { reason: 'invalid_url' };
    return { item: { source: 'quran', id: url, title: title || 'تلاوة', subtitle, url, live: false, duration_s: d ?? null } };
  }
  const id = audiusId(b.id);
  if (!id) return { reason: 'invalid_track' };
  return { item: { source: 'audius', id, title: title || 'Audius', subtitle, url: null, live: false, duration_s: d ?? null } };
}

/** Parse a group_audio_cmd / POST body. Returns { ok, value } or { ok:false, reason }. */
function parseCommand(raw) {
  const b = raw && typeof raw === 'object' ? raw : {};
  if (!ACTIONS.includes(b.action)) return { ok: false, reason: 'invalid_action' };
  const out = { action: b.action };
  const p = position(b.position_s);
  if (p === null) return { ok: false, reason: 'invalid_position' };
  if (p !== undefined) out.position_s = p;
  if (b.action === 'play_item' || b.action === 'queue_add') {
    const r = parseItem(b.item);
    if (!r.item) return { ok: false, reason: r.reason };
    out.item = r.item;
  }
  if (b.action === 'seek' && out.position_s === undefined) return { ok: false, reason: 'invalid_position' };
  if (b.action === 'allow_all') {
    if (typeof b.value !== 'boolean') return { ok: false, reason: 'invalid_value' };
    out.value = b.value;
  }
  return { ok: true, value: out };
}

/** Pure: where the item is at time `t` (ms). Live radio has no position. */
function positionAt(s, t) {
  if (!s || !s.item) return 0;
  if (s.item.live) return 0;
  if (!s.playing) return s.position_s;
  let p = s.position_s + Math.max(0, t - s.at) / 1000;
  if (s.item.duration_s) p = Math.min(p, s.item.duration_s);
  return Math.min(POSITION_MAX_S, Math.round(p * 1000) / 1000);
}

/** Pure permission rule (shared with the iOS client's GroupAudioPermissions). */
function mayControl({ leads, allowAll }) {
  return leads === true || allowAll === true;
}

function createGroupAudio({ q, now, err, events, requireMember, canLead, limit = { n: 60, windowMs: 60_000 } }) {
  const hub = () => events();
  const states = new Map(); // outingId → state
  const loaded = new Set(); // outings whose row was read since boot
  const cmdLimit = createRateLimiter({ limit: limit.n, windowMs: limit.windowMs, now });

  const blank = (t) => ({ allow_all: false, item: null, playing: false, position_s: 0, at: t, started_at: null, by: null, queue: [], seq: 0, updated_at: t });

  async function load(outingId) {
    if (loaded.has(outingId)) return;
    try {
      const [row] = await q(`SELECT state FROM sary.group_audio WHERE outing_id = $1`, [outingId]);
      if (row?.state && !states.has(outingId)) states.set(outingId, row.state);
    } catch {
      /* the table is not there yet (old schema): memory only */
    }
    loaded.add(outingId);
  }

  function persist(outingId) {
    const s = states.get(outingId);
    const p = s
      ? q(`INSERT INTO sary.group_audio (outing_id, state, updated_at) VALUES ($1, $2, now())
           ON CONFLICT (outing_id) DO UPDATE SET state = EXCLUDED.state, updated_at = now()`, [outingId, s])
      : q(`DELETE FROM sary.group_audio WHERE outing_id = $1`, [outingId]);
    return p.catch((e) => console.warn('[group-audio]', e.code || e.message));
  }

  function live(outingId) {
    const s = states.get(outingId);
    if (!s) return null;
    if (now() - s.updated_at > TTL_MS && s.item) {
      s.item = null;
      s.playing = false;
      s.queue = [];
    }
    return s;
  }

  /** The wire shape, rebased to now. Always an object (allow_all is known even when idle). */
  function out(s) {
    const t = now();
    if (!s) return { allow_all: false, item: null, playing: false, position_s: 0, queue: [], by: null, started_at: null, seq: 0, at: new Date(t).toISOString() };
    return {
      allow_all: s.allow_all,
      item: s.item ? { ...s.item } : null,
      playing: !!s.item && s.playing,
      position_s: positionAt(s, t),
      queue: s.queue.map((x) => ({ ...x })),
      by: s.by,
      started_at: s.started_at ? new Date(s.started_at).toISOString() : null,
      seq: s.seq,
      at: new Date(t).toISOString(),
    };
  }

  function emit(outingId) {
    hub().emit(outingId, { type: 'group_audio_state', state: out(live(outingId)), server_now: new Date(now()).toISOString() });
  }

  /** For snapshots (`ready`, GET /:id): the state, loading the row once after a restart. */
  async function stateFor(outingId) {
    await load(outingId);
    return out(live(outingId));
  }

  async function getGroupAudio(user, outingId) {
    const m = await requireMember(user, outingId);
    const ended = m.outing_status === 'ended';
    return {
      group_audio: ended ? out(null) : await stateFor(outingId),
      can_control: !ended && mayControl({ leads: canLead(m), allowAll: (states.get(outingId) || {}).allow_all }),
      server_now: new Date(now()).toISOString(),
    };
  }

  async function groupAudioCommand(user, outingId, raw) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const parsed = parseCommand(raw);
    if (!parsed.ok) throw err(parsed.reason, 400);
    if (!cmdLimit(`${outingId}:${user.id}`)) throw err('rate_limited', 429);
    await load(outingId);
    const c = parsed.value;
    const t = now();
    const leads = canLead(m);
    const s = live(outingId) || blank(t);

    if (c.action === 'allow_all') {
      if (!leads) throw err('leader_only', 403);
      s.allow_all = c.value;
    } else if (c.action === 'queue_add') {
      if (!s.item) throw err('audio_idle', 409);
      if (s.queue.length >= QUEUE_MAX) throw err('queue_full', 409);
      s.queue.push(c.item);
    } else {
      if (!mayControl({ leads, allowAll: s.allow_all })) throw err('not_allowed', 403);
      if (!s.item && !['play_item', 'stop'].includes(c.action)) throw err('audio_idle', 409);
      s.position_s = positionAt(s, t);
      s.at = t;
      switch (c.action) {
        case 'play_item':
          s.item = c.item;
          s.position_s = c.item.live ? 0 : c.position_s ?? 0;
          s.playing = true;
          s.started_at = t;
          s.by = user.id;
          break;
        case 'play':
          s.playing = true;
          s.by = user.id;
          break;
        case 'pause':
          s.playing = false;
          s.by = user.id;
          break;
        case 'seek':
          if (s.item.live) throw err('live_stream', 409);
          break;
        case 'next': {
          const nx = s.queue.shift();
          s.item = nx || null;
          s.position_s = 0;
          s.playing = !!nx;
          s.started_at = nx ? t : null;
          s.by = user.id;
          break;
        }
        case 'stop':
          s.item = null;
          s.playing = false;
          s.position_s = 0;
          s.started_at = null;
          s.by = user.id;
          break;
        default:
          throw err('invalid_action', 400);
      }
      if (c.position_s !== undefined && s.item && !s.item.live && c.action !== 'play_item') s.position_s = c.position_s;
      if (s.item?.duration_s) s.position_s = Math.min(s.position_s, s.item.duration_s);
    }
    s.seq += 1;
    s.updated_at = t;
    states.set(outingId, s);
    loaded.add(outingId);
    await persist(outingId);
    emit(outingId);
    return { group_audio: out(s), server_now: new Date(t).toISOString() };
  }

  /** The trip ended: it goes with it. */
  function dropGroupAudio(outingId) {
    const had = states.delete(outingId);
    loaded.add(outingId);
    void persist(outingId);
    return had;
  }

  function sweepGroupAudio() {
    for (const id of [...states.keys()]) live(id);
  }

  return {
    api: { getGroupAudio, groupAudioCommand },
    stateFor,
    dropGroupAudio,
    sweepGroupAudio,
  };
}

module.exports = { createGroupAudio, parseCommand, parseItem, positionAt, mayControl, cleanText, QUEUE_MAX, TTL_MS };
