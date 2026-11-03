'use strict';

/**
 * Shared outings — every rule about who may see whom lives here, on the
 * server, and is checked on every call. The client is never trusted to hide
 * something it should not have received.
 *
 *   outing:  created → active ⇄ paused → ended         (owner drives it)
 *   member:  active → left | removed                    (removed cannot rejoin)
 *   sharing: per member, on/off                         (off deletes the fix)
 *
 * Positions are shown only while the outing is `active`, only for active
 * members with sharing on, and only to active members. Pausing, leaving,
 * removal and ending delete the stored fix — there is no location history.
 */

const v = require('./validate');
const { sanitizeDiagnostics, outingRef } = require('./diagnostics');

class OutingError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

const err = (code, status) => new OutingError(code, status);

function envNumber(name, fallback, { min = -Infinity, max = Infinity } = {}) {
  const n = Number(process.env[name]);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function defaultConfig() {
  return {
    maxMembers: envNumber('OUTING_MAX_MEMBERS', 50, { min: 2, max: 200 }),
    inviteTtlHours: envNumber('OUTING_INVITE_TTL_HOURS', 24, { min: 1, max: 24 * 14 }),
    /* Broadcast every accepted fix, but write it to Postgres at most this often per member. */
    persistEveryMs: envNumber('OUTING_PERSIST_EVERY_MS', 10_000, { min: 0, max: 120_000 }),
    /* Server-side floor between two accepted fixes from one member. */
    minFixIntervalMs: envNumber('OUTING_MIN_FIX_INTERVAL_MS', 1_000, { min: 0, max: 60_000 }),
    /* The last known position is the one thing a group in the desert must not
     * lose, so it lives as long as the outing is open (idle outings end at
     * idleEndHours). Ending the outing deletes it. */
    positionRetentionHours: envNumber('OUTING_POSITION_RETENTION_HOURS', 24, { min: 0.1, max: 24 * 7 }),
    idleEndHours: envNumber('OUTING_IDLE_END_HOURS', 24, { min: 1, max: 24 * 30 }),
    membershipCacheMs: 15_000,
    authCacheMs: 60_000,
  };
}

function noopEvents() {
  return { emit() {}, kick() {}, closeRoom() {}, onlineUsers: () => new Set(), awayUsers: () => new Set(), linkState: () => new Map() };
}

function createOutingsService({ pool, events = noopEvents(), config = {}, now = () => Date.now() } = {}) {
  if (!pool) throw new Error('outings service needs a pool');
  const cfg = { ...defaultConfig(), ...config };
  const authCache = new Map(); // digest hex -> { user, at }
  const memberCache = new Map(); // outingId -> Map(userId -> { row, at })
  /* Freshest fix per member, ahead of the throttled DB write. outingId -> Map(userId -> pos) */
  const latest = new Map();
  const lastPersist = new Map(); // `${o}:${u}` -> ms
  let hub = events;

  const q = (text, params) => pool.query(text, params).then((r) => r.rows);

  async function tx(fn) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const out = await fn((text, params) => client.query(text, params).then((r) => r.rows));
      await client.query('COMMIT');
      return out;
    } catch (e) {
      await client.query('ROLLBACK').catch(() => {});
      throw e;
    } finally {
      client.release();
    }
  }

  function forgetOuting(outingId) {
    memberCache.delete(outingId);
  }

  function dropLatest(outingId, userId) {
    const room = latest.get(outingId);
    if (!room) return;
    if (userId) room.delete(userId);
    else latest.delete(outingId);
    if (userId && !room.size) latest.delete(outingId);
  }

  /* ---------- identity ---------- */

  function publicUser(row) {
    return { id: row.id, display_name: row.display_name, avatar: row.avatar || null, phone: row.phone || null };
  }

  async function createUser({ display_name, avatar } = {}) {
    const name = v.displayName(display_name);
    if (!name) throw err('invalid_name');
    const av = v.avatar(avatar);
    if (!av.ok) throw err('invalid_avatar');
    const token = v.newSecret();
    const [row] = await q(
      `INSERT INTO sary.users (display_name, avatar, token_hash) VALUES ($1, $2, $3)
       RETURNING id, display_name, avatar, phone`,
      [name, av.value, v.digest(token)],
    );
    return { user: publicUser(row), token };
  }

  async function authenticate(token) {
    if (!v.isSecretShaped(token)) return null;
    const d = v.digest(token);
    const key = d.toString('hex');
    const hit = authCache.get(key);
    if (hit && now() - hit.at < cfg.authCacheMs) return hit.user;
    const [row] = await q(
      `UPDATE sary.users SET last_seen_at = now()
       WHERE token_hash = $1
       RETURNING id, display_name, avatar, phone`,
      [d],
    );
    if (!row) {
      authCache.delete(key);
      return null;
    }
    const user = publicUser(row);
    authCache.set(key, { user, at: now() });
    if (authCache.size > 5000) authCache.delete(authCache.keys().next().value);
    return user;
  }

  async function updateProfile(user, patch = {}) {
    const sets = [];
    const params = [];
    if (patch.display_name !== undefined) {
      const name = v.displayName(patch.display_name);
      if (!name) throw err('invalid_name');
      params.push(name);
      sets.push(`display_name = $${params.length}`);
    }
    if (patch.avatar !== undefined) {
      const av = v.avatar(patch.avatar);
      if (!av.ok) throw err('invalid_avatar');
      params.push(av.value);
      sets.push(`avatar = $${params.length}`);
    }
    if (patch.phone !== undefined) {
      const ph = v.phone(patch.phone);
      if (ph === undefined) throw err('invalid_phone');
      params.push(ph);
      sets.push(`phone = $${params.length}`);
    }
    if (!sets.length) return user;
    params.push(user.id);
    const [row] = await q(
      `UPDATE sary.users SET ${sets.join(', ')} WHERE id = $${params.length}
       RETURNING id, display_name, avatar, phone`,
      params,
    );
    authCache.clear();
    const next = publicUser(row);
    /* Every open outing of this person sees the new name/photo. */
    const rooms = await q(
      `SELECT m.outing_id FROM sary.outing_members m JOIN sary.outings o ON o.id = m.outing_id
       WHERE m.user_id = $1 AND m.status = 'active' AND o.status <> 'ended'`,
      [user.id],
    );
    for (const r of rooms) hub.emit(r.outing_id, { type: 'member_updated', member: { user_id: next.id, display_name: next.display_name, avatar: next.avatar, phone: next.phone } });
    return next;
  }

  /* ---------- membership ---------- */

  async function membership(outingId, userId, { fresh = false } = {}) {
    if (!v.isUuid(outingId)) return null;
    const room = memberCache.get(outingId);
    const hit = room?.get(userId);
    if (!fresh && hit && now() - hit.at < cfg.membershipCacheMs) return hit.row;
    const [row] = await q(
      `SELECT o.id AS outing_id, o.status AS outing_status, o.owner_id,
              m.role, m.status, m.sharing
       FROM sary.outings o
       LEFT JOIN sary.outing_members m ON m.outing_id = o.id AND m.user_id = $2
       WHERE o.id = $1`,
      [outingId, userId],
    );
    const value = row || null;
    if (value) {
      if (!memberCache.has(outingId)) memberCache.set(outingId, new Map());
      memberCache.get(outingId).set(userId, { row: value, at: now() });
    }
    return value;
  }

  /** The one gate: an active member of an outing that exists. */
  async function requireMember(user, outingId, opts) {
    const m = await membership(outingId, user.id, opts);
    if (!m || m.status !== 'active') throw err('not_a_member', 404);
    return m;
  }

  async function requireOwner(user, outingId) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.role !== 'owner') throw err('owner_only', 403);
    return m;
  }

  /* ---------- outings ---------- */

  async function createInviteRow(run, outingId, userId, ttlHours) {
    const hours = Math.min(24 * 14, Math.max(1, Number(ttlHours) || cfg.inviteTtlHours));
    const token = v.newSecret();
    const [row] = await run(
      `INSERT INTO sary.outing_invites (outing_id, token_hash, created_by, expires_at)
       VALUES ($1, $2, $3, now() + make_interval(secs => $4))
       RETURNING expires_at`,
      [outingId, v.digest(token), userId, Math.round(hours * 3600)],
    );
    return { token, expires_at: row.expires_at };
  }

  async function createOuting(user, { name, ttl_hours } = {}) {
    const clean = v.outingName(name);
    if (!clean) throw err('invalid_outing_name');
    return tx(async (run) => {
      const [o] = await run(
        `INSERT INTO sary.outings (name, owner_id) VALUES ($1, $2) RETURNING id`,
        [clean, user.id],
      );
      await run(
        `INSERT INTO sary.outing_members (outing_id, user_id, role) VALUES ($1, $2, 'owner')`,
        [o.id, user.id],
      );
      const invite = await createInviteRow(run, o.id, user.id, ttl_hours);
      return { outing_id: o.id, invite };
    });
  }

  async function rotateInvite(user, outingId, { ttl_hours } = {}) {
    const m = await requireOwner(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    return tx(async (run) => {
      await run(
        `UPDATE sary.outing_invites SET revoked_at = now() WHERE outing_id = $1 AND revoked_at IS NULL`,
        [outingId],
      );
      return createInviteRow(run, outingId, user.id, ttl_hours);
    });
  }

  async function revokeInvites(user, outingId) {
    await requireOwner(user, outingId);
    const rows = await q(
      `UPDATE sary.outing_invites SET revoked_at = now()
       WHERE outing_id = $1 AND revoked_at IS NULL RETURNING id`,
      [outingId],
    );
    return { revoked: rows.length };
  }

  /** Why an invite cannot be used, or null when it can. */
  function inviteProblem(row) {
    if (!row) return 'invite_invalid';
    if (row.revoked_at) return 'invite_revoked';
    if (new Date(row.expires_at).getTime() <= now()) return 'invite_expired';
    if (row.outing_status === 'ended') return 'outing_ended';
    return null;
  }

  async function previewInvite(token) {
    if (!v.isSecretShaped(token)) throw err('invite_invalid', 404);
    const [row] = await q(
      `SELECT i.outing_id, i.expires_at, i.revoked_at,
              o.name, o.status AS outing_status, u.display_name AS owner_name,
              (SELECT count(*)::int FROM sary.outing_members m
                WHERE m.outing_id = o.id AND m.status = 'active') AS member_count
       FROM sary.outing_invites i
       JOIN sary.outings o ON o.id = i.outing_id
       JOIN sary.users u ON u.id = o.owner_id
       WHERE i.token_hash = $1`,
      [v.digest(token)],
    );
    const problem = inviteProblem(row);
    if (problem) throw err(problem, problem === 'invite_invalid' ? 404 : 410);
    return {
      outing_id: row.outing_id,
      name: row.name,
      status: row.outing_status,
      owner_name: row.owner_name,
      member_count: row.member_count,
      expires_at: row.expires_at,
    };
  }

  async function joinByInvite(user, token) {
    if (!v.isSecretShaped(token)) throw err('invite_invalid', 404);
    const result = await tx(async (run) => {
      const [row] = await run(
        `SELECT i.id, i.outing_id, i.expires_at, i.revoked_at, o.status AS outing_status
         FROM sary.outing_invites i JOIN sary.outings o ON o.id = i.outing_id
         WHERE i.token_hash = $1
         FOR UPDATE OF i, o`,
        [v.digest(token)],
      );
      const problem = inviteProblem(row);
      if (problem) throw err(problem, problem === 'invite_invalid' ? 404 : 410);
      const [existing] = await run(
        `SELECT status FROM sary.outing_members WHERE outing_id = $1 AND user_id = $2`,
        [row.outing_id, user.id],
      );
      if (existing?.status === 'active') return { outing_id: row.outing_id, already: true };
      if (existing?.status === 'removed') throw err('removed_from_outing', 403);
      const [{ n }] = await run(
        `SELECT count(*)::int AS n FROM sary.outing_members WHERE outing_id = $1 AND status = 'active'`,
        [row.outing_id],
      );
      if (n >= cfg.maxMembers) throw err('outing_full', 409);
      if (existing) {
        await run(
          `UPDATE sary.outing_members SET status = 'active', sharing = true, left_at = NULL, joined_at = now()
           WHERE outing_id = $1 AND user_id = $2`,
          [row.outing_id, user.id],
        );
      } else {
        await run(
          `INSERT INTO sary.outing_members (outing_id, user_id) VALUES ($1, $2)`,
          [row.outing_id, user.id],
        );
      }
      await run(`UPDATE sary.outing_invites SET uses = uses + 1 WHERE id = $1`, [row.id]);
      await run(`UPDATE sary.outings SET updated_at = now() WHERE id = $1`, [row.outing_id]);
      return { outing_id: row.outing_id, already: false };
    });
    forgetOuting(result.outing_id);
    if (!result.already) {
      hub.emit(result.outing_id, {
        type: 'member_joined',
        member: { user_id: user.id, display_name: user.display_name, avatar: user.avatar, phone: user.phone || null, role: 'member', sharing: true },
      });
    }
    return result;
  }

  async function members(outingId) {
    return q(
      `SELECT m.user_id, u.display_name, u.avatar, u.phone, m.role, m.sharing, m.joined_at
       FROM sary.outing_members m JOIN sary.users u ON u.id = m.user_id
       WHERE m.outing_id = $1 AND m.status = 'active'
       ORDER BY m.role = 'owner' DESC, m.joined_at`,
      [outingId],
    );
  }

  function shapePosition(userId, p) {
    return {
      user_id: userId,
      lat: p.lat,
      lng: p.lng,
      accuracy: p.accuracy,
      heading: p.heading,
      speed: p.speed,
      mode: p.mode || null,
      recorded_at: new Date(p.recorded_at).toISOString(),
      received_at: new Date(p.received_at).toISOString(),
    };
  }

  /** Visible positions: outing active, member active and sharing. DB merged with the fresher in-memory fix. */
  async function positions(outingId, outingStatus) {
    if (outingStatus !== 'active') return [];
    const rows = await q(
      `SELECT p.user_id, p.lat, p.lng, p.accuracy, p.heading, p.speed, p.mode, p.recorded_at, p.received_at
       FROM sary.member_positions p
       JOIN sary.outing_members m ON m.outing_id = p.outing_id AND m.user_id = p.user_id
       WHERE p.outing_id = $1 AND m.status = 'active' AND m.sharing
         AND p.received_at > now() - make_interval(secs => $2)`,
      [outingId, Math.round(cfg.positionRetentionHours * 3600)],
    );
    const byUser = new Map(rows.map((r) => [r.user_id, r]));
    const mem = latest.get(outingId);
    if (mem) {
      for (const [uid, p] of mem) {
        const db = byUser.get(uid);
        if (!db) {
          /* Only trust the memory copy for members the DB still shows as sharing. */
          continue;
        }
        if (new Date(p.recorded_at) > new Date(db.recorded_at)) byUser.set(uid, p);
      }
    }
    return [...byUser.entries()].map(([uid, p]) => shapePosition(uid, p));
  }

  async function getOuting(user, outingId) {
    const m = await requireMember(user, outingId, { fresh: true });
    const [o] = await q(
      `SELECT id, name, status, owner_id, created_at, started_at, ended_at FROM sary.outings WHERE id = $1`,
      [outingId],
    );
    const [mem, pos, inv] = await Promise.all([
      members(outingId),
      positions(outingId, o.status),
      m.role === 'owner'
        ? q(
            `SELECT expires_at FROM sary.outing_invites
             WHERE outing_id = $1 AND revoked_at IS NULL AND expires_at > now()
             ORDER BY created_at DESC LIMIT 1`,
            [outingId],
          )
        : Promise.resolve([]),
    ]);
    const online = hub.onlineUsers(outingId);
    const away = hub.awayUsers ? hub.awayUsers(outingId) : new Set();
    const link = hub.linkState ? hub.linkState(outingId) : new Map();
    return {
      outing: o,
      me: { user_id: user.id, role: m.role, sharing: m.sharing },
      members: mem.map((x) => ({
        ...x,
        online: online.has(x.user_id),
        away: away.has(x.user_id),
        last_seen_at: link.get(x.user_id)?.at ? new Date(link.get(x.user_id).at).toISOString() : null,
        gps: link.get(x.user_id)?.gps || null,
        note: o.status === 'ended' ? null : noteOf(outingId, x.user_id),
      })),
      positions: pos,
      invite: m.role === 'owner' ? { active: Boolean(inv[0]), expires_at: inv[0]?.expires_at || null } : null,
      server_now: new Date(now()).toISOString(),
    };
  }

  async function listOutings(user) {
    const rows = await q(
      `SELECT o.id, o.name, o.status, o.created_at, o.started_at, o.ended_at,
              m.role, m.status AS my_status, m.left_at,
              (SELECT count(*)::int FROM sary.outing_members x
                WHERE x.outing_id = o.id AND x.status = 'active') AS member_count
       FROM sary.outing_members m JOIN sary.outings o ON o.id = m.outing_id
       WHERE m.user_id = $1
       ORDER BY COALESCE(o.ended_at, o.started_at, o.created_at) DESC
       LIMIT 100`,
      [user.id],
    );
    const current = rows.filter((r) => r.my_status === 'active' && r.status !== 'ended');
    const history = rows.filter((r) => !(r.my_status === 'active' && r.status !== 'ended'));
    return { current, history };
  }

  const TRANSITIONS = {
    start: { from: ['created'], to: 'active' },
    pause: { from: ['active'], to: 'paused' },
    resume: { from: ['paused'], to: 'active' },
    end: { from: ['created', 'active', 'paused'], to: 'ended' },
  };

  async function endOutingRows(run, outingId) {
    await run(`DELETE FROM sary.member_positions WHERE outing_id = $1`, [outingId]);
    await run(
      `UPDATE sary.outing_invites SET revoked_at = now() WHERE outing_id = $1 AND revoked_at IS NULL`,
      [outingId],
    );
  }

  async function setStatus(user, outingId, action) {
    const t = TRANSITIONS[action];
    if (!t) throw err('invalid_action');
    const m = await requireOwner(user, outingId);
    if (!t.from.includes(m.outing_status)) throw err('invalid_transition', 409);
    const [o] = await tx(async (run) => {
      const rows = await run(
        `UPDATE sary.outings SET status = $2, updated_at = now(),
                started_at = CASE WHEN $2 = 'active' AND started_at IS NULL THEN now() ELSE started_at END,
                ended_at = CASE WHEN $2 = 'ended' THEN now() ELSE ended_at END
         WHERE id = $1 AND status = ANY($3::text[])
         RETURNING id, name, status, started_at, ended_at`,
        [outingId, t.to, t.from],
      );
      if (!rows.length) throw err('invalid_transition', 409);
      if (t.to === 'paused') await run(`DELETE FROM sary.member_positions WHERE outing_id = $1`, [outingId]);
      if (t.to === 'ended') await endOutingRows(run, outingId);
      return rows;
    });
    forgetOuting(outingId);
    if (t.to !== 'active') dropLatest(outingId);
    hub.emit(outingId, { type: 'outing_status', status: o.status, started_at: o.started_at, ended_at: o.ended_at });
    if (t.to === 'ended') hub.closeRoom(outingId, 'outing_ended');
    return o;
  }

  async function removeMember(user, outingId, memberId) {
    await requireOwner(user, outingId);
    if (!v.isUuid(memberId)) throw err('not_a_member', 404);
    if (memberId === user.id) throw err('cannot_remove_self');
    const rows = await tx(async (run) => {
      const r = await run(
        `UPDATE sary.outing_members SET status = 'removed', left_at = now(), sharing = false
         WHERE outing_id = $1 AND user_id = $2 AND status = 'active' RETURNING user_id`,
        [outingId, memberId],
      );
      await run(`DELETE FROM sary.member_positions WHERE outing_id = $1 AND user_id = $2`, [outingId, memberId]);
      return r;
    });
    if (!rows.length) throw err('not_a_member', 404);
    forgetOuting(outingId);
    dropLatest(outingId, memberId);
    hub.kick(outingId, memberId, 'removed');
    hub.emit(outingId, { type: 'member_left', user_id: memberId, reason: 'removed' });
    return { removed: memberId };
  }

  /**
   * Leaving stops sharing at once. If the owner leaves, the earliest remaining
   * member takes over; if nobody remains, the outing ends.
   */
  async function leave(user, outingId) {
    const m = await requireMember(user, outingId, { fresh: true });
    const outcome = await tx(async (run) => {
      await run(
        `UPDATE sary.outing_members SET status = 'left', left_at = now(), sharing = false
         WHERE outing_id = $1 AND user_id = $2`,
        [outingId, user.id],
      );
      await run(`DELETE FROM sary.member_positions WHERE outing_id = $1 AND user_id = $2`, [outingId, user.id]);
      if (m.role !== 'owner') return { ended: false, owner: null };
      await run(`UPDATE sary.outing_members SET role = 'member' WHERE outing_id = $1 AND user_id = $2`, [outingId, user.id]);
      const [next] = await run(
        `SELECT user_id FROM sary.outing_members WHERE outing_id = $1 AND status = 'active'
         ORDER BY joined_at LIMIT 1 FOR UPDATE`,
        [outingId],
      );
      if (!next || m.outing_status === 'ended') {
        if (m.outing_status !== 'ended') {
          await run(`UPDATE sary.outings SET status = 'ended', ended_at = now(), updated_at = now() WHERE id = $1`, [outingId]);
          await endOutingRows(run, outingId);
        }
        return { ended: true, owner: null };
      }
      await run(`UPDATE sary.outing_members SET role = 'owner' WHERE outing_id = $1 AND user_id = $2`, [outingId, next.user_id]);
      await run(`UPDATE sary.outings SET owner_id = $2, updated_at = now() WHERE id = $1`, [outingId, next.user_id]);
      return { ended: false, owner: next.user_id };
    });
    forgetOuting(outingId);
    dropLatest(outingId, user.id);
    hub.kick(outingId, user.id, 'left');
    hub.emit(outingId, { type: 'member_left', user_id: user.id, reason: 'left' });
    if (outcome.owner) hub.emit(outingId, { type: 'owner_changed', owner_id: outcome.owner });
    if (outcome.ended) {
      dropLatest(outingId);
      hub.emit(outingId, { type: 'outing_status', status: 'ended' });
      hub.closeRoom(outingId, 'outing_ended');
    }
    return outcome;
  }

  /* ---------- car notes ---------- */

  /* A note is a passing word to the group, not a record: held in memory only,
   * gone after NOTE_TTL_MS, when replaced, or when the server restarts. */
  const NOTE_TTL_MS = 15 * 60_000;
  const NOTE_MIN_GAP_MS = 2_000;
  const notes = new Map(); // `${outingId}:${userId}` → { text, at }

  function noteOf(outingId, userId) {
    const n = notes.get(`${outingId}:${userId}`);
    if (!n) return null;
    if (now() - n.at > NOTE_TTL_MS) {
      notes.delete(`${outingId}:${userId}`);
      return null;
    }
    return { text: n.text, at: new Date(n.at).toISOString() };
  }

  async function setNote(user, outingId, raw) {
    const m = await requireMember(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const text = v.note(raw);
    if (text === null) throw err('invalid_note', 400);
    const key = `${outingId}:${user.id}`;
    const prev = notes.get(key);
    if (prev && now() - prev.at < NOTE_MIN_GAP_MS) throw err('too_frequent', 429);
    const at = now();
    if (text) notes.set(key, { text, at });
    else notes.delete(key);
    const payload = text ? { text, at: new Date(at).toISOString() } : null;
    /* Everyone, the sender's other devices included. */
    hub.emit(outingId, { type: 'member_note', user_id: user.id, note: payload });
    return { note: payload };
  }

  async function setSharing(user, outingId, sharing) {
    await requireMember(user, outingId, { fresh: true });
    const on = sharing === true;
    await tx(async (run) => {
      await run(
        `UPDATE sary.outing_members SET sharing = $3 WHERE outing_id = $1 AND user_id = $2`,
        [outingId, user.id, on],
      );
      if (!on) await run(`DELETE FROM sary.member_positions WHERE outing_id = $1 AND user_id = $2`, [outingId, user.id]);
    });
    forgetOuting(outingId);
    if (!on) dropLatest(outingId, user.id);
    hub.emit(outingId, { type: 'member_sharing', user_id: user.id, sharing: on });
    return { sharing: on };
  }

  /**
   * One fix from a member. Returns { ok, position } and broadcasts it, or
   * { ok: false, reason } — refusals are normal (paused outing, stale fix) and
   * never throw for the hot path.
   */
  async function recordPosition(user, outingId, raw) {
    const m = await membership(outingId, user.id);
    if (!m || m.status !== 'active') return { ok: false, reason: 'not_a_member' };
    if (m.outing_status !== 'active') return { ok: false, reason: `outing_${m.outing_status}` };
    if (!m.sharing) return { ok: false, reason: 'sharing_off' };
    const t = now();
    const parsed = v.fix(raw, t);
    if (!parsed.ok) return { ok: false, reason: parsed.reason };
    const pos = { ...parsed.value, received_at: new Date(t) };
    if (!latest.has(outingId)) latest.set(outingId, new Map());
    const room = latest.get(outingId);
    const prev = room.get(user.id);
    if (prev) {
      if (pos.recorded_at <= new Date(prev.recorded_at)) return { ok: false, reason: 'out_of_order' };
      if (t - new Date(prev.received_at).getTime() < cfg.minFixIntervalMs) return { ok: false, reason: 'too_frequent' };
    }
    room.set(user.id, pos);
    const key = `${outingId}:${user.id}`;
    const persistedAt = lastPersist.get(key) || 0;
    if (!prev || t - persistedAt >= cfg.persistEveryMs) {
      lastPersist.set(key, t);
      const written = await q(
        `INSERT INTO sary.member_positions (outing_id, user_id, lat, lng, accuracy, heading, speed, recorded_at, received_at, mode)
         SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
         WHERE EXISTS (SELECT 1 FROM sary.outing_members m JOIN sary.outings o ON o.id = m.outing_id
                       WHERE m.outing_id = $1 AND m.user_id = $2 AND m.status = 'active' AND m.sharing AND o.status = 'active')
         ON CONFLICT (outing_id, user_id) DO UPDATE SET
           lat = EXCLUDED.lat, lng = EXCLUDED.lng, accuracy = EXCLUDED.accuracy, heading = EXCLUDED.heading,
           speed = EXCLUDED.speed, mode = EXCLUDED.mode, recorded_at = EXCLUDED.recorded_at, received_at = EXCLUDED.received_at
         WHERE sary.member_positions.recorded_at < EXCLUDED.recorded_at
         RETURNING user_id`,
        [outingId, user.id, pos.lat, pos.lng, pos.accuracy, pos.heading, pos.speed, pos.recorded_at, pos.received_at, pos.mode],
      );
      if (!written.length && !prev) {
        /* The DB disagrees with the cache (state changed elsewhere): refuse. */
        room.delete(user.id);
        forgetOuting(outingId);
        return { ok: false, reason: 'not_allowed' };
      }
      await q(`UPDATE sary.outings SET updated_at = now() WHERE id = $1 AND updated_at < now() - interval '5 minutes'`, [outingId]);
    }
    const position = shapePosition(user.id, pos);
    hub.emit(outingId, { type: 'position', position });
    return { ok: true, position };
  }

  /** Housekeeping: forget old fixes, end abandoned outings, drop dead invites. */
  /* ---------- field-test diagnostics (opt-in, numbers only) ---------- */

  async function recordDiagnostics(user, outingId, raw) {
    /* Membership gates who may write; the row itself keeps no user and no outing id. */
    await requireMember(user, outingId);
    const r = sanitizeDiagnostics(raw);
    if (!r.ok) throw err(r.error, 400);
    await q(
      `INSERT INTO sary.field_diagnostics (outing_ref, platform, browser, report) VALUES ($1, $2, $3, $4)`,
      [outingRef(outingId), r.report.app.platform, r.report.app.browser, JSON.stringify(r.report)],
    );
    return { ok: true };
  }

  async function sweep() {
    const retention = Math.round(cfg.positionRetentionHours * 3600);
    await q(`DELETE FROM sary.member_positions WHERE received_at < now() - make_interval(secs => $1)`, [retention]);
    const ended = await q(
      `UPDATE sary.outings SET status = 'ended', ended_at = now(), updated_at = now()
       WHERE status <> 'ended' AND updated_at < now() - make_interval(secs => $1)
       RETURNING id`,
      [Math.round(cfg.idleEndHours * 3600)],
    );
    for (const { id } of ended) {
      await q(`DELETE FROM sary.member_positions WHERE outing_id = $1`, [id]);
      await q(`UPDATE sary.outing_invites SET revoked_at = now() WHERE outing_id = $1 AND revoked_at IS NULL`, [id]);
      forgetOuting(id);
      dropLatest(id);
      hub.emit(id, { type: 'outing_status', status: 'ended' });
      hub.closeRoom(id, 'outing_ended');
    }
    await q(`DELETE FROM sary.outing_invites WHERE expires_at < now() - interval '7 days'`);
    await q(`DELETE FROM sary.field_diagnostics WHERE received_at < now() - interval '180 days'`).catch(() => undefined);
    const cutoff = now() - retention * 1000;
    for (const [oid, room] of latest) {
      for (const [uid, p] of room) if (new Date(p.received_at).getTime() < cutoff) room.delete(uid);
      if (!room.size) latest.delete(oid);
    }
    for (const [k, at] of lastPersist) if (at < cutoff) lastPersist.delete(k);
    return { ended: ended.length };
  }

  return {
    config: cfg,
    setEvents(next) {
      hub = next || noopEvents();
    },
    createUser,
    authenticate,
    updateProfile,
    membership,
    requireMember,
    createOuting,
    rotateInvite,
    revokeInvites,
    previewInvite,
    joinByInvite,
    getOuting,
    listOutings,
    setStatus,
    removeMember,
    leave,
    setSharing,
    setNote,
    recordPosition,
    recordDiagnostics,
    sweep,
  };
}

module.exports = { createOutingsService, OutingError };
