'use strict';

/**
 * «دعوة شخصية» — one link for one person the inviter knows.
 *
 * The leader picks someone from their contacts (or types a name + number). The
 * server mints a single-use token bound to that invitee: whoever opens it
 * first joins AS that person — shown in the trip under the name the leader
 * gave them — and the link then admits nobody else (the same person may come
 * back through it). Expiry, revoke and «أرسل من جديد» work per person.
 *
 * Privacy: the inviter's phone keeps the full number. The server keeps only a
 * per-trip salted digest (to notice a second invite to the same number) and the
 * last four digits (to tell two «فهد» apart). See migrations/011.
 *
 * The open group link (kind = 'group') still exists for build 9–11 clients
 * and trips made before this change; `outings.open_links` lets the leader turn
 * it off. See service.js previewInvite / joinByInvite for the join rules.
 */

const crypto = require('crypto');
const v = require('./validate');

const MAX_PERSONAL_PER_OUTING = 200;

/** Salted per trip: the same number gives a different digest in another trip. */
function phoneDigest(outingId, e164) {
  return crypto.createHash('sha256').update(`sary-invite-phone|${outingId}|${e164}`).digest('hex');
}

function last4(e164) {
  const d = String(e164 || '').replace(/\D/g, '');
  return d.length >= 4 ? d.slice(-4) : null;
}

/**
 * Where a personal invite stands, for the leader's list:
 *   sent     «أُرسلت»        — made, nobody opened it yet
 *   opened   «فتحها»         — previewed, not joined yet
 *   joined   «انضم»          — used (bound to that person)
 *   expired  «لم يفتحها» / «انتهت» — ran out unused (`opened` tells which)
 *   revoked  «أُلغيت»
 */
function inviteStatus(row, nowMs) {
  if (row.consumed_at) return 'joined';
  if (row.revoked_at) return 'revoked';
  if (new Date(row.expires_at).getTime() <= nowMs) return 'expired';
  if (row.opened_at) return 'opened';
  return 'sent';
}

function shapePersonal(row, nowMs) {
  return {
    id: row.id,
    kind: 'personal',
    invitee_name: row.invitee_name,
    phone_last4: row.invitee_phone_last4 || null,
    status: inviteStatus(row, nowMs),
    opened: Boolean(row.opened_at),
    created_at: row.created_at,
    expires_at: row.expires_at,
    opened_at: row.opened_at || null,
    consumed_at: row.consumed_at || null,
    revoked_at: row.revoked_at || null,
    member_user_id: row.consumed_by || null,
  };
}

const COLS = `id, outing_id, invitee_name, invitee_phone_last4, created_at, expires_at,
              opened_at, consumed_at, consumed_by, revoked_at, replaced_by`;

function createPersonalInvites(ctx) {
  const { q, tx, now, err, cfg, requireLeader, forgetOuting, events } = ctx;
  const hub = () => events();

  function ttlSeconds(ttlHours) {
    const hours = Math.min(24 * 14, Math.max(1, Number(ttlHours) || cfg.inviteTtlHours));
    return Math.round(hours * 3600);
  }

  async function insertPersonal(run, outingId, userId, { name, phone, ttl_hours }) {
    const token = v.newSecret();
    const [row] = await run(
      `INSERT INTO sary.outing_invites
         (outing_id, token_hash, created_by, expires_at, kind, invitee_name, invitee_phone_hash, invitee_phone_last4)
       VALUES ($1, $2, $3, now() + make_interval(secs => $4), 'personal', $5, $6, $7)
       RETURNING ${COLS}`,
      [outingId, v.digest(token), userId, ttlSeconds(ttl_hours), name, phone ? phoneDigest(outingId, phone) : null, phone ? last4(phone) : null],
    );
    return { row, token };
  }

  function cleanInvitee(raw = {}) {
    const name = v.displayName(raw.name ?? raw.invitee_name);
    if (!name) throw err('invalid_invitee_name');
    let phone = null;
    if (raw.phone !== undefined && raw.phone !== null && raw.phone !== '') {
      phone = v.phone(raw.phone);
      if (!phone) throw err('invalid_phone');
    }
    return { name, phone };
  }

  /**
   * A new personal invite. A still-open invite to the same number in this trip
   * is revoked first (a resend under a fresh token), so one person never holds
   * two live links. Returns the token once, here; only its digest is stored.
   */
  async function createPersonal(user, outingId, raw = {}) {
    const m = await requireLeader(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const { name, phone } = cleanInvitee(raw);
    const out = await tx(async (run) => {
      await run(`SELECT id FROM sary.outings WHERE id = $1 FOR UPDATE`, [outingId]);
      const [{ n }] = await run(
        `SELECT count(*)::int AS n FROM sary.outing_invites WHERE outing_id = $1 AND kind = 'personal'`,
        [outingId],
      );
      if (n >= MAX_PERSONAL_PER_OUTING) throw err('too_many_invites', 409);
      const made = await insertPersonal(run, outingId, user.id, { name, phone, ttl_hours: raw.ttl_hours });
      let replaced = null;
      if (phone) {
        /* Same number, still unused (sent, opened or expired): this one supersedes it. */
        const dups = await run(
          `UPDATE sary.outing_invites SET revoked_at = COALESCE(revoked_at, now()), replaced_by = $3
           WHERE outing_id = $1 AND kind = 'personal' AND invitee_phone_hash = $2
             AND consumed_at IS NULL AND replaced_by IS NULL AND id <> $3
           RETURNING id`,
          [outingId, phoneDigest(outingId, phone), made.row.id],
        );
        replaced = dups[0]?.id || null;
      }
      return { ...made, replaced };
    });
    return { invite: { ...shapePersonal(out.row, now()), token: out.token }, replaced: out.replaced };
  }

  async function listPersonal(user, outingId) {
    await requireLeader(user, outingId);
    return { invites: await personalOf(outingId) };
  }

  /** The leader's per-person list (also folded into getOuting for leaders). */
  async function personalOf(outingId) {
    const rows = await q(
      `SELECT ${COLS} FROM sary.outing_invites
       WHERE outing_id = $1 AND kind = 'personal' AND replaced_by IS NULL
       ORDER BY created_at DESC LIMIT ${MAX_PERSONAL_PER_OUTING}`,
      [outingId],
    );
    const t = now();
    return rows.map((r) => shapePersonal(r, t));
  }

  async function findPersonal(run, outingId, inviteId, { lock = false } = {}) {
    if (!v.isUuid(inviteId)) throw err('invite_not_found', 404);
    const [row] = await run(
      `SELECT ${COLS}, invitee_phone_hash FROM sary.outing_invites
       WHERE id = $1 AND outing_id = $2 AND kind = 'personal'${lock ? ' FOR UPDATE' : ''}`,
      [inviteId, outingId],
    );
    if (!row) throw err('invite_not_found', 404);
    return row;
  }

  /**
   * «أرسل من جديد»: the same invitee, a fresh token and expiry. The old link
   * stops working. Not for an invite that was already used — that person is in.
   */
  async function resendPersonal(user, outingId, inviteId, raw = {}) {
    const m = await requireLeader(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const out = await tx(async (run) => {
      const old = await findPersonal(run, outingId, inviteId, { lock: true });
      if (old.consumed_at) throw err('invite_used', 409);
      if (old.replaced_by) throw err('invite_replaced', 409);
      const token = v.newSecret();
      const [row] = await run(
        `INSERT INTO sary.outing_invites
           (outing_id, token_hash, created_by, expires_at, kind, invitee_name, invitee_phone_hash, invitee_phone_last4)
         VALUES ($1, $2, $3, now() + make_interval(secs => $4), 'personal', $5, $6, $7)
         RETURNING ${COLS}`,
        [outingId, v.digest(token), user.id, ttlSeconds(raw.ttl_hours), old.invitee_name, old.invitee_phone_hash, old.invitee_phone_last4],
      );
      await run(
        `UPDATE sary.outing_invites SET revoked_at = COALESCE(revoked_at, now()), replaced_by = $2 WHERE id = $1`,
        [old.id, row.id],
      );
      return { row, token, replaced: old.id };
    });
    return { invite: { ...shapePersonal(out.row, now()), token: out.token }, replaced: out.replaced };
  }

  /** «ألغِ الدعوة». A used invite stays used (the member stays — removing them is separate). */
  async function revokePersonal(user, outingId, inviteId) {
    await requireLeader(user, outingId);
    const row = await tx(async (run) => {
      const r = await findPersonal(run, outingId, inviteId, { lock: true });
      if (!r.revoked_at) await run(`UPDATE sary.outing_invites SET revoked_at = now() WHERE id = $1`, [r.id]);
      return { ...r, revoked_at: r.revoked_at || new Date(now()) };
    });
    return { invite: shapePersonal(row, now()) };
  }

  /**
   * «الرابط المفتوح»: may the trip's open group link admit people? Turning it
   * off also revokes the live group link; personal invites are untouched.
   */
  async function setOpenLinks(user, outingId, on) {
    const m = await requireLeader(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    if (typeof on !== 'boolean') throw err('invalid_open_links');
    await tx(async (run) => {
      await run(`UPDATE sary.outings SET open_links = $2, updated_at = now() WHERE id = $1`, [outingId, on]);
      if (!on) {
        await run(
          `UPDATE sary.outing_invites SET revoked_at = now()
           WHERE outing_id = $1 AND kind = 'group' AND revoked_at IS NULL`,
          [outingId],
        );
      }
    });
    forgetOuting(outingId);
    hub().emit(outingId, { type: 'outing_open_links', open_links: on });
    return { open_links: on };
  }

  return {
    personalOf,
    api: { createPersonal, listPersonal, resendPersonal, revokePersonal, setOpenLinks },
  };
}

module.exports = { createPersonalInvites, phoneDigest, last4, inviteStatus, shapePersonal, MAX_PERSONAL_PER_OUTING };
