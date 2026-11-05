'use strict';

/**
 * WebSocket endpoint for live outings: /api/outings/live
 *
 * Browsers cannot set headers on a WebSocket, and a token in the URL ends up
 * in proxy logs, so the first frame authenticates:
 *   → { type: 'auth', token, outing_id }
 *   ← { type: 'ready', snapshot }        (or close 4401 / 4404)
 * then
 *   → { type: 'position', id, fix }      ← { type: 'ack', id, ok, reason? }
 *   → { type: 'presence', away }
 *   → { type: 'heartbeat', gps, battery? } (no coordinates; "I am still here"; battery only where the phone can tell)
 *   → { type: 'ping' }                   ← { type: 'pong', server_now }
 *   → { type: 'note', id, text }         ← { type: 'note_ack', id, ok, note }  (everyone: member_note)
 *   ← position · presence · member_* · sos · rally · voice_clip · outing_status · owner_changed · closed
 *   ← return_timer · member_stuck · stuck_reply · stuck_clear · waypoint_added · waypoint_removed
 *     convoy_updated · plan_updated · checklist_updated   (see lib/outings/features.js)
 *   ← member_silent · member_resumed · member_going_offline   (see lib/outings/silence.js)
 *   ← media_state { state }   («قناة الطلعة», state or null — see lib/outings/media.js)
 *   (older builds' voice clips go over HTTP: POST/GET /api/outings/:id/clips — see routes/outings.js)
 *
 * Live push-to-talk «قناة الطلعة» (lib/outings/ptt.js): ptt_join / ptt_leave /
 * ptt_start / ptt_stop text frames, and BINARY audio frames from the talker,
 * relayed to the other joined members only. Binary frames are the only binary
 * this socket accepts, and have their own rate limit (not the 40-per-10 s one).
 */

const { WebSocketServer } = require('ws');
const { battery } = require('./validate');

const PATH = '/api/outings/live';
const AUTH_TIMEOUT_MS = 5_000;
const HEARTBEAT_MS = 25_000;
const MAX_FRAME_BYTES = 4 * 1024;
const MAX_MSGS_PER_10S = 40;
const MAX_SOCKETS_PER_USER_ROOM = 3;
/* Close codes. 4401 means "this token is no good": clients stop for good on it, so a slow
 * auth must never be reported with it (it used to be — see AUTH_TIMEOUT_CODE). */
const AUTH_TIMEOUT_CODE = 4408;
const OPEN = 1;

/** Socket lifetimes and close codes, numbers only (no user, no outing): GET /api/outings/health-style probes. */
function createSocketStats() {
  const closes = new Map(); // code → count
  let opened = 0;
  let ready = 0;
  let shortLived = 0; // closed < 15 s after opening
  return {
    open() {
      opened += 1;
    },
    ready() {
      ready += 1;
    },
    close(code, ms) {
      closes.set(code, (closes.get(code) || 0) + 1);
      if (ms < 15_000) shortLived += 1;
    },
    snapshot() {
      return { opened, ready, short_lived: shortLived, closes: Object.fromEntries([...closes].sort((a, b) => a[0] - b[0])) };
    },
  };
}

function attachOutingsSocket(server, { service, hub, ptt = null, path = PATH, authTimeoutMs = AUTH_TIMEOUT_MS, heartbeatMs = HEARTBEAT_MS, log = null } = {}) {
  const stats = createSocketStats();
  const debug = log || (process.env.SARY_WS_DEBUG === '1' ? (...a) => console.log('[outings-ws]', ...a) : null);
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES, perMessageDeflate: false });

  server.on('upgrade', (req, socket, head) => {
    let pathname = '';
    try {
      pathname = new URL(req.url, 'http://x').pathname;
    } catch {
      /* */
    }
    if (pathname !== path) return; // another upgrade handler may own it
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });

  wss.on('connection', (ws) => {
    const conn = { ws, userId: null, outingId: null, user: null, window: [] };
    const openedAt = Date.now();
    let authing = false;
    let wasReady = false;
    stats.open();
    /* Only a socket that never sent `auth` is timed out here. One whose auth is still being
     * checked (a slow database) waits for the answer: closing it then, and with 4401, told
     * the phone its token was bad and it stopped reconnecting for good. */
    let authTimer = setTimeout(() => {
      if (conn.userId) return;
      if (!authing) return ws.close(AUTH_TIMEOUT_CODE, 'auth_timeout');
      /* Checking for a long time already: a last, generous cap. */
      authTimer = setTimeout(() => {
        if (!conn.userId) ws.close(AUTH_TIMEOUT_CODE, 'auth_timeout');
      }, authTimeoutMs * 4);
      authTimer.unref?.();
    }, authTimeoutMs);
    authTimer.unref?.();

    const reply = (msg) => hub.send(conn, msg);

    ws.on('message', async (data, isBinary) => {
      conn.msgs = (conn.msgs || 0) + 1;
      if (isBinary) {
        /* Audio for the walkie-talkie. Without a relay, or before auth, binary is not allowed. */
        if (!ptt || !conn.userId) return ws.close(1003, 'text_only');
        if (!conn.outingId) return;
        ptt.audio(conn, data);
        return;
      }
      const t = Date.now();
      conn.window = conn.window.filter((x) => t - x < 10_000);
      conn.window.push(t);
      if (conn.window.length > MAX_MSGS_PER_10S) return; // drop, do not disconnect
      let msg;
      try {
        msg = JSON.parse(String(data));
      } catch {
        return;
      }
      if (!msg || typeof msg.type !== 'string') return;
      try {
        if (msg.type === 'auth') {
          if (conn.userId || authing) return;
          authing = true;
          const user = await service.authenticate(msg.token);
          if (!user) return ws.close(4401, 'unauthorized');
          const m = await service.membership(msg.outing_id, user.id, { fresh: true });
          if (!m || m.status !== 'active') return ws.close(4404, 'not_a_member');
          if (m.outing_status === 'ended') return ws.close(4410, 'outing_ended');
          clearTimeout(authTimer);
          /* The phone may have given up while we checked: never seat a closed socket in the room
           * (it would count as "online" and as one of this person's sockets forever). */
          if (ws.readyState !== OPEN) return;
          conn.userId = user.id;
          conn.user = user;
          hub.join(msg.outing_id, conn);
          /* A reload loop must not pile up sockets: keep the newest few. */
          const mine = hub.connectionsOf(msg.outing_id, user.id);
          for (const old of mine.slice(0, Math.max(0, mine.length - MAX_SOCKETS_PER_USER_ROOM))) {
            old.ws.close(4409, 'replaced');
          }
          const snapshot = await service.getOuting(user, msg.outing_id);
          wasReady = true;
          stats.ready();
          reply({ type: 'ready', snapshot });
          return;
        }
        if (!conn.userId || !conn.outingId) return;
        hub.touch(conn.outingId, conn.userId);
        if (msg.type === 'heartbeat') return hub.heartbeat(conn.outingId, conn.userId, msg.gps, battery(msg.battery));
        if (msg.type === 'ping') return reply({ type: 'pong', server_now: new Date().toISOString() });
        if (msg.type === 'presence') return hub.setAway(conn.outingId, conn.userId, msg.away === true);
        if (ptt && msg.type.startsWith('ptt_')) return void (await ptt.handle(conn, msg));
        if (msg.type === 'note') {
          try {
            const r = await service.setNote(conn.user, conn.outingId, msg.text);
            return reply({ type: 'note_ack', id: msg.id ?? null, ok: true, note: r.note });
          } catch (e) {
            return reply({ type: 'note_ack', id: msg.id ?? null, ok: false, reason: e.code || 'server_error' });
          }
        }
        if (msg.type === 'position') {
          const r = await service.recordPosition(conn.user, conn.outingId, msg.fix);
          reply({ type: 'ack', id: msg.id ?? null, ok: r.ok, reason: r.ok ? undefined : r.reason, server_now: new Date().toISOString() });
        }
      } catch (e) {
        /* Never echo internals; never log the frame (it may hold a position). */
        console.warn('[outings-ws]', e.code || e.message);
        reply({ type: 'error', code: e.code || 'server_error' });
        /* A failed auth leaves nothing to talk to: let the phone retry (not 4401: nothing says the token is bad). */
        if (msg.type === 'auth' && !wasReady && ws.readyState === OPEN) ws.close(1011, 'server_error');
      }
    });

    ws.on('close', (code) => {
      clearTimeout(authTimer);
      const ms = Date.now() - openedAt;
      stats.close(code, ms);
      if (debug) debug('close', { code, ms, ready: wasReady, msgs: conn.msgs || 0, pongs: ws.__pongs || 0 });
      ptt?.drop(conn);
      hub.leave(conn);
    });
    ws.on('error', () => {
      /* close follows */
    });
  });

  /* Dead phones (tunnel, battery) do not send a close frame. Ping them out. */
  const beat = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.__dead) return ws.terminate();
      ws.__dead = true;
      try {
        ws.ping();
      } catch {
        /* */
      }
    });
    hub.sweepPollers();
  }, heartbeatMs);
  beat.unref?.();
  wss.on('connection', (ws) => {
    ws.on('pong', () => {
      ws.__pongs = (ws.__pongs || 0) + 1;
      ws.__dead = false;
    });
    ws.on('message', () => {
      ws.__dead = false;
    });
  });

  return {
    wss,
    stats: () => stats.snapshot(),
    close() {
      clearInterval(beat);
      for (const ws of wss.clients) ws.terminate();
      wss.close();
    },
  };
}

module.exports = { attachOutingsSocket, OUTINGS_WS_PATH: PATH, AUTH_TIMEOUT_CODE };
