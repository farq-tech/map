'use strict';

/**
 * Outing features, on the same rules as the rest of the service: membership
 * is checked on the server for every call, leader checks use canLead.
 *
 *   1. Return timer («مؤقت الرجوع») + public watch link + sweeper
 *   2. «غرّزت» (stuck) with replies — memory only, like SOS
 *   3. Shared waypoints («نقاط مشتركة»)
 *   4. Convoy settings («وضع القافلة»)
 *   5. Trip plan («تخطيط الطلعة») + destination + checklist
 *
 * Built by createOutingsService, which hands it its internals (ctx) and
 * spreads the returned methods into the service.
 */

const v = require('./validate');
const { createRateLimiter } = require('./rate-limit');
const { featurePayload, watcherPayload } = require('./push');

const DEFAULT_WATCH_BASE = 'https://farq-map-investor.vercel.app/watch';
const STUCK_TTL_MS = 3 * 3600_000;
const STUCK_MIN_GAP_MS = 3_000;
const MAX_WAYPOINTS = 200;
const MAX_CHECKLIST = 100;
const MAX_WATCH_TOKENS = 5;
const MAX_WATCH_SUBS = 10;
/* Closed timers (arrived / cancelled) answer the watch link for a day, then go. */
const CLOSED_TIMER_KEEP_MS = 24 * 3600_000;
/* An overdue timer nobody closed — and its position snapshot — is kept 7 days past its due time. */
const OVERDUE_TIMER_KEEP_MS = 7 * 24 * 3600_000;

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function createFeatures(ctx) {
  const { q, tx, now, err, events, requireMember, requireLeader, membership, canLead, positions, push, webPush, cfg } = ctx;
  const hub = () => events();
  const watchBase = cfg.watchBaseUrl || process.env.SARY_WATCH_BASE_URL || DEFAULT_WATCH_BASE;

  async function namesOf(outingId, senderId) {
    const [row] = await q(
      `SELECT o.name AS outing_name, u.display_name AS sender_name
       FROM sary.outings o LEFT JOIN sary.users u ON u.id = $2::uuid WHERE o.id = $1`,
      [outingId, v.isUuid(senderId) ? senderId : null],
    );
    return row || null;
  }

  /** Best effort, never awaited by callers' answers. */
  async function pushFeature(kind, outingId, senderId, extra = {}) {
    if (!push.enabled) return null;
    try {
      const row = await namesOf(outingId, senderId);
      if (!row) return null;
      const payload = featurePayload(kind, { senderName: row.sender_name, outingName: row.outing_name, outingId, ...extra });
      if (!payload) return null;
      return await push.notifyMembers(outingId, extra.exceptUserId === undefined ? senderId || null : extra.exceptUserId, payload);
    } catch (e) {
      console.warn('[outings-push] feature', e.code || e.message);
      return null;
    }
  }

  async function pushWatchers(timerId, kind, ownerName) {
    if (!webPush?.enabled) return null;
    const payload = watcherPayload(kind, { ownerName });
    if (!payload) return null;
    return webPush.notifyWatchers(timerId, payload);
  }

  /** Own-timer calls (get / arrived / cancel) are open to anyone who is or was in the outing:
   * leaving does not cancel a timer, so it must still be closable. Arming needs active membership. */
  async function requireTimerOwner(user, outingId) {
    const m = await membership(outingId, user.id, { fresh: true });
    if (!m || !m.status) throw err('not_a_member', 404);
    return m;
  }

  /* ---------- 1. return timer ---------- */

  function timerOut(r) {
    return r ? { id: r.id, due_at: iso(r.due_at), contact_name: r.contact_name, state: r.state } : null;
  }

  function emitTimer(outingId, userId, state, dueAt) {
    hub().emit(outingId, { type: 'return_timer', user_id: userId, state, due_at: iso(dueAt) });
  }

  async function liveTimer(run, outingId, userId) {
    const [r] = await run(
      `SELECT id, due_at, contact_name, state FROM sary.return_timers
       WHERE outing_id = $1 AND user_id = $2 AND state IN ('armed', 'overdue') FOR UPDATE`,
      [outingId, userId],
    );
    return r || null;
  }

  /**
   * Arm (or replace) my return timer. Same contact while one is live = an
   * extension («مدّد»): the same timer, so the contact's earlier link keeps
   * working, plus a fresh link in the answer. A different contact cancels the
   * old timer (its link shows «أُلغي») and starts a new one.
   */
  async function armReturnTimer(user, outingId, raw) {
    await requireMember(user, outingId, { fresh: true });
    const parsed = v.returnTimer(raw, now());
    if (!parsed.ok) throw err(parsed.reason, 400);
    const { due_at, contact_name } = parsed.value;
    const token = v.newSecret();
    const at = new Date(now());
    const out = await tx(async (run) => {
      const prev = await liveTimer(run, outingId, user.id);
      let row;
      let wasOverdue = false;
      if (prev && prev.contact_name === contact_name) {
        wasOverdue = prev.state === 'overdue';
        [row] = await run(
          `UPDATE sary.return_timers SET due_at = $2, state = 'armed', overdue_at = NULL, last_known = NULL
           WHERE id = $1 RETURNING id, due_at, contact_name, state`,
          [prev.id, due_at],
        );
      } else {
        if (prev) await run(`UPDATE sary.return_timers SET state = 'cancelled', closed_at = $2 WHERE id = $1`, [prev.id, at]);
        [row] = await run(
          `INSERT INTO sary.return_timers (outing_id, user_id, due_at, contact_name, created_at)
           VALUES ($1, $2, $3, $4, $5) RETURNING id, due_at, contact_name, state`,
          [outingId, user.id, due_at, contact_name, at],
        );
      }
      await run(`INSERT INTO sary.watch_tokens (token_hash, timer_id, created_at) VALUES ($1, $2, $3)`, [v.digest(token), row.id, at]);
      await run(
        `DELETE FROM sary.watch_tokens WHERE timer_id = $1 AND token_hash NOT IN (
           SELECT token_hash FROM sary.watch_tokens WHERE timer_id = $1 ORDER BY created_at DESC LIMIT $2)`,
        [row.id, MAX_WATCH_TOKENS],
      );
      return { row, wasOverdue, replaced: prev && prev.id !== row.id ? prev.id : null };
    });
    emitTimer(outingId, user.id, 'armed', out.row.due_at);
    if (out.wasOverdue) void pushWatchers(out.row.id, 'extended', user.display_name);
    return { timer: timerOut(out.row), watch_url: `${watchBase}#${token}` };
  }

  async function getReturnTimer(user, outingId) {
    await requireTimerOwner(user, outingId);
    const [r] = await q(
      `SELECT id, due_at, contact_name, state FROM sary.return_timers
       WHERE outing_id = $1 AND user_id = $2 AND state IN ('armed', 'overdue')`,
      [outingId, user.id],
    );
    return { timer: timerOut(r) };
  }

  async function closeTimer(user, outingId, state) {
    await requireTimerOwner(user, outingId);
    const [r] = await q(
      `UPDATE sary.return_timers SET state = $3, closed_at = $4
       WHERE outing_id = $1 AND user_id = $2 AND state IN ('armed', 'overdue')
       RETURNING id, due_at, contact_name, state`,
      [outingId, user.id, state, new Date(now())],
    );
    if (!r) throw err('no_timer', 404);
    emitTimer(outingId, user.id, state, r.due_at);
    return r;
  }

  /** «وصلت»: closes the timer and tells the watchers «وصلوا بالسلامة». */
  async function arrivedReturnTimer(user, outingId) {
    const r = await closeTimer(user, outingId, 'arrived');
    void pushWatchers(r.id, 'arrived', user.display_name);
    return { timer: timerOut(r) };
  }

  async function cancelReturnTimer(user, outingId) {
    const r = await closeTimer(user, outingId, 'cancelled');
    return { timer: timerOut(r) };
  }

  async function timerByToken(token) {
    if (!v.isSecretShaped(token)) return null;
    const [r] = await q(
      `SELECT t.id, t.outing_id, t.user_id, t.due_at, t.contact_name, t.state, t.last_known,
              o.name AS outing_name, u.display_name AS owner_name, u.phone AS owner_phone
       FROM sary.watch_tokens w
       JOIN sary.return_timers t ON t.id = w.timer_id
       JOIN sary.outings o ON o.id = t.outing_id
       JOIN sary.users u ON u.id = t.user_id
       WHERE w.token_hash = $1`,
      [v.digest(token)],
    );
    return r || null;
  }

  /**
   * The public watch link. What a watcher sees: the outing's and the person's
   * names, the contact name they were given, the due time and state, and the
   * names of the members while it is live. Positions ONLY once overdue — the
   * snapshot taken at that moment, of members who had sharing on — plus the
   * timer owner's own phone if they put one on their profile.
   */
  async function watchStatus(token) {
    const r = await timerByToken(token);
    if (!r) throw err('watch_invalid', 404);
    const live = r.state === 'armed' || r.state === 'overdue';
    const members = live
      ? await q(
          `SELECT u.display_name AS name FROM sary.outing_members m JOIN sary.users u ON u.id = m.user_id
           WHERE m.outing_id = $1 AND m.status = 'active' ORDER BY m.role = 'owner' DESC, m.joined_at`,
          [r.outing_id],
        )
      : [];
    const out = {
      outing_name: r.outing_name,
      owner_name: r.owner_name,
      contact_name: r.contact_name,
      due_at: iso(r.due_at),
      state: r.state,
      members: members.map((m) => ({ name: m.name })),
      server_now: new Date(now()).toISOString(),
    };
    if (r.state === 'overdue') {
      out.last_known = (Array.isArray(r.last_known) ? r.last_known : []).map((p) => ({ name: p.name, lat: p.lat, lng: p.lng, at: p.at }));
      out.owner_phone = r.owner_phone || null;
    }
    return out;
  }

  async function watchSubscribe(token, raw, parseSubscription) {
    if (!webPush?.enabled) throw err('push_disabled', 503);
    const r = await timerByToken(token);
    if (!r) throw err('watch_invalid', 404);
    if (r.state !== 'armed' && r.state !== 'overdue') throw err('watch_closed', 410);
    const sub = parseSubscription(raw);
    if (!sub) throw err('invalid_subscription', 400);
    await q(
      `INSERT INTO sary.watch_subscriptions (timer_id, endpoint, p256dh, auth) VALUES ($1, $2, $3, $4)
       ON CONFLICT (timer_id, endpoint) DO UPDATE SET p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth`,
      [r.id, sub.endpoint, sub.p256dh, sub.auth],
    );
    await q(
      `DELETE FROM sary.watch_subscriptions WHERE id IN (
         SELECT id FROM sary.watch_subscriptions WHERE timer_id = $1 ORDER BY created_at DESC OFFSET $2)`,
      [r.id, MAX_WATCH_SUBS],
    );
    return { subscribed: true };
  }

  /** The last real positions right now, of active members with sharing on (never estimated). */
  async function snapshot(outingId) {
    const [o] = await q(`SELECT status FROM sary.outings WHERE id = $1`, [outingId]);
    if (!o) return [];
    const pos = await positions(outingId, o.status);
    if (!pos.length) return [];
    const names = new Map(
      (await q(`SELECT id, display_name FROM sary.users WHERE id = ANY($1::uuid[])`, [pos.map((p) => p.user_id)])).map((u) => [u.id, u.display_name]),
    );
    return pos.map((p) => ({ user_id: p.user_id, name: names.get(p.user_id) || '', lat: p.lat, lng: p.lng, at: p.recorded_at }));
  }

  /**
   * Every 60 s: armed timers past due → overdue, with the position snapshot
   * taken now, a push to the watchers and to the outing's members (even if
   * the outing has ended — people end it in the desert). The state change is
   * one conditional UPDATE, so two instances never alarm twice.
   */
  async function sweepReturnTimers() {
    const t = new Date(now());
    const due = await q(
      `SELECT id, outing_id, user_id FROM sary.return_timers WHERE state = 'armed' AND due_at <= $1 ORDER BY due_at LIMIT 200`,
      [t],
    );
    let overdue = 0;
    for (const d of due) {
      const snap = await snapshot(d.outing_id);
      const [row] = await q(
        `UPDATE sary.return_timers SET state = 'overdue', overdue_at = $2, last_known = $3::jsonb
         WHERE id = $1 AND state = 'armed' AND due_at <= $2
         RETURNING id, due_at`,
        [d.id, t, JSON.stringify(snap)],
      );
      if (!row) continue;
      overdue += 1;
      emitTimer(d.outing_id, d.user_id, 'overdue', row.due_at);
      const [owner] = await q(`SELECT display_name FROM sary.users WHERE id = $1`, [d.user_id]);
      void pushWatchers(d.id, 'overdue', owner?.display_name);
      void pushFeature('return_timer_overdue', d.outing_id, d.user_id, { exceptUserId: null });
    }
    return { overdue };
  }

  /* ---------- 2. stuck («غرّزت») ---------- */

  const stuck = new Map(); // `${outingId}:${userId}` → { at, updated_at, note, replies: Map(userId → kind) }
  const stuckLimit = createRateLimiter({ limit: 20, windowMs: 10 * 60_000, now });

  function stuckEntry(outingId, userId) {
    const key = `${outingId}:${userId}`;
    const s = stuck.get(key);
    if (!s) return null;
    if (now() - s.updated_at > STUCK_TTL_MS) {
      stuck.delete(key);
      return null;
    }
    return s;
  }

  function stuckOut(userId, s) {
    return { user_id: userId, at: iso(s.at), note: s.note, replies: [...s.replies].map(([uid, kind]) => ({ user_id: uid, kind })) };
  }

  function stuckList(outingId) {
    const out = [];
    for (const k of [...stuck.keys()]) {
      if (!k.startsWith(`${outingId}:`)) continue;
      const uid = k.slice(outingId.length + 1);
      const s = stuckEntry(outingId, uid);
      if (s) out.push(stuckOut(uid, s));
    }
    return out;
  }

  function dropStuck(outingId, userId) {
    if (userId) return stuck.delete(`${outingId}:${userId}`);
    for (const k of [...stuck.keys()]) if (k.startsWith(`${outingId}:`)) stuck.delete(k);
    return true;
  }

  async function raiseStuck(user, outingId, raw = {}) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const n = v.stuckNote(raw?.note);
    if (!n.ok) throw err('invalid_note', 400);
    const key = `${outingId}:${user.id}`;
    const prev = stuckEntry(outingId, user.id);
    if (prev && now() - prev.updated_at < STUCK_MIN_GAP_MS) throw err('too_frequent', 429);
    if (!stuckLimit(user.id)) throw err('rate_limited', 429);
    const next = prev ? { ...prev, updated_at: now(), note: n.value } : { at: now(), updated_at: now(), note: n.value, replies: new Map() };
    stuck.set(key, next);
    hub().emit(outingId, { type: 'member_stuck', user_id: user.id, at: iso(next.at), note: next.note });
    /* One alarm per «غرّزت»; a changed note updates screens without waking phones again. */
    if (!prev) void pushFeature('member_stuck', outingId, user.id, { note: next.note, userId: user.id });
    return { stuck: stuckOut(user.id, next) };
  }

  async function replyStuck(user, outingId, targetId, raw = {}) {
    const m = await requireMember(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const kind = raw?.kind;
    if (!v.STUCK_REPLY_KINDS.includes(kind)) throw err('invalid_kind', 400);
    if (!v.isUuid(targetId)) throw err('not_stuck', 404);
    const to = targetId.toLowerCase();
    if (to === user.id) throw err('cannot_reply_self', 400);
    const s = stuckEntry(outingId, to);
    if (!s) throw err('not_stuck', 404);
    s.replies.set(user.id, kind);
    hub().emit(outingId, { type: 'stuck_reply', user_id: user.id, to_user_id: to, kind });
    /* To the stuck person only. */
    void pushFeature('stuck_reply', outingId, user.id, { replyKind: kind, userId: to });
    return { stuck: stuckOut(to, s) };
  }

  async function clearStuck(user, outingId) {
    await requireMember(user, outingId);
    const had = stuck.delete(`${outingId}:${user.id}`);
    if (had) hub().emit(outingId, { type: 'stuck_clear', user_id: user.id });
    return { stuck: null };
  }

  /* ---------- 3. waypoints ---------- */

  function waypointOut(r) {
    return { id: r.id, outing_id: r.outing_id, user_id: r.user_id, kind: r.kind, title: r.title, note: r.note, lat: r.lat, lng: r.lng, photo: r.photo, created_at: iso(r.created_at) };
  }

  const WP_COLS = 'id, outing_id, user_id, kind, title, note, lat, lng, photo, created_at';

  async function listWaypoints(user, outingId) {
    await requireMember(user, outingId);
    const rows = await q(`SELECT ${WP_COLS} FROM sary.outing_waypoints WHERE outing_id = $1 ORDER BY created_at, id`, [outingId]);
    return { waypoints: rows.map(waypointOut) };
  }

  async function addWaypoint(user, outingId, raw) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const parsed = v.waypoint(raw);
    if (!parsed.ok) throw err(parsed.reason, 400);
    const w = parsed.value;
    const [{ n }] = await q(`SELECT count(*)::int AS n FROM sary.outing_waypoints WHERE outing_id = $1`, [outingId]);
    if (n >= MAX_WAYPOINTS) throw err('too_many_waypoints', 409);
    const [row] = await q(
      `INSERT INTO sary.outing_waypoints (outing_id, user_id, kind, title, note, lat, lng, photo, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING ${WP_COLS}`,
      [outingId, user.id, w.kind, w.title, w.note, w.lat, w.lng, w.photo, new Date(now())],
    );
    const waypoint = waypointOut(row);
    hub().emit(outingId, { type: 'waypoint_added', waypoint });
    void pushFeature('waypoint_added', outingId, user.id, { title: w.title });
    return { waypoint };
  }

  async function removeWaypoint(user, outingId, wid) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (!v.isUuid(wid)) throw err('waypoint_not_found', 404);
    const [row] = await q(`SELECT user_id FROM sary.outing_waypoints WHERE id = $1 AND outing_id = $2`, [wid, outingId]);
    if (!row) throw err('waypoint_not_found', 404);
    if (row.user_id !== user.id && !canLead(m)) throw err('not_allowed', 403);
    await q(`DELETE FROM sary.outing_waypoints WHERE id = $1 AND outing_id = $2`, [wid, outingId]);
    hub().emit(outingId, { type: 'waypoint_removed', id: wid });
    return { removed: wid };
  }

  /* ---------- 4. convoy ---------- */

  function convoyOut(r) {
    return { lead_user_id: r.convoy_lead_user_id || null, tail_user_id: r.convoy_tail_user_id || null, max_gap_m: r.convoy_max_gap_m ?? 1000 };
  }

  async function activeMember(outingId, userId) {
    const [r] = await q(`SELECT 1 FROM sary.outing_members WHERE outing_id = $1 AND user_id = $2 AND status = 'active'`, [outingId, userId]);
    return Boolean(r);
  }

  async function setConvoy(user, outingId, raw) {
    const m = await requireLeader(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const patch = v.convoyPatch(raw);
    if (!patch) throw err('invalid_convoy', 400);
    const [cur] = await q(`SELECT convoy_lead_user_id, convoy_tail_user_id, convoy_max_gap_m FROM sary.outings WHERE id = $1`, [outingId]);
    const lead = patch.lead !== undefined ? patch.lead : cur.convoy_lead_user_id;
    const tail = patch.tail !== undefined ? patch.tail : cur.convoy_tail_user_id;
    const gap = patch.gap !== undefined ? patch.gap : cur.convoy_max_gap_m;
    if (lead && tail && lead === tail) throw err('invalid_convoy', 400);
    for (const uid of [patch.lead, patch.tail]) {
      if (uid && !(await activeMember(outingId, uid))) throw err('invalid_convoy_member', 400);
    }
    const [row] = await q(
      `UPDATE sary.outings SET convoy_lead_user_id = $2, convoy_tail_user_id = $3, convoy_max_gap_m = $4, updated_at = now()
       WHERE id = $1 AND status <> 'ended'
       RETURNING convoy_lead_user_id, convoy_tail_user_id, convoy_max_gap_m`,
      [outingId, lead, tail, gap],
    );
    if (!row) throw err('outing_ended', 409);
    const convoy = convoyOut(row);
    hub().emit(outingId, { type: 'convoy_updated', convoy });
    return { convoy };
  }

  /** A member who leaves or is removed stops being the lead / tail. */
  async function dropFromConvoy(outingId, userId) {
    const [row] = await q(
      `UPDATE sary.outings SET
         convoy_lead_user_id = CASE WHEN convoy_lead_user_id = $2 THEN NULL ELSE convoy_lead_user_id END,
         convoy_tail_user_id = CASE WHEN convoy_tail_user_id = $2 THEN NULL ELSE convoy_tail_user_id END
       WHERE id = $1 AND (convoy_lead_user_id = $2 OR convoy_tail_user_id = $2)
       RETURNING convoy_lead_user_id, convoy_tail_user_id, convoy_max_gap_m`,
      [outingId, userId],
    ).catch(() => []);
    if (row) hub().emit(outingId, { type: 'convoy_updated', convoy: convoyOut(row) });
  }

  /* ---------- 5. plan + destination + checklist ---------- */

  function planOut(r) {
    return { route: r.plan_route || null, notes: r.plan_notes || '', destination: r.plan_destination || null, updated_at: iso(r.plan_updated_at) };
  }

  async function getPlan(user, outingId) {
    await requireMember(user, outingId);
    const [r] = await q(`SELECT plan_route, plan_notes, plan_destination, plan_updated_at FROM sary.outings WHERE id = $1`, [outingId]);
    return planOut(r);
  }

  /** Leader only. Each of route / notes / destination is replaced when present, kept when absent. */
  async function putPlan(user, outingId, raw) {
    const m = await requireLeader(user, outingId);
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const parsed = v.planPut(raw);
    if (parsed.error) throw err(parsed.error, 400);
    const p = parsed.value;
    const sets = [];
    const params = [outingId];
    if (p.route !== undefined) {
      params.push(p.route === null ? null : JSON.stringify(p.route));
      sets.push(`plan_route = $${params.length}::jsonb`);
    }
    if (p.notes !== undefined) {
      params.push(p.notes || null);
      sets.push(`plan_notes = $${params.length}`);
    }
    if (p.destination !== undefined) {
      params.push(p.destination === null ? null : JSON.stringify(p.destination));
      sets.push(`plan_destination = $${params.length}::jsonb`);
    }
    params.push(new Date(now()));
    sets.push(`plan_updated_at = $${params.length}`);
    const [row] = await q(
      `UPDATE sary.outings SET ${sets.join(', ')}, updated_at = now() WHERE id = $1 AND status <> 'ended'
       RETURNING plan_route, plan_notes, plan_destination, plan_updated_at`,
      params,
    );
    if (!row) throw err('outing_ended', 409);
    const plan = planOut(row);
    hub().emit(outingId, { type: 'plan_updated', plan });
    return plan;
  }

  function itemOut(r) {
    return { id: r.id, title: r.title, assignee_user_id: r.assignee_user_id || null, done: r.done === true, created_by: r.created_by || null, created_at: iso(r.created_at) };
  }

  async function checklistItems(outingId) {
    const rows = await q(
      `SELECT id, title, assignee_user_id, done, created_by, created_at FROM sary.outing_checklist
       WHERE outing_id = $1 ORDER BY created_at, id`,
      [outingId],
    );
    return rows.map(itemOut);
  }

  async function emitChecklist(outingId) {
    hub().emit(outingId, { type: 'checklist_updated', items: await checklistItems(outingId) });
  }

  async function listChecklist(user, outingId) {
    await requireMember(user, outingId);
    return { items: await checklistItems(outingId) };
  }

  async function addChecklistItem(user, outingId, raw) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    const title = v.checklistTitle(raw?.title);
    if (!title) throw err('invalid_title', 400);
    const [{ n }] = await q(`SELECT count(*)::int AS n FROM sary.outing_checklist WHERE outing_id = $1`, [outingId]);
    if (n >= MAX_CHECKLIST) throw err('too_many_items', 409);
    const [row] = await q(
      `INSERT INTO sary.outing_checklist (outing_id, title, created_by, created_at) VALUES ($1, $2, $3, $4)
       RETURNING id, title, assignee_user_id, done, created_by, created_at`,
      [outingId, title, user.id, new Date(now())],
    );
    await emitChecklist(outingId);
    return { item: itemOut(row) };
  }

  async function patchChecklistItem(user, outingId, itemId, raw = {}) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (m.outing_status === 'ended') throw err('outing_ended', 409);
    if (!v.isUuid(itemId)) throw err('item_not_found', 404);
    const sets = [];
    const params = [itemId, outingId];
    if (raw && raw.assignee_user_id !== undefined) {
      const a = raw.assignee_user_id;
      if (a !== null && !v.isUuid(a)) throw err('invalid_assignee', 400);
      if (a !== null && !(await activeMember(outingId, a.toLowerCase()))) throw err('invalid_assignee', 400);
      params.push(a === null ? null : a.toLowerCase());
      sets.push(`assignee_user_id = $${params.length}`);
    }
    if (raw && raw.done !== undefined) {
      if (typeof raw.done !== 'boolean') throw err('invalid_item', 400);
      params.push(raw.done);
      sets.push(`done = $${params.length}`);
    }
    if (!sets.length) throw err('invalid_item', 400);
    const [row] = await q(
      `UPDATE sary.outing_checklist SET ${sets.join(', ')} WHERE id = $1 AND outing_id = $2
       RETURNING id, title, assignee_user_id, done, created_by, created_at`,
      params,
    );
    if (!row) throw err('item_not_found', 404);
    await emitChecklist(outingId);
    return { item: itemOut(row) };
  }

  async function removeChecklistItem(user, outingId, itemId) {
    const m = await requireMember(user, outingId, { fresh: true });
    if (!v.isUuid(itemId)) throw err('item_not_found', 404);
    const [row] = await q(`SELECT created_by FROM sary.outing_checklist WHERE id = $1 AND outing_id = $2`, [itemId, outingId]);
    if (!row) throw err('item_not_found', 404);
    if (row.created_by !== user.id && !canLead(m)) throw err('not_allowed', 403);
    await q(`DELETE FROM sary.outing_checklist WHERE id = $1 AND outing_id = $2`, [itemId, outingId]);
    await emitChecklist(outingId);
    return { removed: itemId };
  }

  /* ---------- account deletion / housekeeping hooks ---------- */

  /**
   * Inside the deleteAccount transaction, after owned outings were handed
   * over and before the user row goes: the person's waypoints and timers
   * (with their watch links and watcher subscriptions) are deleted, checklist
   * items they created pass to the outing's owner, items assigned to them are
   * unassigned, and their name/position is struck from other people's overdue
   * snapshots. Returns what changed, for afterAccountDeleted().
   */
  async function accountRows(run, userId) {
    const convoyRows = await run(
      `UPDATE sary.outings SET
         convoy_lead_user_id = CASE WHEN convoy_lead_user_id = $1 THEN NULL ELSE convoy_lead_user_id END,
         convoy_tail_user_id = CASE WHEN convoy_tail_user_id = $1 THEN NULL ELSE convoy_tail_user_id END
       WHERE convoy_lead_user_id = $1 OR convoy_tail_user_id = $1
       RETURNING id, convoy_lead_user_id, convoy_tail_user_id, convoy_max_gap_m`,
      [userId],
    );
    const waypoints = await run(`DELETE FROM sary.outing_waypoints WHERE user_id = $1 RETURNING id, outing_id`, [userId]);
    const timers = await run(`DELETE FROM sary.return_timers WHERE user_id = $1 RETURNING outing_id, state, due_at`, [userId]);
    const created = await run(
      `UPDATE sary.outing_checklist c SET created_by = o.owner_id
       FROM sary.outings o WHERE o.id = c.outing_id AND c.created_by = $1 AND o.owner_id <> $1
       RETURNING c.outing_id`,
      [userId],
    );
    const assigned = await run(`UPDATE sary.outing_checklist SET assignee_user_id = NULL WHERE assignee_user_id = $1 RETURNING outing_id`, [userId]);
    await run(
      `UPDATE sary.return_timers SET last_known = (
         SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(last_known) e WHERE e->>'user_id' <> $1::text)
       WHERE last_known IS NOT NULL AND last_known @> jsonb_build_array(jsonb_build_object('user_id', $1::text))`,
      [userId],
    );
    return { convoyRows, waypoints, timers, checklistOutings: [...new Set([...created, ...assigned].map((r) => r.outing_id))] };
  }

  async function afterAccountDeleted(info, userId) {
    if (!info) return;
    for (const r of info.convoyRows) hub().emit(r.id, { type: 'convoy_updated', convoy: convoyOut(r) });
    for (const w of info.waypoints) hub().emit(w.outing_id, { type: 'waypoint_removed', id: w.id });
    for (const t of info.timers) if (t.state === 'armed' || t.state === 'overdue') emitTimer(t.outing_id, userId, 'cancelled', t.due_at);
    for (const k of [...stuck.keys()]) {
      if (!k.endsWith(`:${userId}`)) continue;
      stuck.delete(k);
      hub().emit(k.slice(0, -(userId.length + 1)), { type: 'stuck_clear', user_id: userId });
    }
    for (const s of stuck.values()) s.replies.delete(userId);
    for (const oid of info.checklistOutings) await emitChecklist(oid).catch(() => undefined);
  }

  /** Part of the 10-minute sweep: closed timers after a day, unclosed overdue ones 7 days past due. */
  async function sweepFeatures() {
    const t = now();
    await q(
      `DELETE FROM sary.return_timers
       WHERE (state IN ('arrived', 'cancelled') AND closed_at < $1) OR (state = 'overdue' AND due_at < $2)`,
      [new Date(t - CLOSED_TIMER_KEEP_MS), new Date(t - OVERDUE_TIMER_KEEP_MS)],
    );
    for (const k of [...stuck.keys()]) {
      const i = k.indexOf(':');
      stuckEntry(k.slice(0, i), k.slice(i + 1));
    }
  }


  return {
    api: {
      armReturnTimer,
      getReturnTimer,
      arrivedReturnTimer,
      cancelReturnTimer,
      watchStatus,
      watchSubscribe,
      sweepReturnTimers,
      raiseStuck,
      replyStuck,
      clearStuck,
      listWaypoints,
      addWaypoint,
      removeWaypoint,
      setConvoy,
      getPlan,
      putPlan,
      listChecklist,
      addChecklistItem,
      patchChecklistItem,
      removeChecklistItem,
    },
    stuckList,
    dropStuck,
    convoyOut,
    dropFromConvoy,
    accountRows,
    afterAccountDeleted,
    sweepFeatures,
  };
}

module.exports = { createFeatures, DEFAULT_WATCH_BASE, STUCK_TTL_MS };
