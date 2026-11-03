'use strict';

/**
 * Rooms of live connections, one room per outing. A room only ever holds
 * sockets that passed the server-side membership check; events for one outing
 * are never written to a socket of another.
 *
 * Single-process by design today (one Railway instance). The service talks to
 * this through emit/kick/closeRoom/onlineUsers only, so a Postgres
 * LISTEN/NOTIFY or Redis fan-out can replace it without touching the rules.
 */

const OPEN = 1;

function createHub({ pollPresenceMs = 25_000, now = () => Date.now() } = {}) {
  const rooms = new Map(); // outingId -> Set<conn>
  const pollers = new Map(); // outingId -> Map(userId -> lastPollAt)
  const away = new Map(); // outingId -> Set(userId)

  function send(conn, msg) {
    if (conn.ws.readyState !== OPEN) return;
    try {
      conn.ws.send(typeof msg === 'string' ? msg : JSON.stringify(msg));
    } catch {
      /* a dying socket; its close handler cleans up */
    }
  }

  function onlineUsers(outingId) {
    const set = new Set();
    for (const c of rooms.get(outingId) || []) set.add(c.userId);
    const p = pollers.get(outingId);
    if (p) for (const [uid, at] of p) if (now() - at < pollPresenceMs) set.add(uid);
    return set;
  }

  function emit(outingId, event, { exceptUser } = {}) {
    const room = rooms.get(outingId);
    if (!room || !room.size) return 0;
    const payload = JSON.stringify(event);
    /* A member never needs their own position echoed back. */
    const skip = exceptUser || (event.type === 'position' ? event.position?.user_id : null);
    let n = 0;
    for (const c of room) {
      if (skip && c.userId === skip) continue;
      send(c, payload);
      n += 1;
    }
    return n;
  }

  function join(outingId, conn) {
    if (!rooms.has(outingId)) rooms.set(outingId, new Set());
    const room = rooms.get(outingId);
    const wasOnline = onlineUsers(outingId).has(conn.userId);
    room.add(conn);
    conn.outingId = outingId;
    if (!wasOnline) emit(outingId, { type: 'presence', user_id: conn.userId, online: true, away: false }, { exceptUser: conn.userId });
  }

  function leave(conn) {
    const { outingId } = conn;
    const room = outingId && rooms.get(outingId);
    if (!room || !room.delete(conn)) return;
    if (!room.size) rooms.delete(outingId);
    if (!onlineUsers(outingId).has(conn.userId)) {
      away.get(outingId)?.delete(conn.userId);
      emit(outingId, { type: 'presence', user_id: conn.userId, online: false, away: false });
    }
  }

  function setAway(outingId, userId, isAway) {
    if (!away.has(outingId)) away.set(outingId, new Set());
    const set = away.get(outingId);
    const was = set.has(userId);
    if (isAway) set.add(userId);
    else set.delete(userId);
    if (!set.size) away.delete(outingId);
    if (was !== isAway) emit(outingId, { type: 'presence', user_id: userId, online: true, away: isAway }, { exceptUser: userId });
  }

  function awayUsers(outingId) {
    return new Set(away.get(outingId) || []);
  }

  /** HTTP fallback clients count as online while they keep polling. */
  function touchPoll(outingId, userId) {
    if (!pollers.has(outingId)) pollers.set(outingId, new Map());
    const p = pollers.get(outingId);
    const wasOnline = onlineUsers(outingId).has(userId);
    p.set(userId, now());
    if (!wasOnline) emit(outingId, { type: 'presence', user_id: userId, online: true, away: false }, { exceptUser: userId });
  }

  function kick(outingId, userId, reason) {
    pollers.get(outingId)?.delete(userId);
    away.get(outingId)?.delete(userId);
    for (const c of [...(rooms.get(outingId) || [])]) {
      if (c.userId !== userId) continue;
      send(c, { type: 'closed', reason });
      leaveSilently(c);
      try {
        c.ws.close(4403, reason);
      } catch {
        /* */
      }
    }
  }

  function leaveSilently(conn) {
    const room = rooms.get(conn.outingId);
    if (!room) return;
    room.delete(conn);
    if (!room.size) rooms.delete(conn.outingId);
    conn.outingId = null;
  }

  function closeRoom(outingId, reason) {
    for (const c of [...(rooms.get(outingId) || [])]) {
      send(c, { type: 'closed', reason });
      leaveSilently(c);
      try {
        c.ws.close(4410, reason);
      } catch {
        /* */
      }
    }
    rooms.delete(outingId);
    pollers.delete(outingId);
    away.delete(outingId);
  }

  /** Drop poll presence that went quiet, announcing it once. */
  function sweepPollers() {
    for (const [oid, p] of pollers) {
      for (const [uid, at] of p) {
        if (now() - at < pollPresenceMs) continue;
        p.delete(uid);
        if (!onlineUsers(oid).has(uid)) emit(oid, { type: 'presence', user_id: uid, online: false, away: false });
      }
      if (!p.size) pollers.delete(oid);
    }
  }

  function connectionsOf(outingId, userId) {
    return [...(rooms.get(outingId) || [])].filter((c) => c.userId === userId);
  }

  function stats() {
    let sockets = 0;
    for (const r of rooms.values()) sockets += r.size;
    return { rooms: rooms.size, sockets };
  }

  return { join, leave, emit, connectionsOf, kick, closeRoom, onlineUsers, awayUsers, setAway, touchPoll, sweepPollers, stats, send };
}

module.exports = { createHub };
