'use strict';

/**
 * «ترددات» — the channels of one trip's walkie-talkie («قناة الطلعة»).
 *
 *   · five PUBLIC channels, ids '1'…'5' («تردد ١…٥»): every active member may
 *     listen and talk; no rows; a phone that does not know channels (builds
 *     9–12) is on '1';
 *   · PRIVATE channels («تردد خاص», id = uuid): opened by the trip leader
 *     («أمير الرحلة») for the members he picks. Only those members may join,
 *     listen, talk, be woken by a pushtotalk push, or even see that it exists.
 *
 * This module owns the private channels: their rows (sary.ptt_channels /
 * ptt_channel_members, migration 013) and an in-memory copy per trip that the
 * relay checks synchronously on every frame (`isAllowed`). Every write goes to
 * the database first, then to the copy, then the relay is told so it can kick
 * a removed member off the air at once and refresh everyone's channel list.
 *
 * Who may manage: the trip owner; a co-leader too only if DEPUTY_CAN_MANAGE.
 * A private channel is managed by its creator or by the owner — and only while
 * they are on its member list (a non-member never sees it).
 */

const v = require('./validate');

const PUBLIC_IDS = Object.freeze(['1', '2', '3', '4', '5']);
const DEFAULT_CHANNEL = '1';
const AR_DIGITS = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
/* «نائب الأمير» may open private channels too? Off: the owner asked for «أمير الرحلة». */
const DEPUTY_CAN_MANAGE = false;
const MAX_PRIVATE_PER_OUTING = 5;
const NAME_MAX = 40;

const arabicNumber = (n) => String(n).replace(/[0-9]/g, (d) => AR_DIGITS[Number(d)]);
const publicName = (id) => `تردد ${arabicNumber(id)}`;
const isPublicId = (id) => PUBLIC_IDS.includes(id);
/** A channel id from the wire, or null: '1'…'5' or a uuid. */
function channelId(raw) {
  const s = typeof raw === 'number' ? String(raw) : raw;
  if (typeof s !== 'string') return null;
  if (isPublicId(s)) return s;
  return v.isUuid(s) ? s.toLowerCase() : null;
}

function canManageOuting(m) {
  return Boolean(m && m.status === 'active' && (m.role === 'owner' || (DEPUTY_CAN_MANAGE && m.co_leader === true)));
}

function createPttChannels({ q, tx, err, requireMember, cfg = {}, push = null, log = console.warn } = {}) {
  /** outingId → Map(channelId → { id, name, created_by, created_at, members: Set }) */
  const cache = new Map();
  const loading = new Map();
  let relay = null;
  const maxMembers = cfg.maxMembers || 50;

  function setRelay(r) {
    relay = r;
  }

  async function load(outingId) {
    if (cache.has(outingId)) return cache.get(outingId);
    if (loading.has(outingId)) return loading.get(outingId);
    const p = (async () => {
      const rows = await q(
        `SELECT c.id, c.name, c.created_by, c.created_at,
                COALESCE(array_agg(cm.user_id) FILTER (WHERE cm.user_id IS NOT NULL), '{}') AS members
         FROM sary.ptt_channels c
         LEFT JOIN sary.ptt_channel_members cm ON cm.channel_id = c.id
         WHERE c.outing_id = $1 AND c.kind = 'private'
         GROUP BY c.id ORDER BY c.created_at`,
        [outingId],
      );
      const map = new Map();
      for (const r of rows) map.set(r.id, { id: r.id, name: r.name, created_by: r.created_by, created_at: r.created_at, members: new Set(r.members) });
      cache.set(outingId, map);
      return map;
    })().finally(() => loading.delete(outingId));
    loading.set(outingId, p);
    return p;
  }

  /** Is the copy for this trip in memory? (The relay fails closed until it is.) */
  const loaded = (outingId) => cache.has(outingId);

  /**
   * Synchronous, for the relay's hot path. Public: yes. Private: only a listed
   * member of a channel of THIS trip; unknown / not loaded → no (fail closed).
   */
  function isAllowed(outingId, id, userId) {
    if (isPublicId(id)) return true;
    const ch = cache.get(outingId)?.get(id);
    return Boolean(ch && userId && ch.members.has(userId));
  }

  function privateOf(outingId) {
    return [...(cache.get(outingId)?.values() || [])];
  }

  function nameOf(outingId, id) {
    if (isPublicId(id)) return publicName(id);
    return cache.get(outingId)?.get(id)?.name || null;
  }

  function mayManage(m, ch, userId) {
    return Boolean(ch && ch.members.has(userId) && m && m.status === 'active' && (ch.created_by === userId || canManageOuting(m)));
  }

  /**
   * The channel list as `userId` may see it: the five public ones, then the
   * private ones they are invited to. `live(id)` → { listeners: [userId], talker }.
   */
  function view(outingId, userId, m, live = () => ({ listeners: [], talker: null })) {
    const out = PUBLIC_IDS.map((id) => ({ id, kind: 'public', name: publicName(id), ...live(id) }));
    for (const ch of privateOf(outingId)) {
      if (!ch.members.has(userId)) continue;
      out.push({
        id: ch.id,
        kind: 'private',
        name: ch.name,
        created_by: ch.created_by,
        members: [...ch.members],
        can_manage: mayManage(m, ch, userId),
        ...live(ch.id),
      });
    }
    return out;
  }

  /* ---------- REST: GET / POST / PATCH / DELETE /api/outings/:id/ptt/channels ---------- */

  function liveOf(outingId) {
    return (id) => (relay ? relay.channelLive(outingId, id) : { listeners: [], talker: null });
  }

  async function list(user, outingId) {
    const m = await requireMember(user, outingId);
    await load(outingId);
    return {
      channels: view(outingId, user.id, m, liveOf(outingId)),
      current: relay ? relay.currentChannel(outingId, user.id) : DEFAULT_CHANNEL,
      can_create: canManageOuting(m) && m.outing_status !== 'ended',
      max_private: MAX_PRIVATE_PER_OUTING,
    };
  }

  function cleanName(raw) {
    const n = v.cleanText(raw, NAME_MAX);
    if (!n) throw err('invalid_name', 400);
    return n;
  }

  /** Every id must be an ACTIVE member of this trip right now. */
  async function activeMembers(outingId, raw) {
    if (raw === undefined || raw === null) return [];
    if (!Array.isArray(raw) || raw.length > maxMembers) throw err('invalid_members', 400);
    const ids = [...new Set(raw.map((x) => (typeof x === 'string' ? x.toLowerCase() : x)))];
    if (!ids.every((x) => v.isUuid(x))) throw err('invalid_members', 400);
    if (!ids.length) return [];
    const rows = await q(
      `SELECT user_id FROM sary.outing_members WHERE outing_id = $1 AND status = 'active' AND user_id = ANY($2::uuid[])`,
      [outingId, ids],
    );
    if (rows.length !== ids.length) throw err('invalid_members', 400);
    return ids;
  }

  async function namesFor(outingId, userId) {
    const [row] = await q(
      `SELECT o.name AS outing_name, COALESCE(m.invited_name, u.display_name) AS name
       FROM sary.outings o LEFT JOIN sary.users u ON u.id = $2::uuid
       LEFT JOIN sary.outing_members m ON m.outing_id = o.id AND m.user_id = u.id
       WHERE o.id = $1`,
      [outingId, userId],
    );
    return row || {};
  }

  /** «أمير الرحلة دعاك إلى تردد خاص: …» — live to their open sockets, and a push to the rest. */
  async function invite(outingId, ch, byUser, userIds) {
    const targets = userIds.filter((u) => u !== byUser.id);
    if (!targets.length) return;
    relay?.invited(outingId, ch.id, targets, { name: ch.name, by: byUser.id });
    if (!push?.enabled) return;
    const names = await namesFor(outingId, byUser.id).catch(() => ({}));
    const who = names.name ? `${names.name} (أمير الرحلة)` : 'أمير الرحلة';
    for (const u of targets) {
      void push
        .notifyMembers(outingId, byUser.id, {
          type: 'ptt_channel_invite',
          title: names.outing_name ? `تردد خاص · ${names.outing_name}` : 'تردد خاص',
          body: `${who} دعاك إلى تردد خاص: ${ch.name}`,
          tag: `sary-ptt-invite-${ch.id}`,
          ttl: 3600,
          to_user: u,
          channel_id: ch.id,
        })
        .catch((e) => log('[outings-ptt] invite push', e?.code || e?.message));
    }
  }

  async function create(user, outingId, body = {}) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (!canManageOuting(m)) throw err('leader_only', 403);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const name = cleanName(body.name);
    const invited = await activeMembers(outingId, body.members);
    const members = [...new Set([user.id, ...invited])];
    await load(outingId);
    const row = await tx(async (run) => {
      /* Serialise per trip so two quick taps cannot open a sixth channel. */
      await run(`SELECT id FROM sary.outings WHERE id = $1 FOR UPDATE`, [outingId]);
      const [{ n }] = await run(`SELECT count(*)::int AS n FROM sary.ptt_channels WHERE outing_id = $1 AND kind = 'private'`, [outingId]);
      if (n >= MAX_PRIVATE_PER_OUTING) throw err('too_many_channels', 409);
      const [c] = await run(
        `INSERT INTO sary.ptt_channels (outing_id, kind, name, created_by) VALUES ($1, 'private', $2, $3)
         RETURNING id, name, created_by, created_at`,
        [outingId, name, user.id],
      );
      await run(
        `INSERT INTO sary.ptt_channel_members (channel_id, user_id, added_by)
         SELECT $1, u, $2 FROM unnest($3::uuid[]) AS u ON CONFLICT DO NOTHING`,
        [c.id, user.id, members],
      );
      return c;
    });
    const ch = { id: row.id, name: row.name, created_by: row.created_by, created_at: row.created_at, members: new Set(members) };
    (cache.get(outingId) || cache.set(outingId, new Map()).get(outingId)).set(ch.id, ch);
    relay?.channelsChanged(outingId);
    await invite(outingId, ch, user, members);
    return { channel: view(outingId, user.id, m, liveOf(outingId)).find((c) => c.id === ch.id) };
  }

  async function requireManaged(user, outingId, rawId) {
    const id = channelId(rawId);
    const m = await requireMember(user, outingId, { fresh: true });
    if (!id || isPublicId(id)) throw err('channel_not_found', 404);
    await load(outingId);
    const ch = cache.get(outingId)?.get(id);
    /* Not invited: the same answer as "no such channel" — it must not leak that it exists. */
    if (!ch || !ch.members.has(user.id)) throw err('channel_not_found', 404);
    if (!mayManage(m, ch, user.id)) throw err('leader_only', 403);
    return { m, ch };
  }

  /** PATCH { name?, add?: [userId], remove?: [userId] } */
  async function update(user, outingId, rawId, body = {}) {
    const { m, ch } = await requireManaged(user, outingId, rawId);
    const name = body.name === undefined ? null : cleanName(body.name);
    const add = (await activeMembers(outingId, body.add)).filter((u) => !ch.members.has(u));
    const removeRaw = body.remove === undefined ? [] : body.remove;
    if (!Array.isArray(removeRaw) || removeRaw.length > maxMembers || !removeRaw.every((x) => v.isUuid(x))) throw err('invalid_members', 400);
    const remove = [...new Set(removeRaw.map((x) => x.toLowerCase()))].filter((u) => ch.members.has(u));
    if (remove.includes(user.id)) throw err('cannot_remove_self', 400);
    if (ch.members.size + add.length > maxMembers) throw err('invalid_members', 400);
    await tx(async (run) => {
      if (name) await run(`UPDATE sary.ptt_channels SET name = $2, updated_at = now() WHERE id = $1`, [ch.id, name]);
      if (add.length) {
        await run(
          `INSERT INTO sary.ptt_channel_members (channel_id, user_id, added_by)
           SELECT $1, u, $2 FROM unnest($3::uuid[]) AS u ON CONFLICT DO NOTHING`,
          [ch.id, user.id, add],
        );
      }
      if (remove.length) await run(`DELETE FROM sary.ptt_channel_members WHERE channel_id = $1 AND user_id = ANY($2::uuid[])`, [ch.id, remove]);
      if (name || add.length || remove.length) await run(`UPDATE sary.ptt_channels SET updated_at = now() WHERE id = $1`, [ch.id]);
    });
    if (name) ch.name = name;
    for (const u of add) ch.members.add(u);
    for (const u of remove) ch.members.delete(u);
    /* Off the air at once: their sockets leave the channel before anything else is relayed. */
    if (remove.length) relay?.kick(outingId, ch.id, new Set(remove), 'removed');
    relay?.channelsChanged(outingId);
    if (add.length) await invite(outingId, ch, user, add);
    return { channel: view(outingId, user.id, m, liveOf(outingId)).find((c) => c.id === ch.id) };
  }

  async function close(user, outingId, rawId) {
    const { ch } = await requireManaged(user, outingId, rawId);
    await q(`DELETE FROM sary.ptt_channels WHERE id = $1`, [ch.id]);
    cache.get(outingId)?.delete(ch.id);
    relay?.kick(outingId, ch.id, null, 'closed');
    relay?.channelsChanged(outingId);
    return { closed: ch.id };
  }

  /* ---------- hooks from the service (after the transaction committed) ---------- */

  /** Left / removed from the trip: no longer on any private channel of it. (Rows: service.leaveRows / removeMember.) */
  function memberGone(outingId, userId) {
    let changed = false;
    for (const ch of privateOf(outingId)) if (ch.members.delete(userId)) changed = true;
    if (changed) relay?.channelsChanged(outingId);
  }

  /** The trip ended (rows: service.endOutingRows). */
  function outingEnded(outingId) {
    cache.delete(outingId);
  }

  return {
    api: { listPttChannels: list, createPttChannel: create, updatePttChannel: update, closePttChannel: close },
    load,
    loaded,
    isAllowed,
    nameOf,
    view,
    memberGone,
    outingEnded,
    setRelay,
  };
}

module.exports = {
  createPttChannels,
  channelId,
  isPublicId,
  publicName,
  canManageOuting,
  PTT_PUBLIC_CHANNELS: PUBLIC_IDS,
  PTT_DEFAULT_CHANNEL: DEFAULT_CHANNEL,
  PTT_DEPUTY_CAN_MANAGE: DEPUTY_CAN_MANAGE,
  PTT_MAX_PRIVATE: MAX_PRIVATE_PER_OUTING,
};
