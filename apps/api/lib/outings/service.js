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
const { createRateLimiter } = require('./rate-limit');
const { pushPayloadFor } = require('./push');
const clipsLib = require('./clips');
const { createFeatures } = require('./features');
const { createSilenceWatch } = require('./silence');
const { createMedia } = require('./media');
const { createPersonalInvites } = require('./invites');
const { createChat } = require('./chat');

class OutingError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

const err = (code, status) => new OutingError(code, status);

/* Leaving / removed: off every «تردد خاص» of that trip (migration 013). */
const PTT_CHANNEL_MEMBER_DELETE = `DELETE FROM sary.ptt_channel_members cm USING sary.ptt_channels c
  WHERE c.id = cm.channel_id AND c.outing_id = $1 AND cm.user_id = $2`;

/**
 * May this membership lead the outing — start/pause/resume it, manage the
 * invite link, set rally points? The owner always; a «مساعد» (co-leader) too.
 * Pure, so other modules can reuse it on a `membership()` row.
 */
function canLead(m) {
  return Boolean(m && m.status === 'active' && (m.role === 'owner' || m.co_leader === true));
}

/* Compared against when no row matches, so a miss costs the same as a wrong code. */
const NO_DIGEST = Buffer.alloc(32);

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
    /* «المحادثات»: messages of an ended trip are deleted this many days after it ended. */
    chatRetentionDays: envNumber('OUTING_CHAT_RETENTION_DAYS', 30, { min: 1, max: 90 }),
    membershipCacheMs: 15_000,
    authCacheMs: 60_000,
  };
}

function noopEvents() {
  return { emit() {}, kick() {}, closeRoom() {}, onlineUsers: () => new Set(), awayUsers: () => new Set(), linkState: () => new Map() };
}

function noopPush() {
  return { enabled: false, notifyMembers: async () => ({ sent: 0, removed: 0, failed: 0, skipped: 0 }), notifyWatchers: async () => ({ sent: 0, removed: 0, failed: 0, skipped: 0 }) };
}

function createOutingsService({ pool, events = noopEvents(), push = noopPush(), webPush = null, config = {}, now = () => Date.now() } = {}) {
  if (!pool) throw new Error('outings service needs a pool');
  const cfg = { ...defaultConfig(), ...config };
  const authCache = new Map(); // digest hex -> { user, at }
  const memberCache = new Map(); // outingId -> Map(userId -> { row, at })
  /* Freshest fix per member, ahead of the throttled DB write. outingId -> Map(userId -> pos) */
  const latest = new Map();
  const lastPersist = new Map(); // `${o}:${u}` -> ms
  /* Voice clips: memory only, 10 minutes. See clips.js. */
  const clips = clipsLib.createClipStore({ now });
  let hub = events;
  /* «ترددات»: the walkie-talkie's private channels (lib/outings/ptt-channels.js), told when a
   * member leaves or the trip ends so its in-memory copy matches the rows deleted here. */
  let pttChannels = null;

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

  /* Return timer, «غرّزت», waypoints, convoy, plan + checklist — see features.js. */
  const features = createFeatures({
    q, tx, now, err, cfg, push, webPush, canLead,
    events: () => hub,
    requireMember: (...a) => requireMember(...a),
    requireLeader: (...a) => requireLeader(...a),
    membership: (...a) => membership(...a),
    positions: (...a) => positions(...a),
  });

  /* «انقطع الإرسال»: sharing on, no fix for 10 / 30 min → one alert each. See silence.js. */
  const silence = createSilenceWatch({
    q,
    now,
    events: () => hub,
    latest: (outingId) => latest.get(outingId),
    notify: (outingId, userId, info) => features.pushFeature('member_silent', outingId, userId, { ...info, userId }),
  });

  /* «قناة الطلعة»: shared YouTube channel state, memory only — see media.js. */
  const media = createMedia({
    q, now, err, canLead,
    events: () => hub,
    requireMember: (...a) => requireMember(...a),
  });

  /* «دعوة شخصية»: one link per person, single use — see invites.js. */
  const personal = createPersonalInvites({
    q, tx, now, err, cfg,
    events: () => hub,
    requireLeader: (...a) => requireLeader(...a),
    forgetOuting: (...a) => forgetOuting(...a),
  });

  /* «المحادثات»: group + direct trip chat, stored, 30-day retention — see chat.js. */
  const chat = createChat({ q, tx, now, err, cfg, push, canLead, events: () => hub });

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
      `SELECT m.outing_id, m.invited_name FROM sary.outing_members m JOIN sary.outings o ON o.id = m.outing_id
       WHERE m.user_id = $1 AND m.status = 'active' AND o.status <> 'ended'`,
      [user.id],
    );
    /* In a trip they joined through a personal invite, the inviter's name for
     * them stays the display name; their own name travels as the nickname. */
    for (const r of rooms) {
      hub.emit(r.outing_id, {
        type: 'member_updated',
        member: { user_id: next.id, ...memberNames(r.invited_name, next.display_name), avatar: next.avatar, phone: next.phone },
      });
    }
    return next;
  }

  /**
   * How a member is named inside one trip. Personal invite → the inviter's
   * name for them («فهد أخوي») is `display_name` everywhere (old clients show
   * just that); the person's own name is `nickname`, shown secondarily.
   */
  function memberNames(invitedName, ownName) {
    if (!invitedName) return { display_name: ownName, nickname: null, invited: false };
    return { display_name: invitedName, nickname: ownName && ownName !== invitedName ? ownName : null, invited: true };
  }

  /* ---------- recovery ---------- */

  function forgetUser(userId) {
    for (const [k, hit] of authCache) if (hit.user.id === userId) authCache.delete(k);
  }

  async function recoveryStatus(user) {
    const [row] = await q(`SELECT recovery_created_at FROM sary.users WHERE id = $1`, [user.id]);
    return { active: Boolean(row?.recovery_created_at), created_at: row?.recovery_created_at || null };
  }

  /**
   * A new recovery code for this person, replacing any earlier one. Returned
   * once, here; the server keeps only the selector and a digest of the rest.
   */
  async function createRecoveryCode(user) {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const code = v.newRecoveryCode();
      const { selector, verifier } = v.recoveryCode(code);
      try {
        const [row] = await q(
          `UPDATE sary.users SET recovery_selector = $2, recovery_hash = $3, recovery_created_at = now()
           WHERE id = $1 RETURNING recovery_created_at`,
          [user.id, selector, v.digest(verifier)],
        );
        if (!row) throw err('unauthorized', 401);
        return { code, created_at: row.recovery_created_at };
      } catch (e) {
        if (e.code !== '23505') throw e; // selector collision: draw again
      }
    }
    throw err('server_busy', 503);
  }

  /**
   * A recovery code from a new device → a fresh device token for that person.
   * The old token stops working at once (and its live sockets are dropped),
   * and the code is consumed: the person saves a new one afterwards.
   */
  async function recover(rawCode) {
    const parsed = v.recoveryCode(rawCode);
    if (!parsed) throw err('recovery_invalid', 400);
    const token = v.newSecret();
    const row = await tx(async (run) => {
      const [hit] = await run(
        `SELECT id, recovery_hash FROM sary.users WHERE recovery_selector = $1 FOR UPDATE`,
        [parsed.selector],
      );
      const ok = v.sameDigest(v.digest(parsed.verifier), hit?.recovery_hash || NO_DIGEST);
      if (!hit || !ok) return null;
      const [u] = await run(
        `UPDATE sary.users
         SET token_hash = $2, recovery_selector = NULL, recovery_hash = NULL, recovery_created_at = NULL, last_seen_at = now()
         WHERE id = $1
         RETURNING id, display_name, avatar, phone`,
        [hit.id, v.digest(token)],
      );
      return u;
    });
    if (!row) throw err('recovery_invalid', 400);
    forgetUser(row.id);
    hub.dropUser?.(row.id, 'unauthorized');
    return { user: publicUser(row), token };
  }

  /* ---------- membership ---------- */

  async function membership(outingId, userId, { fresh = false } = {}) {
    if (!v.isUuid(outingId)) return null;
    const room = memberCache.get(outingId);
    const hit = room?.get(userId);
    if (!fresh && hit && now() - hit.at < cfg.membershipCacheMs) return hit.row;
    const [row] = await q(
      `SELECT o.id AS outing_id, o.status AS outing_status, o.owner_id, o.join_locked, o.open_links,
              m.role, m.status, m.sharing, m.co_leader, m.invited_name
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

  /** The owner or a co-leader — see canLead. Always reads fresh. */
  async function requireLeader(user, outingId) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (!canLead(m)) throw err('leader_only', 403);
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

  /**
   * `invites: 'personal'` (new clients): no open group link at all — the
   * leader invites people one by one (invites.js) and `invite` is null.
   * Anything else (build 9–11): today's behaviour, an open link is made.
   */
  async function createOuting(user, { name, ttl_hours, invites } = {}) {
    const clean = v.outingName(name);
    if (!clean) throw err('invalid_outing_name');
    const personalOnly = invites === 'personal';
    return tx(async (run) => {
      const [o] = await run(
        `INSERT INTO sary.outings (name, owner_id, open_links) VALUES ($1, $2, $3) RETURNING id`,
        [clean, user.id, !personalOnly],
      );
      await run(
        `INSERT INTO sary.outing_members (outing_id, user_id, role) VALUES ($1, $2, 'owner')`,
        [o.id, user.id],
      );
      const invite = personalOnly ? null : await createInviteRow(run, o.id, user.id, ttl_hours);
      return { outing_id: o.id, invite, open_links: !personalOnly };
    });
  }

  /** A new open group link (build 9–11 «رابط جديد»). Personal invites are untouched. */
  async function rotateInvite(user, outingId, { ttl_hours } = {}) {
    const m = await requireLeader(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    if (m.open_links === false) throw err('open_links_disabled', 409);
    return tx(async (run) => {
      await run(
        `UPDATE sary.outing_invites SET revoked_at = now()
         WHERE outing_id = $1 AND kind = 'group' AND revoked_at IS NULL`,
        [outingId],
      );
      return createInviteRow(run, outingId, user.id, ttl_hours);
    });
  }

  async function revokeInvites(user, outingId) {
    await requireLeader(user, outingId);
    const rows = await q(
      `UPDATE sary.outing_invites SET revoked_at = now()
       WHERE outing_id = $1 AND kind = 'group' AND revoked_at IS NULL RETURNING id`,
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
    /* The leader switched the open link off: only personal invites admit people. */
    if (row.kind !== 'personal' && row.open_links === false) return 'open_links_disabled';
    return null;
  }

  /** The open group link's state, for leaders. Personal invites: `personal_invites`. */
  async function inviteState(outingId, openLinks = true) {
    const [inv] = await q(
      `SELECT expires_at FROM sary.outing_invites
       WHERE outing_id = $1 AND kind = 'group' AND revoked_at IS NULL AND expires_at > now()
       ORDER BY created_at DESC LIMIT 1`,
      [outingId],
    );
    return { active: Boolean(inv) && openLinks !== false, expires_at: inv?.expires_at || null, open_links: openLinks !== false };
  }

  /**
   * Who a personal invite is for, relative to the viewer:
   *   open      — not used yet: whoever joins becomes this person
   *   yours     — used by the viewer (rejoin is fine)
   *   taken     — used by someone else: «هذه الدعوة لشخص آخر»
   *   claimed   — used, and the viewer is anonymous (build 9–11 previews
   *               without a token): joining decides
   */
  function claimOf(row, viewer) {
    if (!row.consumed_at) return 'open';
    if (!viewer) return 'claimed';
    return row.consumed_by === viewer.id ? 'yours' : 'taken';
  }

  /** `viewer` is optional (the preview route authenticates when it can). */
  async function previewInvite(token, viewer = null) {
    if (!v.isSecretShaped(token)) throw err('invite_invalid', 404);
    const [row] = await q(
      `SELECT i.id, i.outing_id, i.expires_at, i.revoked_at, i.kind, i.invitee_name, i.consumed_by, i.consumed_at, i.opened_at,
              o.name, o.status AS outing_status, o.join_locked, o.open_links, u.display_name AS owner_name,
              (SELECT count(*)::int FROM sary.outing_members m
                WHERE m.outing_id = o.id AND m.status = 'active') AS member_count,
              (SELECT status FROM sary.outing_members m
                WHERE m.outing_id = o.id AND m.user_id = $2::uuid) AS viewer_status
       FROM sary.outing_invites i
       JOIN sary.outings o ON o.id = i.outing_id
       JOIN sary.users u ON u.id = o.owner_id
       WHERE i.token_hash = $1`,
      [v.digest(token), viewer?.id || null],
    );
    const problem = inviteProblem(row);
    if (problem) throw err(problem, problem === 'invite_invalid' ? 404 : 410);
    const isPersonal = row.kind === 'personal';
    /* «فتحها»: the first look by someone who is not already in the trip (the
     * leader checking their own link does not count). */
    if (isPersonal && !row.opened_at && !row.consumed_at && row.viewer_status !== 'active') {
      await q(`UPDATE sary.outing_invites SET opened_at = now() WHERE id = $1 AND opened_at IS NULL`, [row.id]);
    }
    return {
      outing_id: row.outing_id,
      name: row.name,
      status: row.outing_status,
      owner_name: row.owner_name,
      member_count: row.member_count,
      expires_at: row.expires_at,
      /* Shown so the invitee learns why joining will fail, before typing a name. */
      join_locked: row.join_locked === true,
      kind: isPersonal ? 'personal' : 'group',
      invitee_name: isPersonal ? row.invitee_name : null,
      claim: isPersonal ? claimOf(row, viewer) : 'open',
      already_member: row.viewer_status === 'active',
    };
  }

  async function joinByInvite(user, token) {
    if (!v.isSecretShaped(token)) throw err('invite_invalid', 404);
    const result = await tx(async (run) => {
      const [row] = await run(
        `SELECT i.id, i.outing_id, i.expires_at, i.revoked_at, i.kind, i.invitee_name, i.invitee_phone_last4,
                i.consumed_by, i.consumed_at, o.status AS outing_status, o.join_locked, o.open_links
         FROM sary.outing_invites i JOIN sary.outings o ON o.id = i.outing_id
         WHERE i.token_hash = $1
         FOR UPDATE OF i, o`,
        [v.digest(token)],
      );
      const isPersonal = row?.kind === 'personal';
      const [existing] = row
        ? await run(
            `SELECT status, invited_name FROM sary.outing_members WHERE outing_id = $1 AND user_id = $2`,
            [row.outing_id, user.id],
          )
        : [];
      /* A personal link used by someone else admits nobody else — checked
       * before expiry so the answer is the true reason. */
      if (isPersonal && row.consumed_at && row.consumed_by !== user.id) throw err('invite_taken', 409);
      /* The person it is bound to, already in the trip: nothing to do (even
       * if the link has since expired or been revoked). */
      if (isPersonal && existing?.status === 'active' && row.outing_status !== 'ended') {
        return { outing_id: row.outing_id, already: true };
      }
      const problem = inviteProblem(row);
      if (problem) throw err(problem, problem === 'invite_invalid' ? 404 : 410);
      if (existing?.status === 'active') return { outing_id: row.outing_id, already: true };
      if (existing?.status === 'removed') throw err('removed_from_outing', 403);
      if (row.join_locked) throw err('join_locked', 403);
      const [{ n }] = await run(
        `SELECT count(*)::int AS n FROM sary.outing_members WHERE outing_id = $1 AND status = 'active'`,
        [row.outing_id],
      );
      if (n >= cfg.maxMembers) throw err('outing_full', 409);
      /* Personal: the member is that person — the inviter's name for them. A
       * group link keeps whatever name an earlier personal invite gave them. */
      const invitedName = isPersonal ? row.invitee_name : existing?.invited_name || null;
      const last4 = isPersonal ? row.invitee_phone_last4 || null : null;
      if (existing) {
        await run(
          `UPDATE sary.outing_members SET status = 'active', sharing = true, co_leader = false, left_at = NULL, joined_at = now(),
                  invited_name = $3, invited_phone_last4 = COALESCE($4, invited_phone_last4), invite_id = COALESCE($5, invite_id)
           WHERE outing_id = $1 AND user_id = $2`,
          [row.outing_id, user.id, invitedName, last4, isPersonal ? row.id : null],
        );
      } else {
        await run(
          `INSERT INTO sary.outing_members (outing_id, user_id, invited_name, invited_phone_last4, invite_id)
           VALUES ($1, $2, $3, $4, $5)`,
          [row.outing_id, user.id, invitedName, last4, isPersonal ? row.id : null],
        );
      }
      if (isPersonal && !row.consumed_at) {
        await run(
          `UPDATE sary.outing_invites SET uses = uses + 1, consumed_by = $2, consumed_at = now() WHERE id = $1`,
          [row.id, user.id],
        );
      } else {
        await run(`UPDATE sary.outing_invites SET uses = uses + 1 WHERE id = $1`, [row.id]);
      }
      await run(`UPDATE sary.outings SET updated_at = now() WHERE id = $1`, [row.outing_id]);
      return { outing_id: row.outing_id, already: false, invitedName, last4, inviteId: isPersonal ? row.id : null };
    });
    forgetOuting(result.outing_id);
    const { invitedName, last4, inviteId, ...out } = result;
    if (!result.already) {
      hub.emit(result.outing_id, {
        type: 'member_joined',
        member: {
          user_id: user.id,
          ...memberNames(invitedName, user.display_name),
          phone_last4: last4,
          avatar: user.avatar,
          phone: user.phone || null,
          role: 'member',
          co_leader: false,
          sharing: true,
        },
      });
      if (inviteId) hub.emit(result.outing_id, { type: 'invite_used', invite_id: inviteId, user_id: user.id });
    }
    return out;
  }

  /* ---------- offline mesh key ---------- */

  /** First read of an outing without a key: make one (a concurrent reader gets the same). */
  async function ensureMeshKey(outingId) {
    await q(`UPDATE sary.outings SET mesh_key = $2 WHERE id = $1 AND mesh_key IS NULL`, [outingId, v.newSecret()]);
    const [r] = await q(`SELECT mesh_key FROM sary.outings WHERE id = $1`, [outingId]);
    return r?.mesh_key || null;
  }

  /** Someone left the group: a new key, so their copy no longer opens the mesh. */
  async function rotateMeshKeyRows(run, outingId) {
    await run(`UPDATE sary.outings SET mesh_key = $2 WHERE id = $1`, [outingId, v.newSecret()]);
  }

  async function members(outingId) {
    const rows = await q(
      `SELECT m.user_id, u.display_name, m.invited_name, m.invited_phone_last4, u.avatar, u.phone, m.role, m.co_leader, m.sharing, m.joined_at
       FROM sary.outing_members m JOIN sary.users u ON u.id = m.user_id
       WHERE m.outing_id = $1 AND m.status = 'active'
       ORDER BY m.role = 'owner' DESC, m.joined_at`,
      [outingId],
    );
    return rows.map(({ invited_name, invited_phone_last4, display_name, ...r }) => ({
      ...r,
      ...memberNames(invited_name, display_name),
      phone_last4: invited_phone_last4 || null,
    }));
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
      `SELECT id, name, status, owner_id, join_locked, open_links, created_at, started_at, ended_at,
              rally_lat, rally_lng, rally_label, rally_set_at, rally_set_by,
              convoy_lead_user_id, convoy_tail_user_id, convoy_max_gap_m, mesh_key
       FROM sary.outings WHERE id = $1`,
      [outingId],
    );
    const meshKey = o.mesh_key || (await ensureMeshKey(outingId));
    delete o.mesh_key;
    const { rally_lat, rally_lng, rally_label, rally_set_at, rally_set_by, convoy_lead_user_id, convoy_tail_user_id, convoy_max_gap_m, ...outing } = o;
    outing.rally = rallyOut({ rally_lat, rally_lng, rally_label, rally_set_at, rally_set_by });
    outing.convoy = features.convoyOut({ convoy_lead_user_id, convoy_tail_user_id, convoy_max_gap_m });
    const leads = canLead(m);
    const [mem, pos, inv] = await Promise.all([
      members(outingId),
      positions(outingId, outing.status),
      leads ? inviteState(outingId, m.open_links) : Promise.resolve(null),
    ]);
    const personalInvites = leads && outing.status !== 'ended' ? await personal.personalOf(outingId) : null;
    const chatUnread = await chat.unreadTotal(outingId, user.id).catch(() => 0);
    const online = hub.onlineUsers(outingId);
    const away = hub.awayUsers ? hub.awayUsers(outingId) : new Set();
    const link = hub.linkState ? hub.linkState(outingId) : new Map();
    return {
      outing,
      me: { user_id: user.id, role: m.role, co_leader: m.co_leader === true, can_lead: leads, sharing: m.sharing },
      members: mem.map((x) => ({
        ...x,
        online: online.has(x.user_id),
        away: away.has(x.user_id),
        last_seen_at: link.get(x.user_id)?.at ? new Date(link.get(x.user_id).at).toISOString() : null,
        gps: link.get(x.user_id)?.gps || null,
        note: outing.status === 'ended' ? null : noteOf(outingId, x.user_id),
        battery: hub.batteryOut ? hub.batteryOut(link.get(x.user_id)?.battery || null) : null,
        sos: outing.status === 'ended' ? null : sosOf(outingId, x.user_id),
      })),
      positions: pos,
      stuck: outing.status === 'ended' ? [] : features.stuckList(outingId),
      /* Members whose sharing went silent (≥10 min without a fix): never draw them as live. */
      silent: outing.status === 'active' ? silence.list(outingId) : [],
      media: outing.status === 'ended' ? null : media.mediaOf(outingId),
      voice_clips: outing.status === 'ended' ? [] : clips.list(outingId),
      summaries: outing.status === 'ended' ? await summariesOf([outingId]).then((r) => r.get(outingId) || []) : [],
      invite: inv,
      /* Leaders only: one line per person invited — «أُرسلت / فتحها / انضم / لم يفتحها». */
      personal_invites: personalInvites,
      /* «المحادثات»: unread messages for me in this trip (the Group-tab badge). */
      chat_unread: chatUnread,
      /* Offline car-to-car mesh secret: active members only (requireMember above). */
      mesh_key: meshKey,
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
    /* Shared summaries reach the people who were still in the outing at its end. */
    const withSummaries = history.filter((r) => r.status === 'ended' && r.my_status === 'active').map((r) => r.id);
    const sums = withSummaries.length ? await summariesOf(withSummaries) : new Map();
    for (const r of history) r.summaries = sums.get(r.id) || [];
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
    await run(`DELETE FROM sary.ptt_tokens WHERE outing_id = $1`, [outingId]);
    /* «تردد خاص» channels end with the trip (their member lists cascade). */
    await run(`DELETE FROM sary.ptt_channels WHERE outing_id = $1`, [outingId]);
    await run(
      `UPDATE sary.outings SET rally_lat = NULL, rally_lng = NULL, rally_label = NULL, rally_set_at = NULL, rally_set_by = NULL
       WHERE id = $1`,
      [outingId],
    );
    dropSos(outingId);
    /* «غرّزت» ends with the outing, like SOS. A return timer does NOT: people end outings in the desert. */
    features.dropStuck(outingId);
    media.dropMedia(outingId);
    await run(
      `UPDATE sary.outing_invites SET revoked_at = now() WHERE outing_id = $1 AND revoked_at IS NULL`,
      [outingId],
    );
  }

  async function setStatus(user, outingId, action) {
    const t = TRANSITIONS[action];
    if (!t) throw err('invalid_action');
    /* Ending is final and stays the owner's; a co-leader drives the rest. */
    const m = action === 'end' ? await requireOwner(user, outingId) : await requireLeader(user, outingId);
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
    if (t.to !== 'active') {
      dropLatest(outingId);
      silence.drop(outingId);
    }
    if (t.to === 'ended') clips.dropOuting(outingId);
    if (t.to === 'ended') pttChannels?.outingEnded(outingId);
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
        `UPDATE sary.outing_members SET status = 'removed', left_at = now(), sharing = false, co_leader = false
         WHERE outing_id = $1 AND user_id = $2 AND status = 'active' RETURNING user_id`,
        [outingId, memberId],
      );
      await run(`DELETE FROM sary.member_positions WHERE outing_id = $1 AND user_id = $2`, [outingId, memberId]);
      await run(PTT_CHANNEL_MEMBER_DELETE, [outingId, memberId]);
      if (r.length) await rotateMeshKeyRows(run, outingId);
      return r;
    });
    if (!rows.length) throw err('not_a_member', 404);
    forgetOuting(outingId);
    dropLatest(outingId, memberId);
    silence.drop(outingId, memberId, 'removed');
    dropSos(outingId, memberId);
    if (features.dropStuck(outingId, memberId)) hub.emit(outingId, { type: 'stuck_clear', user_id: memberId });
    clips.dropUser(outingId, memberId);
    void features.dropFromConvoy(outingId, memberId);
    void media.memberGone(outingId, memberId);
    pttChannels?.memberGone(outingId, memberId);
    hub.kick(outingId, memberId, 'removed');
    hub.emit(outingId, { type: 'member_left', user_id: memberId, reason: 'removed' });
    hub.emit(outingId, { type: 'mesh_key_rotated' });
    return { removed: memberId };
  }

  /**
   * Leaving stops sharing at once. If the owner leaves, the earliest remaining
   * member takes over; if nobody remains, the outing ends.
   */
  async function leaveRows(run, m, outingId, userId) {
    await run(
      `UPDATE sary.outing_members SET status = 'left', left_at = now(), sharing = false, co_leader = false
       WHERE outing_id = $1 AND user_id = $2`,
      [outingId, userId],
    );
    await run(`DELETE FROM sary.member_positions WHERE outing_id = $1 AND user_id = $2`, [outingId, userId]);
    /* Their phone is no longer in «قناة الطلعة»: no more Push to Talk wake-ups. */
    await run(`DELETE FROM sary.ptt_tokens WHERE outing_id = $1 AND user_id = $2`, [outingId, userId]);
    await run(PTT_CHANNEL_MEMBER_DELETE, [outingId, userId]);
    await rotateMeshKeyRows(run, outingId);
    if (m.role !== 'owner') return { ended: false, owner: null };
    await run(`UPDATE sary.outing_members SET role = 'member' WHERE outing_id = $1 AND user_id = $2`, [outingId, userId]);
    /* A co-leader is the natural heir; otherwise the earliest to join. */
    const [next] = await run(
      `SELECT user_id FROM sary.outing_members WHERE outing_id = $1 AND status = 'active'
       ORDER BY co_leader DESC, joined_at LIMIT 1 FOR UPDATE`,
      [outingId],
    );
    if (!next || m.outing_status === 'ended') {
      if (m.outing_status !== 'ended') {
        await run(`UPDATE sary.outings SET status = 'ended', ended_at = now(), updated_at = now() WHERE id = $1`, [outingId]);
        await endOutingRows(run, outingId);
      }
      return { ended: true, owner: null };
    }
    await run(`UPDATE sary.outing_members SET role = 'owner', co_leader = false WHERE outing_id = $1 AND user_id = $2`, [outingId, next.user_id]);
    await run(`UPDATE sary.outings SET owner_id = $2, updated_at = now() WHERE id = $1`, [outingId, next.user_id]);
    return { ended: false, owner: next.user_id };
  }

  /** After the leave transaction commits: caches, memory-only state, live events. */
  function afterLeave(outingId, userId, outcome) {
    forgetOuting(outingId);
    dropLatest(outingId, userId);
    silence.drop(outingId, userId, 'left');
    if (outcome.ended) silence.drop(outingId);
    dropSos(outingId, userId);
    if (features.dropStuck(outingId, userId)) hub.emit(outingId, { type: 'stuck_clear', user_id: userId });
    notes.delete(`${outingId}:${userId}`);
    clips.dropUser(outingId, userId);
    if (!outcome.ended) void features.dropFromConvoy(outingId, userId);
    if (outcome.ended) media.dropMedia(outingId);
    else void media.memberGone(outingId, userId);
    if (outcome.ended) pttChannels?.outingEnded(outingId);
    else pttChannels?.memberGone(outingId, userId);
    hub.kick(outingId, userId, 'left');
    hub.emit(outingId, { type: 'member_left', user_id: userId, reason: 'left' });
    hub.emit(outingId, { type: 'mesh_key_rotated' });
    if (outcome.owner) hub.emit(outingId, { type: 'owner_changed', owner_id: outcome.owner });
    if (outcome.ended) {
      dropLatest(outingId);
      clips.dropOuting(outingId);
      hub.emit(outingId, { type: 'outing_status', status: 'ended' });
      hub.closeRoom(outingId, 'outing_ended');
    }
  }

  async function leave(user, outingId) {
    const m = await requireMember(user, outingId, { fresh: true });
    const outcome = await tx((run) => leaveRows(run, m, outingId, user.id));
    afterLeave(outingId, user.id, outcome);
    return outcome;
  }

  /* ---------- account deletion («احذف حسابي») ---------- */

  /**
   * Deletes this identity and everything that is only theirs, in one
   * transaction. A HARD delete of the sary.users row:
   *   1. every open outing they are active in is left with the normal leave
   *      rules (owner hand-over, or the outing ends if nobody is left);
   *   2. outings they still own (already ended) pass to the earliest other
   *      member, or are deleted outright when nobody else was ever in them —
   *      sary.outings.owner_id is NOT NULL without ON DELETE, so this is what
   *      makes the row deletable without touching the schema;
   *   3. invite rows they created (created_by is NOT NULL without ON DELETE)
   *      are re-attributed to the outing's current owner, so a group's live
   *      link keeps working;
   *   4. DELETE the user: memberships, positions, trip summaries, web push
   *      subscriptions, APNs tokens, every chat message they sent, every direct
   *      chat message sent to them and their read markers go with it
   *      (ON DELETE CASCADE, migration 012), recovery
   *      code columns live on the row itself, rally_set_by is SET NULL.
   * Memory-only state (notes, SOS, voice clips they sent, latest fixes, auth
   * cache, sockets) is dropped after commit. The token is 401 from then on.
   */
  async function deleteAccount(user) {
    const result = await tx(async (run) => {
      const [me] = await run(`SELECT id FROM sary.users WHERE id = $1 FOR UPDATE`, [user.id]);
      if (!me) return null;
      const open = await run(
        `SELECT m.outing_id, m.role, m.status, o.status AS outing_status
         FROM sary.outing_members m JOIN sary.outings o ON o.id = m.outing_id
         WHERE m.user_id = $1 AND m.status = 'active' AND o.status <> 'ended'
         ORDER BY m.joined_at
         FOR UPDATE OF m, o`,
        [user.id],
      );
      const left = [];
      for (const m of open) left.push({ outingId: m.outing_id, outcome: await leaveRows(run, m, m.outing_id, user.id) });
      const owned = await run(`SELECT id FROM sary.outings WHERE owner_id = $1 FOR UPDATE`, [user.id]);
      const touched = new Set(left.map((l) => l.outingId));
      let deletedOutings = 0;
      for (const { id } of owned) {
        touched.add(id);
        const [heir] = await run(
          `SELECT user_id, status FROM sary.outing_members WHERE outing_id = $1 AND user_id <> $2
           ORDER BY status = 'active' DESC, co_leader DESC, joined_at LIMIT 1`,
          [id, user.id],
        );
        if (!heir) {
          await run(`DELETE FROM sary.outings WHERE id = $1`, [id]);
          deletedOutings += 1;
          continue;
        }
        if (heir.status === 'active') {
          await run(`UPDATE sary.outing_members SET role = 'owner', co_leader = false WHERE outing_id = $1 AND user_id = $2`, [id, heir.user_id]);
        }
        await run(`UPDATE sary.outings SET owner_id = $2 WHERE id = $1`, [id, heir.user_id]);
      }
      await run(
        `UPDATE sary.outing_invites i SET created_by = o.owner_id
         FROM sary.outings o WHERE o.id = i.outing_id AND i.created_by = $1`,
        [user.id],
      );
      const others = await run(`SELECT DISTINCT outing_id FROM sary.outing_members WHERE user_id = $1`, [user.id]);
      for (const r of others) touched.add(r.outing_id);
      /* Every outing they had a key for gets a new one (open ones already did, in leaveRows). */
      const leftIds = new Set(left.map((l) => l.outingId));
      for (const r of others) if (!leftIds.has(r.outing_id)) await rotateMeshKeyRows(run, r.outing_id);
      /* Waypoints, return timers (+ watch links), checklist authorship, snapshots. */
      const featureInfo = await features.accountRows(run, user.id);
      await run(`DELETE FROM sary.users WHERE id = $1`, [user.id]);
      return { left, touched: [...touched], deletedOutings, featureInfo };
    });
    if (!result) throw err('unauthorized', 401);
    forgetUser(user.id);
    for (const { outingId, outcome } of result.left) afterLeave(outingId, user.id, outcome);
    for (const oid of result.touched) {
      forgetOuting(oid);
      dropLatest(oid, user.id);
      silence.drop(oid, user.id);
      dropSos(oid, user.id);
      clips.dropUser(oid, user.id);
      lastPersist.delete(`${oid}:${user.id}`);
    }
    for (const k of [...notes.keys()]) if (k.endsWith(`:${user.id}`)) notes.delete(k);
    for (const k of [...sosAlerts.keys()]) if (k.endsWith(`:${user.id}`)) sosAlerts.delete(k);
    await features.afterAccountDeleted(result.featureInfo, user.id);
    for (const oid of result.touched) if (!result.left.some((l) => l.outingId === oid)) hub.emit(oid, { type: 'mesh_key_rotated' });
    hub.dropUser?.(user.id, 'unauthorized');
    return { left: result.left.length, deleted_outings: result.deletedOutings };
  }

  /* ---------- co-leaders & join lock ---------- */

  /** Owner only: make an active member a «مساعد», or take it back. */
  async function setCoLeader(user, outingId, memberId, on) {
    const m = await requireOwner(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    if (typeof on !== 'boolean') throw err('invalid_role');
    if (!v.isUuid(memberId)) throw err('not_a_member', 404);
    if (memberId === user.id) throw err('owner_is_leader');
    const rows = await q(
      `UPDATE sary.outing_members SET co_leader = $3
       WHERE outing_id = $1 AND user_id = $2 AND status = 'active' AND role = 'member'
       RETURNING user_id, co_leader`,
      [outingId, memberId, on],
    );
    if (!rows.length) throw err('not_a_member', 404);
    forgetOuting(outingId);
    hub.emit(outingId, { type: 'member_role', user_id: memberId, co_leader: on });
    return { user_id: memberId, co_leader: on };
  }

  /** Owner only: «قفل الانضمام» — invite links stop admitting anyone new. */
  async function setJoinLock(user, outingId, locked) {
    const m = await requireOwner(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    if (typeof locked !== 'boolean') throw err('invalid_lock');
    await q(`UPDATE sary.outings SET join_locked = $2, updated_at = now() WHERE id = $1`, [outingId, locked]);
    forgetOuting(outingId);
    hub.emit(outingId, { type: 'outing_lock', join_locked: locked });
    return { join_locked: locked };
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
    const event = { type: 'member_note', user_id: user.id, note: payload };
    hub.emit(outingId, event);
    /* …and a push to members whose screen is off. Best effort, never awaited. */
    if (payload) void announce(outingId, user.id, event);
    return { note: payload };
  }

  /* ---------- safety: SOS, rally point ---------- */

  /* An SOS is a call for help right now, not a record: in memory only, until
   * the sender cancels it («أنا بخير»), leaves, the outing ends, or SOS_TTL_MS
   * passes. It carries the sender's last real fix with that fix's own time, so
   * nobody mistakes an old position for a live one. */
  const SOS_TTL_MS = 60 * 60_000;
  const SOS_MIN_GAP_MS = 3_000;
  const sosAlerts = new Map(); // `${outingId}:${userId}` → { at, updated_at, fix }
  const sosLimit = createRateLimiter({ limit: 20, windowMs: 10 * 60_000, now });

  function sosOf(outingId, userId) {
    const key = `${outingId}:${userId}`;
    const a = sosAlerts.get(key);
    if (!a) return null;
    if (now() - a.updated_at > SOS_TTL_MS) {
      sosAlerts.delete(key);
      return null;
    }
    return { at: new Date(a.at).toISOString(), fix: a.fix };
  }

  function dropSos(outingId, userId) {
    if (userId) return sosAlerts.delete(`${outingId}:${userId}`);
    for (const k of [...sosAlerts.keys()]) if (k.startsWith(`${outingId}:`)) sosAlerts.delete(k);
  }

  /**
   * Raise (or refresh, with a newer fix) my SOS. `fix` is optional — a phone
   * with no GPS can still call for help — and is validated like any fix but
   * may be up to 30 min old. It goes out even with sharing off: pressing SOS
   * for a full second is the decision to be found.
   */
  async function raiseSos(user, outingId, rawFix) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    let fix = null;
    if (rawFix != null) {
      const t = now();
      const parsed = v.fix(rawFix, t, { maxAgeMs: v.SOS_FIX_MAX_AGE_MS });
      if (!parsed.ok) throw err(parsed.reason === 'stale' ? 'sos_fix_stale' : 'invalid_fix', 400);
      fix = { lat: parsed.value.lat, lng: parsed.value.lng, accuracy: parsed.value.accuracy, recorded_at: parsed.value.recorded_at.toISOString() };
    }
    const key = `${outingId}:${user.id}`;
    const prev = sosAlerts.get(key);
    if (prev && now() - prev.updated_at < SOS_MIN_GAP_MS) throw err('too_frequent', 429);
    if (!sosLimit(user.id)) throw err('rate_limited', 429);
    /* A refresh without a fix keeps the one we had; a fix never moves backwards in time. */
    const keep = prev?.fix && (!fix || new Date(prev.fix.recorded_at) > new Date(fix.recorded_at));
    const next = { at: prev && now() - prev.updated_at <= SOS_TTL_MS ? prev.at : now(), updated_at: now(), fix: keep ? prev.fix : fix };
    const refresh = Boolean(prev && now() - prev.updated_at <= SOS_TTL_MS);
    sosAlerts.set(key, next);
    const sos = sosOf(outingId, user.id);
    /* `{type:'sos', user_id}` is what index.js auto-pushes (high urgency, even to viewers);
     * a refresh with a newer fix is flagged so it updates maps without a second alarm. */
    hub.emit(outingId, { type: 'sos', user_id: user.id, sos, ...(refresh ? { refresh: true } : {}) });
    return { sos };
  }

  async function cancelSos(user, outingId) {
    await requireMember(user, outingId);
    const had = sosAlerts.delete(`${outingId}:${user.id}`);
    if (had) hub.emit(outingId, { type: 'sos', user_id: user.id, sos: null });
    return { sos: null };
  }

  function rallyOut(r) {
    if (r.rally_lat == null || r.rally_lng == null) return null;
    return {
      lat: r.rally_lat,
      lng: r.rally_lng,
      label: r.rally_label || null,
      set_at: r.rally_set_at ? new Date(r.rally_set_at).toISOString() : null,
      set_by: r.rally_set_by || null,
    };
  }

  /** Who may place the meeting pin: the owner or a «مساعد» (co-leader). */
  function requireRallyEditor(user, outingId) {
    return requireLeader(user, outingId);
  }

  /** A leader drops, moves (same call) or clears (raw === null) the meeting pin. */
  async function setRally(user, outingId, raw) {
    const m = await requireRallyEditor(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    let row;
    if (raw === null) {
      [row] = await q(
        `UPDATE sary.outings SET rally_lat = NULL, rally_lng = NULL, rally_label = NULL, rally_set_at = NULL, rally_set_by = NULL, updated_at = now()
         WHERE id = $1 AND status <> 'ended'
         RETURNING rally_lat, rally_lng, rally_label, rally_set_at, rally_set_by`,
        [outingId],
      );
    } else {
      const r = v.rally(raw);
      if (!r) throw err('invalid_rally', 400);
      [row] = await q(
        `UPDATE sary.outings SET rally_lat = $2, rally_lng = $3, rally_label = $4, rally_set_at = now(), rally_set_by = $5, updated_at = now()
         WHERE id = $1 AND status <> 'ended'
         RETURNING rally_lat, rally_lng, rally_label, rally_set_at, rally_set_by`,
        [outingId, r.lat, r.lng, r.label, user.id],
      );
    }
    if (!row) throw err('outing_ended', 409);
    const rally = rallyOut(row);
    hub.emit(outingId, { type: 'rally', rally });
    return { rally };
  }

  /* ---------- push ---------- */

  /** Push to every active member except the sender. Generic: any payload. */
  function notifyMembers(outingId, exceptUserId, payload) {
    return push.notifyMembers(outingId, exceptUserId, payload);
  }

  /** An outing event (member_note, sos, …) → a push, when that event type is pushed. */
  async function announce(outingId, senderId, event) {
    if (!push.enabled) return null;
    try {
      const [row] = await q(
        `SELECT o.name AS outing_name, COALESCE(m.invited_name, u.display_name) AS sender_name
         FROM sary.outings o LEFT JOIN sary.users u ON u.id = $2::uuid
         LEFT JOIN sary.outing_members m ON m.outing_id = o.id AND m.user_id = u.id
         WHERE o.id = $1`,
        [outingId, v.isUuid(senderId) ? senderId : null],
      );
      if (!row) return null;
      const payload = pushPayloadFor(event, { senderName: row.sender_name, outingName: row.outing_name });
      if (!payload) return null;
      return await notifyMembers(outingId, senderId || null, payload);
    } catch (e) {
      console.warn('[outings-push] announce', e.code || e.message);
      return null;
    }
  }

  /* ---------- voice clips ---------- */

  const CLIP_MIN_GAP_MS = 2_500;

  /**
   * A member's recorded clip → kept in memory for 10 minutes and announced to
   * everyone else in the room. Never to disk, never to a third party.
   */
  async function addClip(user, outingId, { buf, durationMs } = {}) {
    const m = await requireMember(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    if (!Buffer.isBuffer(buf) || buf.length < clipsLib.CLIP_MIN_BYTES) throw err('invalid_clip', 400);
    if (buf.length > clipsLib.CLIP_MAX_BYTES) throw err('too_large', 413);
    const mime = clipsLib.sniffAudio(buf);
    if (!mime) throw err('invalid_clip', 415);
    const ms = clipsLib.parseDurationMs(durationMs);
    if (ms === null) throw err('invalid_clip_duration', 400);
    if (now() - clips.lastAt(outingId, user.id) < CLIP_MIN_GAP_MS) throw err('too_frequent', 429);
    const clip = clips.put(outingId, user.id, { buf: Buffer.from(buf), mime, durationMs: ms });
    /* The sender already has it; everyone else hears about it. */
    const event = { type: 'voice_clip', clip };
    hub.emit(outingId, event, { exceptUser: user.id });
    /* A quiet push, like a note: only to members whose screen is off (viewers hear it in-app),
     * normal urgency, and it expires with the clip so nobody is woken for audio that is gone. */
    void announce(outingId, user.id, event);
    return clip;
  }

  async function getClip(user, outingId, clipId) {
    await requireMember(user, outingId);
    if (typeof clipId !== 'string' || !/^[0-9a-f]{32}$/.test(clipId)) throw err('clip_gone', 404);
    const hit = clips.get(outingId, clipId);
    if (!hit) throw err('clip_gone', 404);
    return hit;
  }

  /* ---------- opt-in trip summaries ---------- */

  const SUMMARY_WINDOW_MS = 7 * 24 * 3600_000;

  async function summariesOf(outingIds) {
    const rows = await q(
      `SELECT s.outing_id, s.user_id, COALESCE(m.invited_name, u.display_name) AS display_name, s.distance_m, s.duration_s, s.moving_s, s.shared_at
       FROM sary.trip_summaries s JOIN sary.users u ON u.id = s.user_id
       LEFT JOIN sary.outing_members m ON m.outing_id = s.outing_id AND m.user_id = s.user_id
       WHERE s.outing_id = ANY($1::uuid[])
       ORDER BY s.distance_m DESC`,
      [outingIds],
    );
    const out = new Map();
    for (const r of rows) {
      if (!out.has(r.outing_id)) out.set(r.outing_id, []);
      out.get(r.outing_id).push({ user_id: r.user_id, display_name: r.display_name, distance_m: r.distance_m, duration_s: r.duration_s, moving_s: r.moving_s, shared_at: r.shared_at });
    }
    return out;
  }

  /**
   * «شارك ملخصي»: the person's own totals, once the outing has ended. The
   * phone computed them from its own fixes; the server never sees a point.
   */
  async function shareSummary(user, outingId, raw) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status !== 'ended') throw err('outing_not_ended', 409);
    const [o] = await q(`SELECT started_at, ended_at FROM sary.outings WHERE id = $1`, [outingId]);
    if (!o.ended_at || now() - new Date(o.ended_at).getTime() > SUMMARY_WINDOW_MS) throw err('summary_window_closed', 410);
    const spanS = o.started_at ? Math.max(0, Math.round((new Date(o.ended_at) - new Date(o.started_at)) / 1000)) : 0;
    const parsed = v.tripSummary(raw, { spanS });
    if (!parsed.ok) throw err(parsed.reason, 400);
    const s = parsed.value;
    const [row] = await q(
      `INSERT INTO sary.trip_summaries (outing_id, user_id, distance_m, duration_s, moving_s)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (outing_id, user_id) DO UPDATE SET
         distance_m = EXCLUDED.distance_m, duration_s = EXCLUDED.duration_s,
         moving_s = EXCLUDED.moving_s, shared_at = now()
       RETURNING distance_m, duration_s, moving_s, shared_at`,
      [outingId, user.id, s.distance_m, s.duration_s, s.moving_s],
    );
    return { summary: { user_id: user.id, display_name: m.invited_name || user.display_name, ...row } };
  }

  async function withdrawSummary(user, outingId) {
    await requireMember(user, outingId, { fresh: true });
    const rows = await q(`DELETE FROM sary.trip_summaries WHERE outing_id = $1 AND user_id = $2 RETURNING user_id`, [outingId, user.id]);
    return { withdrawn: rows.length > 0 };
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
    if (!on) {
      dropLatest(outingId, user.id);
      silence.drop(outingId, user.id, 'sharing_off');
    }
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
    silence.onFix(outingId, user.id);
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

  /** «بطلع من التغطية»: I know I will lose signal — do not alarm the group about me. */
  async function goingOffline(user, outingId, raw = {}) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    return silence.goingOffline(outingId, user.id, raw?.minutes);
  }

  /** Every 60 s (index.js): members whose sharing went silent. */
  function sweepSilence() {
    return silence.sweep();
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
      await q(`UPDATE sary.outings SET rally_lat = NULL, rally_lng = NULL, rally_label = NULL, rally_set_at = NULL, rally_set_by = NULL WHERE id = $1`, [id]);
      await q(`DELETE FROM sary.ptt_channels WHERE outing_id = $1`, [id]);
      pttChannels?.outingEnded(id);
      forgetOuting(id);
      dropLatest(id);
      silence.drop(id);
      dropSos(id);
      features.dropStuck(id);
      media.dropMedia(id);
      clips.dropOuting(id);
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
    clips.sweep();
    /* Trip chat: ended more than 30 days ago → every message and read marker deleted. */
    await chat.purge().catch((e) => console.warn('[outings-chat] purge', e.code || e.message));
    await features.sweepFeatures();
    media.sweepMedia();
    return { ended: ended.length };
  }

  return {
    config: cfg,
    push,
    ...features.api,
    ...media.api,
    ...personal.api,
    ...chat.api,
    memberNames,
    setEvents(next) {
      hub = next || noopEvents();
    },
    setPttChannels(next) {
      pttChannels = next || null;
    },
    createUser,
    authenticate,
    updateProfile,
    recoveryStatus,
    createRecoveryCode,
    recover,
    membership,
    requireMember,
    requireLeader,
    canLead,
    setCoLeader,
    setJoinLock,
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
    deleteAccount,
    setSharing,
    setNote,
    raiseSos,
    cancelSos,
    setRally,
    notifyMembers,
    announce,
    addClip,
    getClip,
    shareSummary,
    withdrawSummary,
    recordPosition,
    recordDiagnostics,
    goingOffline,
    sweepSilence,
    sweep,
  };
}

module.exports = { createOutingsService, OutingError, canLead };
