'use strict';

/**
 * «قناة الطلعة» — a live walkie-talkie over the outing WebSocket.
 *
 * Half duplex: one talker per outing at a time. The server only relays: audio
 * frames go from the talker's socket straight to the sockets of the other
 * members who joined the channel, and are never written to disk or a database.
 * The only audio held at all is the current transmission's last few seconds in
 * memory, so a phone that iOS just woke with a Push to Talk notification hears
 * the start of the sentence; it is dropped the moment the talker lets go.
 *
 * Text frames (JSON, on the same socket, after `auth`):
 *   → { type: 'ptt_join' }               ← { type: 'ptt_state', talker: {user_id,name,burst,since}|null, max_ms }
 *   → { type: 'ptt_leave' }              (mute «اكتم القناة»: no audio, no PTT pushes on this socket)
 *   → { type: 'ptt_start', id }          ← { type: 'ptt_grant', id, burst, max_ms }
 *                                        | { type: 'ptt_deny', id, reason: busy|not_joined|rate_limited|not_allowed, talker_id? }
 *   → { type: 'ptt_stop', id? }
 *   ← { type: 'ptt_talker', user_id, name, burst, since }        (to joined members, not the talker)
 *   ← { type: 'ptt_idle', user_id, burst, reason }               (to joined members and the talker)
 *        reason: released | max_duration | silence | left
 *
 * Binary frames (talker → server → listeners, relayed byte for byte):
 *   [0]   version 0x01
 *   [1]   burst (u8, from ptt_grant; frames of an older burst are dropped)
 *   [2-3] sequence number (u16 big-endian, wraps)
 *   [4..] one or more encoded audio packets (the client's codec; opaque here)
 */

const VERSION = 1;
const HEADER_BYTES = 4;

const DEFAULTS = Object.freeze({
  maxTalkMs: 60_000,
  /* No audio for this long while holding the floor → released (a phone that went into a tunnel). */
  silenceMs: 4_000,
  maxFrameBytes: 1_200,
  /* 20 ms frames are 50/s; leave room for jitter on the uplink. */
  maxFramesPerSec: 80,
  maxBytesPerSec: 24_000,
  /* Floor requests per user per minute: talking in turns, not a flood. */
  maxStartsPerMin: 20,
  /* Catch-up for a phone that just woke: ~3 s of 40 ms frames. */
  catchUpFrames: 75,
  /* A listener this far behind skips frames rather than buffering without end. */
  maxBufferedBytes: 64 * 1024,
});

function createPttRelay({ hub, service, apns = null, now = () => Date.now(), options = {}, log = console.warn } = {}) {
  const cfg = { ...DEFAULTS, ...options };
  /** outingId → { conn, userId, name, burst, since, lastFrameAt, frames[], maxTimer, silenceTimer } */
  const floors = new Map();
  /** outingId → last burst number handed out (u8). */
  const bursts = new Map();
  const startHits = new Map(); // userId → [t]
  const stats = { granted: 0, denied: 0, relayed: 0, dropped: 0, pushed: 0 };

  const joined = (conn) => Boolean(conn.ptt?.joined && conn.outingId);

  const roomConns = (outingId) => hub.roomOf(outingId);

  function listeners(outingId, exceptUser) {
    return roomConns(outingId).filter((c) => joined(c) && c.userId !== exceptUser);
  }

  function sendJson(conn, msg) {
    hub.send(conn, msg);
  }

  function sendBinary(conn, buf) {
    const ws = conn.ws;
    if (ws.readyState !== 1) return false;
    if (ws.bufferedAmount > cfg.maxBufferedBytes) return false;
    try {
      ws.send(buf, { binary: true });
      return true;
    } catch {
      return false;
    }
  }

  function talkerOut(f) {
    return f ? { user_id: f.userId, name: f.name, burst: f.burst, since: new Date(f.since).toISOString() } : null;
  }

  function nextBurst(outingId) {
    const b = ((bursts.get(outingId) ?? 0) % 255) + 1; // 1..255, never 0
    bursts.set(outingId, b);
    return b;
  }

  function startAllowed(userId) {
    const t = now();
    const hits = (startHits.get(userId) || []).filter((x) => t - x < 60_000);
    hits.push(t);
    startHits.set(userId, hits);
    if (startHits.size > 10_000) for (const [k, v] of startHits) if (!v.some((x) => t - x < 60_000)) startHits.delete(k);
    return hits.length <= cfg.maxStartsPerMin;
  }

  function release(outingId, reason) {
    const f = floors.get(outingId);
    if (!f) return false;
    floors.delete(outingId);
    clearTimeout(f.maxTimer);
    clearTimeout(f.silenceTimer);
    f.frames.length = 0;
    const msg = { type: 'ptt_idle', user_id: f.userId, burst: f.burst, reason };
    for (const c of listeners(outingId, null)) sendJson(c, msg);
    /* The talker hears why, even if they muted their own listening meanwhile. */
    if (!joined(f.conn)) sendJson(f.conn, msg);
    return true;
  }

  function armSilence(outingId, f) {
    clearTimeout(f.silenceTimer);
    f.silenceTimer = setTimeout(() => {
      if (floors.get(outingId) === f) release(outingId, 'silence');
    }, cfg.silenceMs);
    f.silenceTimer.unref?.();
  }

  /** Users to wake with a pushtotalk push: members whose app has no live, foreground, joined socket. */
  function awakeUsers(outingId) {
    const away = hub.awayUsers ? hub.awayUsers(outingId) : new Set();
    const set = new Set();
    for (const c of roomConns(outingId)) if (joined(c) && !away.has(c.userId)) set.add(c.userId);
    return set;
  }

  async function start(conn, msg = {}) {
    const id = msg.id ?? null;
    const outingId = conn.outingId;
    const deny = (reason, extra = {}) => {
      stats.denied += 1;
      sendJson(conn, { type: 'ptt_deny', id, reason, ...extra });
    };
    if (!joined(conn)) return deny('not_joined');
    const cur = floors.get(outingId);
    if (cur && cur.conn === conn) {
      return sendJson(conn, { type: 'ptt_grant', id, burst: cur.burst, max_ms: Math.max(0, cfg.maxTalkMs - (now() - cur.since)) });
    }
    if (cur) return deny('busy', { talker_id: cur.userId });
    if (!startAllowed(conn.userId)) return deny('rate_limited');
    /* Membership is re-checked (cached ≤15 s; removal closes the socket at once anyway). */
    const m = service ? await service.membership(outingId, conn.userId) : { status: 'active', outing_status: 'active' };
    if (!m || m.status !== 'active' || m.outing_status === 'ended') return deny('not_allowed');
    /* Someone may have taken the floor while we awaited the check. */
    const raced = floors.get(outingId);
    if (raced) return raced.conn === conn ? undefined : deny('busy', { talker_id: raced.userId });
    if (conn.outingId !== outingId || !joined(conn)) return deny('not_joined');

    const f = {
      conn,
      userId: conn.userId,
      name: String(conn.user?.display_name || '').slice(0, 40) || 'عضو',
      burst: nextBurst(outingId),
      since: now(),
      lastFrameAt: now(),
      frames: [],
      maxTimer: null,
      silenceTimer: null,
    };
    floors.set(outingId, f);
    stats.granted += 1;
    f.maxTimer = setTimeout(() => {
      if (floors.get(outingId) === f) release(outingId, 'max_duration');
    }, cfg.maxTalkMs);
    f.maxTimer.unref?.();
    armSilence(outingId, f);
    sendJson(conn, { type: 'ptt_grant', id, burst: f.burst, max_ms: cfg.maxTalkMs });
    const ev = { type: 'ptt_talker', ...talkerOut(f) };
    for (const c of listeners(outingId, conn.userId)) sendJson(c, ev);

    if (apns?.enabled && apns.notifyPtt) {
      const skip = awakeUsers(outingId);
      skip.add(conn.userId);
      void apns
        .notifyPtt(outingId, conn.userId, { name: f.name, burst: f.burst, skipUsers: skip })
        .then((r) => {
          stats.pushed += r?.sent || 0;
        })
        .catch((e) => log('[outings-ptt] push', e?.code || e?.message));
    }
  }

  function stop(conn) {
    const f = floors.get(conn.outingId);
    if (f && f.conn === conn) release(conn.outingId, 'released');
  }

  function join(conn) {
    if (!conn.outingId) return;
    conn.ptt = { joined: true, window: [], bytes: [] };
    const f = floors.get(conn.outingId);
    sendJson(conn, { type: 'ptt_state', talker: f && f.userId !== conn.userId ? talkerOut(f) : null, max_ms: cfg.maxTalkMs });
    /* A phone that just woke hears the sentence from its start. */
    if (f && f.userId !== conn.userId) for (const b of f.frames) sendBinary(conn, b);
  }

  function leave(conn) {
    if (!conn.ptt) return;
    conn.ptt.joined = false;
    const f = floors.get(conn.outingId);
    if (f && f.conn === conn) release(conn.outingId, 'left');
  }

  /** Socket closed / kicked: never leave a dead talker holding the floor. */
  function drop(conn) {
    if (conn.ptt) conn.ptt.joined = false;
    /* By the connection, not conn.outingId: a kick clears that before the socket closes. */
    for (const [oid, f] of [...floors]) if (f.conn === conn) release(oid, 'left');
  }

  /** A binary WS message. Returns true when relayed. Never throws, never closes. */
  function audio(conn, data) {
    const buf = Buffer.isBuffer(data) ? data : Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data);
    const outingId = conn.outingId;
    const f = outingId && floors.get(outingId);
    const dropIt = () => {
      stats.dropped += 1;
      return false;
    };
    if (!f || f.conn !== conn) return dropIt();
    if (buf.length <= HEADER_BYTES || buf.length > cfg.maxFrameBytes) return dropIt();
    if (buf[0] !== VERSION || buf[1] !== f.burst) return dropIt();
    const t = now();
    const p = conn.ptt;
    p.window = p.window.filter((x) => t - x < 1_000);
    p.bytes = p.bytes.filter((x) => t - x.t < 1_000);
    const bytes = p.bytes.reduce((s, x) => s + x.n, 0);
    if (p.window.length >= cfg.maxFramesPerSec || bytes + buf.length > cfg.maxBytesPerSec) return dropIt();
    p.window.push(t);
    p.bytes.push({ t, n: buf.length });
    f.lastFrameAt = t;
    armSilence(outingId, f);
    f.frames.push(buf);
    if (f.frames.length > cfg.catchUpFrames) f.frames.shift();
    for (const c of listeners(outingId, conn.userId)) {
      if (sendBinary(c, buf)) stats.relayed += 1;
    }
    return true;
  }

  /** WS text message router; true when it was a ptt_* message. */
  async function handle(conn, msg) {
    switch (msg.type) {
      case 'ptt_join':
        join(conn);
        return true;
      case 'ptt_leave':
        leave(conn);
        return true;
      case 'ptt_start':
        await start(conn, msg);
        return true;
      case 'ptt_stop':
        stop(conn);
        return true;
      default:
        return false;
    }
  }

  /** The outing ended / the member was removed: the hub closes sockets, this drops the floor. */
  function closeOuting(outingId) {
    release(outingId, 'left');
    bursts.delete(outingId);
  }

  function state(outingId) {
    return talkerOut(floors.get(outingId));
  }

  function close() {
    for (const oid of [...floors.keys()]) release(oid, 'left');
  }

  return { handle, audio, join, leave, start, stop, drop, closeOuting, state, close, stats, config: cfg };
}

module.exports = { createPttRelay, PTT_FRAME_VERSION: VERSION, PTT_HEADER_BYTES: HEADER_BYTES, PTT_DEFAULTS: DEFAULTS };
