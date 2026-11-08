'use strict';

/**
 * «قناة الطلعة» voice notes («رسالة صوتية»): the walkie-talkie as messages.
 *
 * Why (see docs in the PR): the live relay (lib/outings/ptt.js) needs one
 * unbroken socket from the talker, through the server, to every listener for
 * the whole sentence, plus a floor grant before the first word — on desert
 * cellular a reconnect anywhere in that chain loses the audio silently. A
 * voice note is recorded on the phone first, uploaded over plain HTTP (retried
 * until it gets through), stored here for a while, announced on the socket and
 * by push, and fetched by each listener — so a dropped link only delays it.
 *
 *   POST /api/outings/:id/voice-notes          body: the m4a bytes
 *        X-Clip-Duration-Ms (300…60 000) · X-Ptt-Channel ('1'…'5' | private uuid)
 *        X-Client-Id (idempotency) · X-Clip-Age-Ms (how long ago recording stopped)
 *        → 201 { note } (200 { note, duplicate: true } for a retried upload)
 *   GET  /api/outings/:id/voice-notes?channel=  → { notes: [...], server_now }   (no audio)
 *   GET  /api/outings/:id/voice-notes/:noteId   → the audio bytes
 *
 * Who: an active member of a trip that is not over; for a private channel one
 * of its listed members — checked on upload, on every list and on every fetch.
 *
 * Delivery of a new note to the other members allowed on its channel:
 *   · a socket that says it knows voice notes (auth `caps: ['voice_notes']`)
 *     gets { type: 'voice_note', note } — the phone decides whether its radio
 *     is on that channel and the note is fresh enough to play by itself;
 *   · an older socket (web, builds ≤ 16) whose radio is on that channel gets
 *     the old { type: 'voice_clip', clip } with a url to this note, so it shows
 *     its usual voice banner and can play it;
 *   · a member whose radio is on that channel and who is not looking at the
 *     trip right now: a Push to Talk push (type 'voice_note': the phone wakes,
 *     fetches and plays it through the system's walkie-talkie audio), and a
 *     time-sensitive alert for the ones that push could not reach.
 *
 * Storage: Postgres bytea (migration 015), ≤ 640 KB a note, 24 h, swept every
 * 10 minutes; sooner when the trip ends, the sender leaves, or the private
 * channel closes (read-time checks hide them at once, the sweep frees them).
 */

const crypto = require('crypto');
const { sniffAudio } = require('./clips');
const { channelId, isPublicId, PTT_DEFAULT_CHANNEL } = require('./ptt-channels');
const v = require('./validate');

const NOTE_MAX_MS = 60_000;
const NOTE_MIN_MS = 300;
/** Recorders overshoot a stop by a few hundred ms. */
const NOTE_DURATION_SLACK_MS = 1_500;
/** 60 s at 32 kbps ≈ 240 KB; head-room for the container and a higher bit rate. */
const NOTE_MAX_BYTES = 640 * 1024;
const NOTE_MIN_BYTES = 256;
const NOTE_TTL_MS = 24 * 3600_000;
/** A phone plays a note by itself only this long after it was recorded (older: «الرسائل الصوتية»). */
const NOTE_AUTOPLAY_MS = 120_000;
const NOTE_MIN_GAP_MS = 1_200;
/** Per trip: the newest ones matter; a runaway client cannot fill the database. */
const OUTING_MAX_NOTES = 300;
const LIST_LIMIT = 50;
const CLIENT_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

function parseNoteDurationMs(raw) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return null;
  const ms = Math.round(n);
  if (ms < NOTE_MIN_MS || ms > NOTE_MAX_MS + NOTE_DURATION_SLACK_MS) return null;
  return Math.min(ms, NOTE_MAX_MS);
}

/** How long ago recording stopped, as the phone says it (an outbox upload is late). 0…TTL. */
function parseAgeMs(raw) {
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.min(Math.round(n), NOTE_TTL_MS - 60_000);
}

function createVoiceNotes({ q, hub, requireMember, err, pttChannels = null, relay = null, apns = null, push = null, blockersOf = null, now = () => Date.now(), log = console.warn } = {}) {
  const lastAt = new Map(); // userId → ms of the last accepted upload
  const stats = { uploaded: 0, duplicates: 0, socket: 0, compat: 0, ptt_pushed: 0, alerted: 0, fetched: 0, swept: 0 };

  const isAllowed = (outingId, ch, userId) => (pttChannels ? pttChannels.isAllowed(outingId, ch, userId) : isPublicId(ch));
  const radioOf = (outingId, userId) => (relay?.currentChannel ? relay.currentChannel(outingId, userId) : PTT_DEFAULT_CHANNEL);

  /** The channel a request names (absent: '1'); a private one only for its members (loads the list first). */
  async function allowedChannel(outingId, raw, userId) {
    const ch = raw === undefined || raw === null || raw === '' ? PTT_DEFAULT_CHANNEL : channelId(raw);
    if (!ch) throw err('invalid_channel', 400);
    if (isPublicId(ch)) return ch;
    if (pttChannels && !pttChannels.loaded(outingId)) await pttChannels.load(outingId);
    if (!isAllowed(outingId, ch, userId)) throw err('not_invited', 403);
    return ch;
  }

  function shape(r, at = now()) {
    const recorded = new Date(r.recorded_at).getTime();
    return {
      id: r.id,
      channel: r.channel,
      user_id: r.sender_id,
      mime: r.mime,
      duration_ms: r.duration_ms,
      bytes: r.bytes,
      recorded_at: new Date(recorded).toISOString(),
      created_at: new Date(r.created_at).toISOString(),
      expires_at: new Date(r.expires_at).toISOString(),
      /* Server-measured, so a phone with a wrong clock still knows whether to play it by itself. */
      age_ms: Math.max(0, at - recorded),
      url: `/api/outings/${r.outing_id}/voice-notes/${r.id}`,
    };
  }

  const META = `n.id, n.outing_id, n.channel, n.sender_id, n.mime, n.duration_ms, n.bytes, n.recorded_at, n.created_at, n.expires_at`;

  async function upload(user, outingId, { buf, durationMs, channel, clientId, ageMs } = {}) {
    const m = await requireMember(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const ch = await allowedChannel(outingId, channel, user.id);
    if (!Buffer.isBuffer(buf) || buf.length < NOTE_MIN_BYTES) throw err('invalid_clip', 400);
    if (buf.length > NOTE_MAX_BYTES) throw err('too_large', 413);
    const mime = sniffAudio(buf);
    if (!mime) throw err('invalid_clip', 415);
    const ms = parseNoteDurationMs(durationMs);
    if (ms === null) throw err('invalid_clip_duration', 400);
    const cid = typeof clientId === 'string' && CLIENT_ID_RE.test(clientId) ? clientId : null;
    if (!cid) throw err('invalid_client_id', 400);
    /* A retry of an upload we already have: the same note, announced once only. */
    const [dup] = await q(`SELECT ${META} FROM sary.ptt_voice_notes n WHERE n.sender_id = $1 AND n.client_id = $2 AND n.outing_id = $3`, [user.id, cid, outingId]);
    if (dup) {
      stats.duplicates += 1;
      return { note: shape(dup), duplicate: true };
    }
    if (now() - (lastAt.get(user.id) || 0) < NOTE_MIN_GAP_MS) throw err('too_frequent', 429);
    const age = parseAgeMs(ageMs);
    const [row] = await q(
      `INSERT INTO sary.ptt_voice_notes (outing_id, channel, sender_id, client_id, mime, duration_ms, bytes, audio, recorded_at, expires_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now() - make_interval(secs => $9::double precision / 1000), now() + make_interval(secs => $10::double precision / 1000))
       ON CONFLICT (sender_id, client_id) DO NOTHING
       RETURNING id, outing_id, channel, sender_id, mime, duration_ms, bytes, recorded_at, created_at, expires_at`,
      [outingId, ch, user.id, cid, mime, ms, buf.length, buf, age, NOTE_TTL_MS],
    );
    if (!row) {
      /* Raced with itself (two retries at once): whichever landed is the note. */
      const [again] = await q(`SELECT ${META} FROM sary.ptt_voice_notes n WHERE n.sender_id = $1 AND n.client_id = $2`, [user.id, cid]);
      if (!again || again.outing_id !== outingId) throw err('invalid_client_id', 409);
      stats.duplicates += 1;
      return { note: shape(again), duplicate: true };
    }
    lastAt.set(user.id, now());
    if (lastAt.size > 10_000) for (const [k, t] of lastAt) if (now() - t > 60_000) lastAt.delete(k);
    stats.uploaded += 1;
    /* Keep the newest few hundred of this trip. */
    await q(
      `DELETE FROM sary.ptt_voice_notes WHERE id IN (
         SELECT id FROM sary.ptt_voice_notes WHERE outing_id = $1 ORDER BY created_at DESC OFFSET $2)`,
      [outingId, OUTING_MAX_NOTES],
    ).catch(() => {});
    const note = shape(row);
    const name = String(m.invited_name || user.display_name || '').slice(0, 40) || 'عضو';
    /* «احظر»: whoever blocked the sender neither hears it play by itself nor gets woken for it. */
    const blockers = blockersOf ? await blockersOf(user.id).catch(() => new Set()) : new Set();
    deliver(outingId, user.id, name, note, blockers);
    return { note, duplicate: false };
  }

  /** The old clip shape, for sockets that predate voice notes (they fetch `url` with their token). */
  function asClip(note) {
    return { id: note.id, user_id: note.user_id, mime: note.mime, duration_ms: note.duration_ms, bytes: note.bytes, at: note.recorded_at, expires_at: note.expires_at, url: note.url, channel: note.channel };
  }

  function deliver(outingId, senderId, name, note, blockers = new Set()) {
    const ch = note.channel;
    const away = hub.awayUsers ? hub.awayUsers(outingId) : new Set();
    /** On screen right now, with a socket that will play or show it: no push for them. */
    const watching = new Set([senderId]);
    for (const c of hub.roomOf ? hub.roomOf(outingId) : []) {
      if (!c.userId || c.userId === senderId || !isAllowed(outingId, ch, c.userId)) continue;
      if (blockers.has(c.userId)) continue;
      if (c.caps?.has('voice_notes')) {
        hub.send(c, { type: 'voice_note', note });
        stats.socket += 1;
        if (!away.has(c.userId)) watching.add(c.userId);
      } else if (radioOf(outingId, c.userId) === ch) {
        hub.send(c, { type: 'voice_clip', clip: asClip(note) });
        stats.compat += 1;
        if (!away.has(c.userId)) watching.add(c.userId);
      }
    }
    for (const b of blockers) watching.add(b);
    void wake(outingId, senderId, name, note, watching).catch((e) => log('[outings-voice] push', e?.code || e?.message));
  }

  /** Members tuned to the note's channel and not looking: Push to Talk first, an alert for the rest. */
  async function wake(outingId, senderId, name, note, watching) {
    const ch = note.channel;
    const rows = await q(`SELECT user_id FROM sary.outing_members WHERE outing_id = $1 AND status = 'active' AND user_id <> $2`, [outingId, senderId]);
    const targets = rows.map((r) => r.user_id).filter((u) => !watching.has(u) && isAllowed(outingId, ch, u) && radioOf(outingId, u) === ch);
    if (!targets.length) return;
    const fresh = Math.max(0, NOTE_AUTOPLAY_MS - note.age_ms);
    let reached = new Set();
    if (apns?.enabled && apns.notifyPtt && fresh > 5_000) {
      const set = new Set(targets);
      const r = await apns.notifyPtt(outingId, senderId, {
        name,
        burst: null,
        channel: ch,
        type: 'voice_note',
        include: (u) => set.has(u),
        expiresInS: fresh / 1000,
        extra: { note: { id: note.id, channel: ch, user_id: senderId, duration_ms: note.duration_ms, recorded_at: note.recorded_at, url: note.url } },
      });
      reached = r?.users || new Set();
      stats.ptt_pushed += r?.sent || 0;
    }
    const rest = targets.filter((u) => !reached.has(u));
    if (!rest.length || !push?.enabled) return;
    const secs = Math.max(1, Math.round(note.duration_ms / 1000));
    const r = await push.notifyMembers(outingId, senderId, {
      type: 'voice_note',
      title: `${name} · قناة الطلعة`,
      body: `🎙️ رسالة صوتية (${secs} ث) — افتح الطلعة وتسمعها`,
      tag: `sary-voice-${note.id}`,
      ttl: 30 * 60,
      urgency: 'high',
      only_users: rest,
      channel_id: ch,
      extra: { note_id: note.id },
    });
    stats.alerted += r?.sent || 0;
  }

  async function list(user, outingId, { channel } = {}) {
    const m = await requireMember(user, outingId);
    const ch = await allowedChannel(outingId, channel, user.id);
    if (m.outing_status === 'ended') return { notes: [], channel: ch, server_now: new Date(now()).toISOString() };
    const rows = await q(
      `SELECT ${META} FROM sary.ptt_voice_notes n
       JOIN sary.outing_members s ON s.outing_id = n.outing_id AND s.user_id = n.sender_id AND s.status = 'active'
       WHERE n.outing_id = $1 AND n.channel = $2 AND n.expires_at > now()
         AND NOT EXISTS (SELECT 1 FROM sary.user_blocks ub WHERE ub.blocker_id = $4 AND ub.blocked_id = n.sender_id)
       ORDER BY n.created_at DESC LIMIT $3`,
      [outingId, ch, LIST_LIMIT, user.id],
    );
    const at = now();
    return { notes: rows.map((r) => shape(r, at)), channel: ch, server_now: new Date(at).toISOString() };
  }

  async function fetch(user, outingId, noteId) {
    const m = await requireMember(user, outingId);
    if (!v.isUuid(noteId) || m.outing_status === 'ended') throw err('clip_gone', 404);
    const [row] = await q(
      `SELECT ${META}, n.audio FROM sary.ptt_voice_notes n
       JOIN sary.outing_members s ON s.outing_id = n.outing_id AND s.user_id = n.sender_id AND s.status = 'active'
       WHERE n.id = $1 AND n.outing_id = $2 AND n.expires_at > now()`,
      [noteId, outingId],
    );
    if (!row) throw err('clip_gone', 404);
    if (!isPublicId(row.channel)) {
      if (pttChannels && !pttChannels.loaded(outingId)) await pttChannels.load(outingId);
      /* Not on that private channel: it does not exist for them. */
      if (!isAllowed(outingId, row.channel, user.id)) throw err('clip_gone', 404);
    }
    stats.fetched += 1;
    return { meta: shape(row), buf: row.audio };
  }

  /** Every 10 minutes: expired, trip over, sender gone, private channel closed. */
  async function sweep() {
    const rows = await q(
      `DELETE FROM sary.ptt_voice_notes n
       WHERE n.expires_at <= now()
          OR EXISTS (SELECT 1 FROM sary.outings o WHERE o.id = n.outing_id AND o.status = 'ended')
          OR NOT EXISTS (SELECT 1 FROM sary.outing_members s WHERE s.outing_id = n.outing_id AND s.user_id = n.sender_id AND s.status = 'active')
          OR (n.channel !~ '^[1-5]$' AND NOT EXISTS (SELECT 1 FROM sary.ptt_channels c WHERE c.id::text = n.channel AND c.outing_id = n.outing_id))
       RETURNING n.id`,
    );
    stats.swept += rows.length;
    return rows.length;
  }

  return { upload, list, fetch, sweep, stats, config: { maxMs: NOTE_MAX_MS, maxBytes: NOTE_MAX_BYTES, ttlMs: NOTE_TTL_MS, autoplayMs: NOTE_AUTOPLAY_MS } };
}

/** A fresh idempotency key (tests, tools). */
const newClientId = () => crypto.randomBytes(12).toString('hex');

module.exports = {
  createVoiceNotes,
  parseNoteDurationMs,
  parseAgeMs,
  newClientId,
  NOTE_MAX_MS,
  NOTE_MAX_BYTES,
  NOTE_TTL_MS,
  NOTE_AUTOPLAY_MS,
};
