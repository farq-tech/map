'use strict';

/**
 * «قناة الطلعة» — a live walkie-talkie over the outing WebSocket.
 *
 * Half duplex: one talker per CHANNEL at a time («ترددات», see
 * lib/outings/ptt-channels.js). Every trip has five public channels '1'…'5'
 * and the private ones its leader opens. A socket listens to exactly one
 * channel; a phone that never names one (builds 9–12) is on '1', so for it
 * nothing changed. The server only relays: audio frames go from the talker's
 * socket straight to the sockets that joined the same channel (and, for a
 * private channel, are on its member list — checked on join, on the floor
 * request and again on every frame), and are never written to disk or a
 * database. The only audio held at all is the current transmission's last few
 * seconds in memory, so a phone that iOS just woke with a Push to Talk
 * notification hears the start of the sentence; it is dropped the moment the
 * talker lets go.
 *
 * Text frames (JSON, on the same socket, after `auth`):
 *   → { type: 'ptt_join', channel?, channels? }
 *        ← { type: 'ptt_state', talker: {user_id,name,burst,since}|null, max_ms, channel }
 *        `channel` absent: '1' (or the one this socket was on). `channels: true`: this
 *        client understands channels → it also gets ptt_channels / _kicked / _invite.
 *        A private channel it is not invited to → ptt_channel_kicked {reason:'not_invited'} + '1'.
 *   → { type: 'ptt_join_channel', channel }    switch («غيّر التردد»): same answers as ptt_join;
 *        a transmission we were hearing on the old channel ends for us with
 *        ptt_idle {reason:'switched'}; a floor we held there is released.
 *   → { type: 'ptt_leave' }              (mute «اكتم القناة»: no audio, no PTT pushes on this socket)
 *   → { type: 'ptt_start', id }          ← { type: 'ptt_grant', id, burst, max_ms, channel }
 *                                        | { type: 'ptt_deny', id, reason: busy|not_joined|rate_limited|not_allowed|not_invited, talker_id? }
 *   → { type: 'ptt_stop', id? }
 *   ← { type: 'ptt_talker', user_id, name, burst, since, channel }  (to that channel's listeners, not the talker)
 *   ← { type: 'ptt_idle', user_id, burst, reason, channel }         (to that channel's listeners and the talker)
 *        reason: released | max_duration | silence | left | switched | removed | closed
 *   ← { type: 'ptt_channels', current, can_create, channels: [{ id, kind, name, listeners, talker, members?, created_by?, can_manage? }] }
 *        (channel-aware sockets only; a private channel only to its members)
 *   ← { type: 'ptt_channel_kicked', channel, reason: removed|closed|not_invited }  → now on '1'
 *   ← { type: 'ptt_channel_invite', channel, name, by }
 *
 * Binary frames (talker → server → listeners, relayed byte for byte):
 *   [0]   version 0x01
 *   [1]   burst (u8, from ptt_grant; frames of an older burst are dropped)
 *   [2-3] sequence number (u16 big-endian, wraps)
 *   [4..] one or more encoded audio packets (the client's codec; opaque here)
 * The channel is not in the frame: it is the talker's socket's channel.
 */

const { channelId, isPublicId, publicName, canManageOuting, PTT_PUBLIC_CHANNELS, PTT_DEFAULT_CHANNEL } = require('./ptt-channels');

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

/** Without the channel registry (tests, a relay on its own): the five public channels only. */
const PUBLIC_ONLY = Object.freeze({
  load: async () => new Map(),
  loaded: () => true,
  isAllowed: (_o, id) => isPublicId(id),
  view: (_o, _u, _m, live) => PTT_PUBLIC_CHANNELS.map((id) => ({ id, kind: 'public', name: publicName(id), ...live(id) })),
});

function createPttRelay({ hub, service, apns = null, channels = PUBLIC_ONLY, now = () => Date.now(), options = {}, log = console.warn } = {}) {
  const cfg = { ...DEFAULTS, ...options };
  /** `${outingId}|${channel}` → { conn, userId, name, channel, burst, since, lastFrameAt, frames[], maxTimer, silenceTimer } */
  const floors = new Map();
  /** outingId → last burst number handed out (u8), shared by the trip's channels. */
  const bursts = new Map();
  const startHits = new Map(); // userId → [t]
  /** outingId → Map(userId → channel): where each member last listened (who to wake for which channel). */
  const lastChannel = new Map();
  const stats = { granted: 0, denied: 0, relayed: 0, dropped: 0, pushed: 0, switched: 0, kicked: 0 };

  const fk = (outingId, ch) => `${outingId}|${ch}`;
  const joined = (conn) => Boolean(conn.ptt?.joined && conn.outingId);
  const chanOf = (conn) => conn.ptt?.channel || PTT_DEFAULT_CHANNEL;

  const roomConns = (outingId) => hub.roomOf(outingId);

  /** Joined to this channel, and (private) still on its member list. */
  function listeners(outingId, ch, exceptUser) {
    return roomConns(outingId).filter((c) => joined(c) && chanOf(c) === ch && c.userId !== exceptUser && channels.isAllowed(outingId, ch, c.userId));
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

  function remember(outingId, userId, ch) {
    if (!lastChannel.has(outingId)) lastChannel.set(outingId, new Map());
    lastChannel.get(outingId).set(userId, ch);
  }

  /** Where this member's radio is set (last join / switch); '1' if we never heard. */
  function currentChannel(outingId, userId) {
    return lastChannel.get(outingId)?.get(userId) || PTT_DEFAULT_CHANNEL;
  }

  function release(outingId, ch, reason) {
    const key = fk(outingId, ch);
    const f = floors.get(key);
    if (!f) return false;
    floors.delete(key);
    clearTimeout(f.maxTimer);
    clearTimeout(f.silenceTimer);
    f.frames.length = 0;
    const msg = { type: 'ptt_idle', user_id: f.userId, burst: f.burst, reason, channel: ch };
    const heard = listeners(outingId, ch, null);
    for (const c of heard) sendJson(c, msg);
    /* The talker hears why, even if they muted their own listening (or switched) meanwhile. */
    if (!heard.includes(f.conn)) sendJson(f.conn, msg);
    channelsChanged(outingId);
    return true;
  }

  function armSilence(outingId, f) {
    clearTimeout(f.silenceTimer);
    f.silenceTimer = setTimeout(() => {
      if (floors.get(fk(outingId, f.channel)) === f) release(outingId, f.channel, 'silence');
    }, cfg.silenceMs);
    f.silenceTimer.unref?.();
  }

  /** Not to be woken for `ch`: the talker, and anyone with a live, foreground socket on it. */
  function skipForPush(outingId, ch, talkerId) {
    const away = hub.awayUsers ? hub.awayUsers(outingId) : new Set();
    const set = new Set([talkerId]);
    for (const c of roomConns(outingId)) if (joined(c) && chanOf(c) === ch && !away.has(c.userId)) set.add(c.userId);
    return set;
  }

  /** May be woken for `ch`: their radio is set to it, and (private) they are invited. */
  function wantsPush(outingId, ch) {
    return (userId) => currentChannel(outingId, userId) === ch && channels.isAllowed(outingId, ch, userId);
  }

  async function start(conn, msg = {}) {
    const id = msg.id ?? null;
    const outingId = conn.outingId;
    const deny = (reason, extra = {}) => {
      stats.denied += 1;
      sendJson(conn, { type: 'ptt_deny', id, reason, ...extra });
    };
    if (!joined(conn)) return deny('not_joined');
    const ch = chanOf(conn);
    if (!channels.isAllowed(outingId, ch, conn.userId)) return deny('not_invited');
    const key = fk(outingId, ch);
    const cur = floors.get(key);
    if (cur && cur.conn === conn) {
      return sendJson(conn, { type: 'ptt_grant', id, burst: cur.burst, max_ms: Math.max(0, cfg.maxTalkMs - (now() - cur.since)), channel: ch });
    }
    if (cur) return deny('busy', { talker_id: cur.userId });
    if (!startAllowed(conn.userId)) return deny('rate_limited');
    /* Membership is re-checked (cached ≤15 s; removal closes the socket at once anyway). */
    const m = service ? await service.membership(outingId, conn.userId) : { status: 'active', outing_status: 'active' };
    if (!m || m.status !== 'active' || m.outing_status === 'ended') return deny('not_allowed');
    /* Someone may have taken the floor — or moved us — while we awaited the check. */
    if (conn.outingId !== outingId || !joined(conn) || chanOf(conn) !== ch) return deny('not_joined');
    if (!channels.isAllowed(outingId, ch, conn.userId)) return deny('not_invited');
    const raced = floors.get(key);
    if (raced) return raced.conn === conn ? undefined : deny('busy', { talker_id: raced.userId });

    const f = {
      conn,
      userId: conn.userId,
      name: String(conn.user?.display_name || '').slice(0, 40) || 'عضو',
      channel: ch,
      burst: nextBurst(outingId),
      since: now(),
      lastFrameAt: now(),
      frames: [],
      maxTimer: null,
      silenceTimer: null,
    };
    floors.set(key, f);
    stats.granted += 1;
    f.maxTimer = setTimeout(() => {
      if (floors.get(key) === f) release(outingId, ch, 'max_duration');
    }, cfg.maxTalkMs);
    f.maxTimer.unref?.();
    armSilence(outingId, f);
    sendJson(conn, { type: 'ptt_grant', id, burst: f.burst, max_ms: cfg.maxTalkMs, channel: ch });
    const ev = { type: 'ptt_talker', ...talkerOut(f), channel: ch };
    for (const c of listeners(outingId, ch, conn.userId)) sendJson(c, ev);
    channelsChanged(outingId);

    if (apns?.enabled && apns.notifyPtt) {
      void apns
        .notifyPtt(outingId, conn.userId, { name: f.name, burst: f.burst, channel: ch, skipUsers: skipForPush(outingId, ch, conn.userId), include: wantsPush(outingId, ch) })
        .then((r) => {
          stats.pushed += r?.sent || 0;
        })
        .catch((e) => log('[outings-ptt] push', e?.code || e?.message));
    }
  }

  function stop(conn) {
    const ch = chanOf(conn);
    const f = conn.outingId && floors.get(fk(conn.outingId, ch));
    if (f && f.conn === conn) release(conn.outingId, ch, 'released');
  }

  /** ptt_state for the channel `conn` is on now, plus the current sentence so far. */
  function sendState(conn) {
    const ch = chanOf(conn);
    const f = floors.get(fk(conn.outingId, ch));
    const other = f && f.userId !== conn.userId ? f : null;
    sendJson(conn, { type: 'ptt_state', talker: talkerOut(other), max_ms: cfg.maxTalkMs, channel: ch });
    /* A phone that just woke (or just tuned in) hears the sentence from its start. */
    if (other) for (const b of other.frames) sendBinary(conn, b);
  }

  /** Put `conn` on `ch` (already authorised), ending what it heard / held on the old one. */
  function tune(conn, ch) {
    const outingId = conn.outingId;
    const prev = conn.ptt.joined ? chanOf(conn) : null;
    if (prev && prev !== ch) {
      const f = floors.get(fk(outingId, prev));
      if (f && f.conn === conn) release(outingId, prev, 'left');
      else if (f) sendJson(conn, { type: 'ptt_idle', user_id: f.userId, burst: f.burst, reason: 'switched', channel: prev });
      stats.switched += 1;
    }
    conn.ptt.joined = true;
    conn.ptt.channel = ch;
    remember(outingId, conn.userId, ch);
    sendState(conn);
  }

  /** Can `conn` be on `ch`? Private: loads the trip's channel list first (fail closed). */
  async function authorise(conn, ch) {
    if (isPublicId(ch)) return true;
    const outingId = conn.outingId;
    if (!channels.loaded(outingId)) {
      try {
        await channels.load(outingId);
      } catch (e) {
        log('[outings-ptt] channels', e?.code || e?.message);
        return false;
      }
    }
    return conn.outingId === outingId && channels.isAllowed(outingId, ch, conn.userId);
  }

  /** ptt_join (listen; `channel` optional) and ptt_join_channel (switch to `channel`). */
  async function join(conn, msg = {}, { switching = false } = {}) {
    if (!conn.outingId) return;
    const outingId = conn.outingId;
    const prev = conn.ptt;
    conn.ptt = {
      joined: prev?.joined === true,
      channel: prev?.channel || PTT_DEFAULT_CHANNEL,
      aware: prev?.aware === true || msg.channels === true || switching,
      window: prev?.window || [],
      bytes: prev?.bytes || [],
      m: prev?.m || null,
    };
    const p = conn.ptt;
    if (p.aware && !p.m && service?.membership) {
      p.m = await service.membership(outingId, conn.userId).catch(() => null);
    }
    const asked = msg.channel === undefined || msg.channel === null ? null : channelId(msg.channel);
    let ch = asked || (switching ? PTT_DEFAULT_CHANNEL : p.channel);
    if (!(await authorise(conn, ch))) {
      if (conn.outingId !== outingId) return;
      sendJson(conn, { type: 'ptt_channel_kicked', channel: ch, reason: 'not_invited' });
      ch = PTT_DEFAULT_CHANNEL;
    }
    /* Kicked out of the trip, or a newer join replaced this one, while we waited. */
    if (conn.outingId !== outingId || conn.ptt !== p) return;
    tune(conn, ch);
    channelsChanged(outingId);
  }

  function leave(conn) {
    if (!conn.ptt) return;
    const ch = chanOf(conn);
    conn.ptt.joined = false;
    const f = conn.outingId && floors.get(fk(conn.outingId, ch));
    if (f && f.conn === conn) release(conn.outingId, ch, 'left');
    if (conn.outingId) channelsChanged(conn.outingId);
  }

  /** Socket closed / kicked: never leave a dead talker holding the floor. */
  function drop(conn) {
    if (conn.ptt) conn.ptt.joined = false;
    /* By the connection, not conn.outingId: a kick clears that before the socket closes. */
    for (const [key, f] of [...floors]) {
      if (f.conn !== conn) continue;
      const i = key.indexOf('|');
      release(key.slice(0, i), key.slice(i + 1), 'left');
    }
    if (conn.outingId) channelsChanged(conn.outingId);
  }

  /** A binary WS message. Returns true when relayed. Never throws, never closes. */
  function audio(conn, data) {
    const buf = Buffer.isBuffer(data) ? data : Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data);
    const outingId = conn.outingId;
    const ch = chanOf(conn);
    const f = outingId && floors.get(fk(outingId, ch));
    const dropIt = () => {
      stats.dropped += 1;
      return false;
    };
    if (!f || f.conn !== conn) return dropIt();
    if (buf.length <= HEADER_BYTES || buf.length > cfg.maxFrameBytes) return dropIt();
    if (buf[0] !== VERSION || buf[1] !== f.burst) return dropIt();
    /* A talker taken off a private channel mid-sentence: not one more frame. */
    if (!channels.isAllowed(outingId, ch, conn.userId)) return dropIt();
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
    for (const c of listeners(outingId, ch, conn.userId)) {
      if (sendBinary(c, buf)) stats.relayed += 1;
    }
    return true;
  }

  /** WS text message router; true when it was a ptt_* message. */
  async function handle(conn, msg) {
    switch (msg.type) {
      case 'ptt_join':
        await join(conn, msg);
        return true;
      case 'ptt_join_channel':
        await join(conn, msg, { switching: true });
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

  /* ---------- channels: who is where, kicks, invitations ---------- */

  /** { listeners: [userId], talker: {user_id,name}|null } of one channel, live. */
  function channelLive(outingId, ch) {
    const users = new Set();
    for (const c of roomConns(outingId)) if (joined(c) && chanOf(c) === ch && channels.isAllowed(outingId, ch, c.userId)) users.add(c.userId);
    const f = floors.get(fk(outingId, ch));
    return { listeners: [...users], talker: f ? { user_id: f.userId, name: f.name } : null };
  }

  /** Coalesced per trip: a burst of joins sends one list. */
  const pendingLists = new Set();
  function channelsChanged(outingId) {
    if (!outingId || pendingLists.has(outingId)) return;
    pendingLists.add(outingId);
    setImmediate(() => {
      pendingLists.delete(outingId);
      sendChannels(outingId);
    });
  }

  function sendChannels(outingId) {
    const live = (id) => channelLive(outingId, id);
    for (const c of roomConns(outingId)) {
      if (!c.ptt?.aware) continue;
      const m = c.ptt.m || null;
      sendJson(c, {
        type: 'ptt_channels',
        current: c.ptt.joined ? chanOf(c) : null,
        can_create: canManageOuting(m) && m?.outing_status !== 'ended',
        channels: channels.view(outingId, c.userId, m, live),
      });
    }
  }

  /**
   * Off a channel at once (`users`: a Set of user ids, or null for everyone on it): a floor they
   * hold is released, they are told why, and their radio goes back to '1'.
   */
  function kick(outingId, ch, users, reason) {
    for (const c of roomConns(outingId)) {
      if (!c.ptt || chanOf(c) !== ch || (users && !users.has(c.userId))) continue;
      const f = floors.get(fk(outingId, ch));
      if (f && f.conn === c) release(outingId, ch, reason);
      else if (f && joined(c)) sendJson(c, { type: 'ptt_idle', user_id: f.userId, burst: f.burst, reason, channel: ch });
      stats.kicked += 1;
      c.ptt.channel = PTT_DEFAULT_CHANNEL;
      if (c.ptt.aware) sendJson(c, { type: 'ptt_channel_kicked', channel: ch, reason });
      if (c.ptt.joined) sendState(c);
    }
    /* Closed: nobody keeps talking into it, whoever they are. */
    if (!users) release(outingId, ch, reason);
    const last = lastChannel.get(outingId);
    if (last) for (const [uid, at] of last) if (at === ch && (!users || users.has(uid))) last.set(uid, PTT_DEFAULT_CHANNEL);
    channelsChanged(outingId);
  }

  function invited(outingId, ch, userIds, { name, by }) {
    const set = new Set(userIds);
    for (const c of roomConns(outingId)) if (c.ptt?.aware && set.has(c.userId)) sendJson(c, { type: 'ptt_channel_invite', channel: ch, name, by });
  }

  /** The outing ended / the member was removed: the hub closes sockets, this drops the floors. */
  function closeOuting(outingId) {
    for (const key of [...floors.keys()]) if (key.startsWith(`${outingId}|`)) release(outingId, key.slice(outingId.length + 1), 'left');
    bursts.delete(outingId);
    lastChannel.delete(outingId);
  }

  /** The current talker of a channel ('1' when not given — older callers). */
  function state(outingId, ch = PTT_DEFAULT_CHANNEL) {
    return talkerOut(floors.get(fk(outingId, ch)));
  }

  function close() {
    for (const key of [...floors.keys()]) {
      const i = key.indexOf('|');
      release(key.slice(0, i), key.slice(i + 1), 'left');
    }
  }

  const relay = { handle, audio, join, leave, start, stop, drop, closeOuting, state, close, stats, config: cfg, channelLive, channelsChanged, currentChannel, kick, invited };
  channels.setRelay?.(relay);
  return relay;
}

module.exports = { createPttRelay, PTT_FRAME_VERSION: VERSION, PTT_HEADER_BYTES: HEADER_BYTES, PTT_DEFAULTS: DEFAULTS };
