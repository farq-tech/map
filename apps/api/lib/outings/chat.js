'use strict';

/**
 * «المحادثات» — trip chat. Per outing: one group conversation
 * («دردشة الطلعة», conv 'group') for every member, and 1:1 direct
 * conversations between any two members of that same trip.
 *
 * Every call checks membership on the server, fresh from Postgres:
 *
 *   read   — an active member reads everything; a member who LEFT reads what
 *            was written up to the moment they left (read-only); a REMOVED
 *            member reads nothing. After the trip ends, everyone who was in
 *            it at the end keeps reading it (read-only) until the retention
 *            sweep deletes it.
 *   write  — active member of an outing that has not ended; for a direct chat
 *            the other person must be an active member too. Removed members
 *            can never send.
 *   delete — your own message, always (soft: content wiped, marker kept);
 *            any group message for the leader or a «مساعد» («حذفها أمير الرحلة»).
 *
 * Retention: messages and read markers are DELETED `retentionDays` (30)
 * after the outing ended — see purge(), run by the service sweep. Account
 * deletion cascades (sender_id / recipient_id ON DELETE CASCADE).
 *
 * Ordering is the server's `seq` (one counter per outing). Clients send a
 * `client_id` with every message, so an offline outbox can retry safely.
 *
 * Wire (see ws.js): → chat_message / chat_read / chat_typing;
 *                   ← chat_ack · chat_message · chat_read · chat_typing · chat_deleted
 */

const v = require('./validate');
const { createRateLimiter } = require('./rate-limit');
const { chatPushPayload } = require('./push');

const TEXT_MAX = 1000;
const QUICK_MAX = 80;
const LABEL_MAX = 60;
const PAGE_DEFAULT = 50;
const PAGE_MAX = 100;
const RETENTION_DAYS = 30;
const TYPING_MIN_GAP_MS = 1_500;
/** The note presets («بوقف، انتظروني، وصلت…»), offered as quick replies. Any short line is accepted. */
const QUICK_PRESETS = ['بوقف', 'محطة بنزين', 'انتظروني', 'تعبت نرتاح', 'وصلت'];

/** Chat text: keeps line breaks (at most one blank line), drops control and bidi-override characters. */
function chatText(raw, max = TEXT_MAX) {
  if (typeof raw !== 'string') return null;
  const t = raw
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f‪-‮⁦-⁩]/g, '')
    .replace(/[^\S\n]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  if (!t) return null;
  if ([...t].length > max) return undefined; // too long: refused, never cut silently
  return t;
}

function clientId(raw) {
  return typeof raw === 'string' && /^[A-Za-z0-9_.:-]{1,64}$/.test(raw) ? raw : null;
}

/** Both participants, lower id first: the same key from either side. */
function directKey(a, b) {
  const [x, y] = [String(a).toLowerCase(), String(b).toLowerCase()].sort();
  return `${x}:${y}`;
}

/** The client's `with` ('group' | the other person's user id) → { conv, peer }. */
function parseWith(me, raw) {
  if (raw === 'group' || raw === undefined || raw === null || raw === '') return { conv: 'group', peer: null };
  if (!v.isUuid(raw)) return null;
  const peer = raw.toLowerCase();
  if (peer === String(me).toLowerCase()) return null;
  return { conv: directKey(me, peer), peer };
}

/** A send request → { kind, body, lat, lng, label } or { error }. */
function parseMessage(raw = {}) {
  const kind = raw.kind || 'text';
  if (kind === 'text') {
    const body = chatText(raw.text);
    if (body === undefined) return { error: 'text_too_long' };
    if (!body) return { error: 'invalid_message' };
    return { kind, body, lat: null, lng: null, label: null };
  }
  if (kind === 'quick') {
    const body = chatText(raw.text, QUICK_MAX);
    if (!body) return { error: 'invalid_message' };
    return { kind, body: body.replace(/\n/g, ' '), lat: null, lng: null, label: null };
  }
  if (kind === 'location') {
    const p = v.latLng(raw.point || raw);
    if (!p) return { error: 'invalid_point' };
    const label = raw.point?.label == null || raw.point?.label === '' ? null : chatText(String(raw.point.label), LABEL_MAX);
    if (label === undefined) return { error: 'invalid_point' };
    return { kind, body: null, lat: p.lat, lng: p.lng, label: label ? label.replace(/\n/g, ' ') : null };
  }
  return { error: 'invalid_kind' };
}

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function messageOut(r) {
  const deleted = Boolean(r.deleted_at);
  return {
    id: r.id,
    outing_id: r.outing_id,
    seq: Number(r.seq),
    conv: r.conv === 'group' ? 'group' : 'direct',
    sender_id: r.sender_id,
    recipient_id: r.recipient_id || null,
    sender_name: r.sender_name || null,
    client_id: r.client_id,
    kind: r.kind,
    text: deleted ? null : r.body || null,
    point: deleted || r.lat == null ? null : { lat: r.lat, lng: r.lng, label: r.label || null },
    created_at: iso(r.created_at),
    deleted,
    deleted_by: r.deleted_by_role || null,
  };
}

const MESSAGE_COLS = `c.id, c.outing_id, c.seq, c.conv, c.sender_id, c.recipient_id, c.client_id, c.kind, c.body,
  c.lat, c.lng, c.label, c.created_at, c.deleted_at, c.deleted_by_role,
  COALESCE(sm.invited_name, su.display_name) AS sender_name`;
const MESSAGE_JOINS = `JOIN sary.users su ON su.id = c.sender_id
  LEFT JOIN sary.outing_members sm ON sm.outing_id = c.outing_id AND sm.user_id = c.sender_id`;

function createChat(ctx) {
  const { q, tx, now, err, events, push, canLead, cfg = {} } = ctx;
  const hub = () => events();
  const retentionDays = cfg.chatRetentionDays ?? RETENTION_DAYS;
  const sendLimit = createRateLimiter({ limit: cfg.chatPerMinute ?? 30, windowMs: 60_000, now });
  const typingAt = new Map(); // `${outingId}:${userId}:${conv}` → ms

  /* ---------- who may do what ---------- */

  async function standing(outingId, userId) {
    if (!v.isUuid(outingId)) return null;
    const [row] = await q(
      `SELECT o.id AS outing_id, o.status AS outing_status, o.ended_at, o.name AS outing_name,
              m.status, m.role, m.co_leader, m.left_at, m.invited_name
       FROM sary.outings o
       LEFT JOIN sary.outing_members m ON m.outing_id = o.id AND m.user_id = $2
       WHERE o.id = $1`,
      [outingId, userId],
    );
    return row || null;
  }

  /**
   * The gate for one conversation. Returns { m, conv, peer, peerStatus, until, writable, why }.
   * Throws not_a_member (404) when the person may not even read it.
   */
  async function access(user, outingId, rawWith) {
    const m = await standing(outingId, user.id);
    if (!m || !m.status || m.status === 'removed') throw err('not_a_member', 404);
    const w = parseWith(user.id, rawWith);
    if (!w) throw err('invalid_conversation', 400);
    let peerStatus = null;
    if (w.peer) {
      const [p] = await q(`SELECT status FROM sary.outing_members WHERE outing_id = $1 AND user_id = $2`, [outingId, w.peer]);
      /* A direct chat exists only between two people of this same trip. */
      if (!p) throw err('not_a_member', 404);
      peerStatus = p.status;
    }
    /* Someone who left reads what was said while they were in it. */
    const until = m.status === 'left' ? m.left_at : null;
    let why = null;
    if (m.outing_status === 'ended') why = 'outing_ended';
    else if (m.status !== 'active') why = 'chat_read_only';
    else if (w.peer && peerStatus !== 'active') why = 'peer_not_active';
    return { m, conv: w.conv, peer: w.peer, peerStatus, until, writable: !why, why };
  }

  async function requireWritable(user, outingId, rawWith) {
    const a = await access(user, outingId, rawWith);
    if (!a.writable) throw err(a.why, 409);
    return a;
  }

  /* ---------- delivery ---------- */

  /** Group → everyone in the room. Direct → the two people only, every device of each. */
  function deliver(outingId, recipientId, senderId, event, { exceptUser } = {}) {
    const h = hub();
    if (!recipientId) return h.emit(outingId, event, exceptUser ? { exceptUser } : undefined);
    if (!h.connectionsOf || !h.send) return 0;
    const payload = JSON.stringify(event);
    let n = 0;
    for (const uid of new Set([senderId, recipientId])) {
      if (exceptUser && uid === exceptUser) continue;
      for (const c of h.connectionsOf(outingId, uid)) {
        h.send(c, payload);
        n += 1;
      }
    }
    return n;
  }

  async function pushMessage(message, a) {
    if (!push?.enabled) return null;
    try {
      const outingId = message.outing_id;
      const optedOut = await q(
        `SELECT m.user_id FROM sary.outing_members m JOIN sary.users u ON u.id = m.user_id
         WHERE m.outing_id = $1 AND m.status = 'active' AND u.chat_push = false`,
        [outingId],
      );
      const skip = optedOut.map((r) => r.user_id);
      if (message.recipient_id && skip.includes(message.recipient_id)) return null;
      const payload = chatPushPayload(message, { senderName: message.sender_name, outingName: a.m.outing_name });
      if (message.recipient_id) payload.to_user = message.recipient_id;
      else if (skip.length) payload.except_users = skip;
      return await push.notifyMembers(outingId, message.sender_id, payload);
    } catch (e) {
      console.warn('[outings-chat] push', e.code || e.message);
      return null;
    }
  }

  /* ---------- messages ---------- */

  async function byClientId(senderId, cid) {
    const [r] = await q(`SELECT ${MESSAGE_COLS} FROM sary.chat_messages c ${MESSAGE_JOINS} WHERE c.sender_id = $1 AND c.client_id = $2`, [senderId, cid]);
    return r || null;
  }

  /**
   * Send one message. Idempotent on (sender, client_id): a retry from the
   * offline outbox gets the same message back (`duplicate: true`), never a copy.
   */
  async function send(user, outingId, raw = {}) {
    const cid = clientId(raw.client_id);
    if (!cid) throw err('invalid_client_id', 400);
    const a = await access(user, outingId, raw.with);
    /* A retry of something already stored answers with it, even if the chat closed since. */
    const prior = await byClientId(user.id, cid);
    if (prior) {
      if (prior.outing_id !== outingId || prior.conv !== a.conv) throw err('invalid_client_id', 409);
      return { message: messageOut(prior), duplicate: true };
    }
    if (!a.writable) throw err(a.why, 409);
    const parsed = parseMessage(raw);
    if (parsed.error) throw err(parsed.error, 400);
    if (!sendLimit(`${outingId}:${user.id}`)) throw err('too_frequent', 429);
    let row;
    try {
      row = await tx(async (run) => {
        const [o] = await run(`UPDATE sary.outings SET chat_seq = chat_seq + 1 WHERE id = $1 AND status <> 'ended' RETURNING chat_seq`, [outingId]);
        if (!o) throw err('outing_ended', 409);
        const [ins] = await run(
          `INSERT INTO sary.chat_messages (outing_id, seq, conv, sender_id, recipient_id, client_id, kind, body, lat, lng, label)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id`,
          [outingId, o.chat_seq, a.conv, user.id, a.peer, cid, parsed.kind, parsed.body, parsed.lat, parsed.lng, parsed.label],
        );
        /* Your own message is read by you. */
        await run(
          `INSERT INTO sary.chat_reads (outing_id, user_id, conv, last_seq) VALUES ($1, $2, $3, $4)
           ON CONFLICT (outing_id, user_id, conv) DO UPDATE SET last_seq = GREATEST(sary.chat_reads.last_seq, EXCLUDED.last_seq), updated_at = now()`,
          [outingId, user.id, a.conv, o.chat_seq],
        );
        return ins;
      });
    } catch (e) {
      if (e.code !== '23505') throw e;
      /* Two retries raced: the first one won. */
      const won = await byClientId(user.id, cid);
      if (!won) throw e;
      return { message: messageOut(won), duplicate: true };
    }
    const [full] = await q(`SELECT ${MESSAGE_COLS} FROM sary.chat_messages c ${MESSAGE_JOINS} WHERE c.id = $1`, [row.id]);
    const message = messageOut(full);
    deliver(outingId, message.recipient_id, user.id, { type: 'chat_message', message });
    void pushMessage(message, a);
    return { message, duplicate: false };
  }

  /** Read markers of the others in this conversation: [{ user_id, seq }]. */
  async function readsOf(outingId, conv, meId) {
    const rows = await q(
      `SELECT user_id, last_seq FROM sary.chat_reads WHERE outing_id = $1 AND conv = $2 AND user_id <> $3`,
      [outingId, conv, meId],
    );
    return rows.map((r) => ({ user_id: r.user_id, seq: Number(r.last_seq) }));
  }

  function seqParam(raw) {
    if (raw === undefined || raw === null || raw === '') return null;
    const n = Number(raw);
    return Number.isSafeInteger(n) && n >= 0 ? n : undefined;
  }

  /**
   * One page of a conversation, oldest first.
   *   before=<seq> → the `limit` messages just older than it (scrolling up);
   *   after=<seq>  → the messages newer than it (catching up after a gap);
   *   neither      → the newest page.
   */
  async function list(user, outingId, rawWith, { before, after, limit } = {}) {
    const a = await access(user, outingId, rawWith);
    const b = seqParam(before);
    const af = seqParam(after);
    if (b === undefined || af === undefined) throw err('invalid_cursor', 400);
    const n = Math.min(PAGE_MAX, Math.max(1, Number.parseInt(limit, 10) || PAGE_DEFAULT));
    const params = [outingId, a.conv, a.until, n + 1];
    let where = `c.outing_id = $1 AND c.conv = $2 AND ($3::timestamptz IS NULL OR c.created_at <= $3)`;
    let order = 'DESC';
    if (af !== null) {
      params.push(af);
      where += ` AND c.seq > $${params.length}`;
      order = 'ASC';
    } else if (b !== null) {
      params.push(b);
      where += ` AND c.seq < $${params.length}`;
    }
    const rows = await q(`SELECT ${MESSAGE_COLS} FROM sary.chat_messages c ${MESSAGE_JOINS} WHERE ${where} ORDER BY c.seq ${order} LIMIT $4`, params);
    const hasMore = rows.length > n;
    const page = rows.slice(0, n);
    if (order === 'DESC') page.reverse();
    const [mine] = await q(`SELECT last_seq FROM sary.chat_reads WHERE outing_id = $1 AND user_id = $2 AND conv = $3`, [outingId, user.id, a.conv]);
    return {
      with: a.peer || 'group',
      messages: page.map(messageOut),
      has_more: hasMore,
      my_read_seq: Number(mine?.last_seq || 0),
      reads: await readsOf(outingId, a.conv, user.id),
      writable: a.writable,
      read_only_reason: a.why,
    };
  }

  /** «قرأت حتى seq». Never moves backwards. Tells the others (✓✓). */
  async function markRead(user, outingId, rawWith, rawSeq) {
    const a = await access(user, outingId, rawWith);
    const seq = seqParam(rawSeq);
    if (seq === null || seq === undefined) throw err('invalid_cursor', 400);
    const [r] = await q(
      `INSERT INTO sary.chat_reads (outing_id, user_id, conv, last_seq)
       SELECT $1, $2, $3, LEAST($4::bigint, o.chat_seq) FROM sary.outings o WHERE o.id = $1
       ON CONFLICT (outing_id, user_id, conv) DO UPDATE SET last_seq = GREATEST(sary.chat_reads.last_seq, EXCLUDED.last_seq), updated_at = now()
       RETURNING last_seq`,
      [outingId, user.id, a.conv, seq],
    );
    const last = Number(r?.last_seq || 0);
    if (!a.until && a.m.outing_status !== 'ended') {
      deliver(outingId, a.peer, user.id, { type: 'chat_read', conv: a.peer ? 'direct' : 'group', user_id: user.id, peer_id: a.peer, seq: last });
    }
    return { with: a.peer || 'group', last_read_seq: last };
  }

  /** Own message: always. Any group message: the leader or a «مساعد». Soft: content wiped. */
  async function remove(user, outingId, messageId) {
    if (!v.isUuid(messageId)) throw err('message_not_found', 404);
    const [msg] = await q(`SELECT id, conv, sender_id, recipient_id, deleted_at FROM sary.chat_messages WHERE id = $1 AND outing_id = $2`, [messageId, outingId]);
    if (!msg) throw err('message_not_found', 404);
    const peerOf = msg.conv === 'group' ? 'group' : msg.sender_id === user.id ? msg.recipient_id : msg.recipient_id === user.id ? msg.sender_id : null;
    if (!peerOf) throw err('message_not_found', 404); // someone else's direct chat: it does not exist for you
    const a = await access(user, outingId, peerOf);
    let role = null;
    if (msg.sender_id === user.id) role = 'self';
    else if (msg.conv === 'group' && canLead(a.m)) role = 'leader';
    if (!role) throw err('not_allowed', 403);
    if (!msg.deleted_at) {
      await q(
        `UPDATE sary.chat_messages SET body = NULL, lat = NULL, lng = NULL, label = NULL, deleted_at = now(), deleted_by_role = $2
         WHERE id = $1 AND deleted_at IS NULL`,
        [messageId, role],
      );
    }
    const [full] = await q(`SELECT ${MESSAGE_COLS} FROM sary.chat_messages c ${MESSAGE_JOINS} WHERE c.id = $1`, [messageId]);
    const message = messageOut(full);
    if (!msg.deleted_at) deliver(outingId, message.recipient_id, message.sender_id, { type: 'chat_deleted', message });
    return { message };
  }

  /** «يكتب…». Memory only, throttled, never stored. */
  async function typing(user, outingId, rawWith, on) {
    const a = await requireWritable(user, outingId, rawWith);
    const key = `${outingId}:${user.id}:${a.conv}`;
    const t = now();
    if (on !== false && t - (typingAt.get(key) || 0) < TYPING_MIN_GAP_MS) return { sent: false };
    if (on !== false) typingAt.set(key, t);
    else typingAt.delete(key);
    if (typingAt.size > 5000) for (const [k, at] of typingAt) if (t - at > 60_000) typingAt.delete(k);
    deliver(outingId, a.peer, user.id, { type: 'chat_typing', conv: a.peer ? 'direct' : 'group', user_id: user.id, peer_id: a.peer, on: on !== false }, { exceptUser: user.id });
    return { sent: true };
  }

  /* ---------- conversation list & badges ---------- */

  const MINE = `SELECT c.* FROM sary.chat_messages c
    WHERE c.outing_id = $1 AND (c.conv = 'group' OR c.sender_id = $2 OR c.recipient_id = $2)
      AND ($3::timestamptz IS NULL OR c.created_at <= $3)`;

  async function unreadRows(outingId, userId, until) {
    return q(
      `WITH mine AS (${MINE})
       SELECT mine.conv, count(*)::int AS n FROM mine
       LEFT JOIN sary.chat_reads r ON r.outing_id = $1 AND r.user_id = $2 AND r.conv = mine.conv
       WHERE mine.sender_id <> $2 AND mine.deleted_at IS NULL AND mine.seq > COALESCE(r.last_seq, 0)
       GROUP BY mine.conv`,
      [outingId, userId, until],
    );
  }

  /** The total for the Group-tab badge (also in the outing snapshot). 0 for anyone without access. */
  async function unreadTotal(outingId, userId) {
    const m = await standing(outingId, userId);
    if (!m || !m.status || m.status === 'removed') return 0;
    const rows = await unreadRows(outingId, userId, m.status === 'left' ? m.left_at : null);
    return rows.reduce((s, r) => s + r.n, 0);
  }

  /** Group first, then every direct chat with messages, newest first. */
  async function conversations(user, outingId) {
    const a = await access(user, outingId, 'group');
    const last = await q(
      `WITH mine AS (${MINE})
       SELECT DISTINCT ON (c.conv) ${MESSAGE_COLS}
       FROM mine c ${MESSAGE_JOINS}
       ORDER BY c.conv, c.seq DESC`,
      [outingId, user.id, a.until],
    );
    const unread = new Map((await unreadRows(outingId, user.id, a.until)).map((r) => [r.conv, r.n]));
    const reads = new Map(
      (await q(`SELECT conv, user_id, last_seq FROM sary.chat_reads WHERE outing_id = $1 AND (conv = 'group' OR conv LIKE '%' || $2 || '%')`, [outingId, user.id])).map((r) => [
        `${r.conv}|${r.user_id}`,
        Number(r.last_seq),
      ]),
    );
    const statuses = new Map((await q(`SELECT user_id, status FROM sary.outing_members WHERE outing_id = $1`, [outingId])).map((r) => [r.user_id, r.status]));
    const byConv = new Map(last.map((r) => [r.conv, r]));
    const group = byConv.get('group');
    const out = [
      {
        with: 'group',
        conv: 'group',
        peer_id: null,
        unread: unread.get('group') || 0,
        last_message: group ? messageOut(group) : null,
        my_read_seq: reads.get(`group|${user.id}`) || 0,
        writable: a.writable,
      },
    ];
    const directs = last
      .filter((r) => r.conv !== 'group')
      .sort((x, y) => Number(y.seq) - Number(x.seq))
      .map((r) => {
        const peer = r.sender_id === user.id ? r.recipient_id : r.sender_id;
        return {
          with: peer,
          conv: 'direct',
          peer_id: peer,
          peer_active: statuses.get(peer) === 'active',
          unread: unread.get(r.conv) || 0,
          last_message: messageOut(r),
          my_read_seq: reads.get(`${r.conv}|${user.id}`) || 0,
          peer_read_seq: reads.get(`${r.conv}|${peer}`) || 0,
          writable: a.writable && statuses.get(peer) === 'active',
        };
      });
    out.push(...directs);
    const purgeAt = a.m.ended_at ? new Date(new Date(a.m.ended_at).getTime() + retentionDays * 86_400_000).toISOString() : null;
    return {
      conversations: out,
      unread_total: out.reduce((s, c) => s + c.unread, 0),
      writable: a.writable,
      read_only_reason: a.why,
      can_moderate: canLead(a.m) && a.m.outing_status !== 'ended',
      quick_replies: QUICK_PRESETS,
      limits: { text_max: TEXT_MAX },
      retention_days: retentionDays,
      purge_at: purgeAt,
    };
  }

  /* ---------- live socket frames ---------- */

  /** One chat_* frame from an authenticated socket → the reply to send back (or null). */
  async function socketFrame(user, outingId, msg) {
    if (msg.type === 'chat_message') {
      try {
        const r = await send(user, outingId, msg);
        return { type: 'chat_ack', id: msg.id ?? null, ok: true, message: r.message, duplicate: r.duplicate };
      } catch (e) {
        return { type: 'chat_ack', id: msg.id ?? null, ok: false, client_id: typeof msg.client_id === 'string' ? msg.client_id.slice(0, 64) : null, reason: e.code || 'server_error' };
      }
    }
    if (msg.type === 'chat_read') {
      try {
        await markRead(user, outingId, msg.with, msg.seq);
      } catch {
        /* a stale read marker is harmless */
      }
      return null;
    }
    if (msg.type === 'chat_typing') {
      try {
        await typing(user, outingId, msg.with, msg.on);
      } catch {
        /* typing is a hint */
      }
      return null;
    }
    return null;
  }

  /* ---------- notification preference ---------- */

  async function prefs(user) {
    const [r] = await q(`SELECT chat_push FROM sary.users WHERE id = $1`, [user.id]);
    return { chat_push: r ? r.chat_push !== false : true };
  }

  async function setPrefs(user, raw = {}) {
    if (typeof raw.chat_push !== 'boolean') throw err('invalid_prefs', 400);
    await q(`UPDATE sary.users SET chat_push = $2 WHERE id = $1`, [user.id, raw.chat_push]);
    return { chat_push: raw.chat_push };
  }

  /* ---------- retention ---------- */

  /** Delete every message and read marker of outings that ended more than `retentionDays` ago. */
  async function purge() {
    const days = Math.max(0, Number(retentionDays) || RETENTION_DAYS);
    const msgs = await q(
      `DELETE FROM sary.chat_messages c USING sary.outings o
       WHERE c.outing_id = o.id AND o.status = 'ended' AND o.ended_at < now() - make_interval(days => $1)
       RETURNING c.id`,
      [days],
    );
    await q(
      `DELETE FROM sary.chat_reads r USING sary.outings o
       WHERE r.outing_id = o.id AND o.status = 'ended' AND o.ended_at < now() - make_interval(days => $1)`,
      [days],
    );
    return { deleted: msgs.length };
  }

  return {
    unreadTotal,
    purge,
    api: {
      chatConversations: conversations,
      chatMessages: list,
      chatSend: send,
      chatRead: markRead,
      chatDelete: remove,
      chatTyping: typing,
      chatSocketFrame: socketFrame,
      chatPrefs: prefs,
      setChatPrefs: setPrefs,
      chatPurge: purge,
    },
  };
}

module.exports = { createChat, chatText, parseWith, parseMessage, directKey, messageOut, QUICK_PRESETS, TEXT_MAX, RETENTION_DAYS };
