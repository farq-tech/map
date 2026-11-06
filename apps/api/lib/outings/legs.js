'use strict';

/**
 * «المشاوير» — legs inside an outing (migration 016, ux/الطلعة-والمشوار.md).
 *
 *   «الطلعة» (outing) is the container: it starts with the leader's «ابدأ الطلعة» and
 *   runs until «أنهِ الطلعة». A «مشوار» (leg) is one A → B inside it: it starts with
 *   «ابدأ المشوار», arriving ends that leg only, and the outing goes on.
 *
 *   GET  /api/outings/:id/legs                    → { legs, current, mine, server_now }
 *   POST /api/outings/:id/legs                    { destination: {name,lat,lng}, scope: 'group'|'personal', client_id? }
 *                                                 → 201 { leg } (200 { leg, duplicate: true } for a retry)
 *   POST /api/outings/:id/legs/:legId/arrive      { distance_m?, duration_s? } → { leg }   (idempotent)
 *   POST /api/outings/:id/legs/:legId/cancel      → { leg }
 *
 * Who: a group leg — a leader (owner or co-leader) starts, arrives or cancels it; every
 * member sees it. A personal leg — any active member, for themselves; only they see it.
 * Legs start only while the outing is active. Starting a leg replaces the one of the same
 * scope still on the way (it becomes `cancelled`: a changed mind is not a leg).
 *
 * Backward compatibility (builds 20–22 know only the plan's destination): starting a group
 * leg also sets the outing's plan_destination and emits `plan_updated`, so older phones
 * see the current leg's destination as «الوجهة». Live: `{ type: 'leg_updated', leg }` for
 * group legs (older clients ignore unknown frames).
 *
 * When the outing ends, legs still on the way read as `ended` (closed at the end).
 */

const v = require('./validate');

const CLIENT_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_LEGS = 200;

function iso(d) {
  return d ? new Date(d).toISOString() : null;
}

function legOut(r) {
  return {
    id: r.id,
    seq: r.seq,
    scope: r.scope,
    destination: { name: r.dest_name, lat: r.dest_lat, lng: r.dest_lng },
    state: r.state,
    started_at: iso(r.started_at),
    arrived_at: iso(r.arrived_at),
    closed_at: iso(r.closed_at),
    distance_m: r.distance_m ?? null,
    duration_s: r.duration_s ?? null,
    started_by: r.started_by || null,
  };
}

/** Body → { destination, scope, clientId } or { error }. Pure. */
function parseLegStart(raw) {
  if (!raw || typeof raw !== 'object') return { error: 'invalid_leg' };
  const destination = v.destination(raw.destination);
  if (!destination) return { error: 'invalid_destination' };
  const scope = raw.scope === undefined ? 'group' : raw.scope;
  if (scope !== 'group' && scope !== 'personal') return { error: 'invalid_scope' };
  let clientId = null;
  if (raw.client_id !== undefined && raw.client_id !== null) {
    if (typeof raw.client_id !== 'string' || !CLIENT_ID_RE.test(raw.client_id)) return { error: 'invalid_client_id' };
    clientId = raw.client_id;
  }
  return { value: { destination, scope, clientId } };
}

/** Totals from the phone: whole numbers in range, else absent. Pure. */
function parseLegTotals(raw) {
  const out = { distance_m: null, duration_s: null };
  if (!raw || typeof raw !== 'object') return out;
  const d = Number(raw.distance_m);
  if (raw.distance_m != null && Number.isFinite(d) && d >= 0) out.distance_m = Math.min(Math.round(d), 3_000_000);
  const s = Number(raw.duration_s);
  if (raw.duration_s != null && Number.isFinite(s) && s >= 0) out.duration_s = Math.min(Math.round(s), 1_209_600);
  return out;
}

function createLegs({ q, tx, hub, requireMember, canLead, err, now = () => Date.now() }) {
  const COLS = `id, seq, scope, owner_user_id, started_by, dest_name, dest_lat, dest_lng, state,
                started_at, arrived_at, closed_at, distance_m, duration_s`;

  /** Legs still on the way in an ended outing are closed as `ended`, at the end. */
  async function closeIfEnded(outingId, m) {
    if (m.outing_status !== 'ended') return;
    await q(
      `UPDATE sary.outing_legs l SET state = 'ended', closed_at = COALESCE(o.ended_at, now())
       FROM sary.outings o WHERE o.id = l.outing_id AND l.outing_id = $1 AND l.state = 'active'`,
      [outingId],
    );
  }

  function visibleTo(userId) {
    return (r) => r.scope === 'group' || r.owner_user_id === userId;
  }

  async function list(user, outingId) {
    const m = await requireMember(user, outingId, { fresh: true });
    await closeIfEnded(outingId, m);
    const rows = (await q(
      `SELECT ${COLS} FROM sary.outing_legs WHERE outing_id = $1 AND (scope = 'group' OR owner_user_id = $2) ORDER BY seq`,
      [outingId, user.id],
    ));
    const legs = rows.map(legOut);
    return {
      legs,
      current: legs.find((l) => l.scope === 'group' && l.state === 'active') || null,
      mine: legs.find((l) => l.scope === 'personal' && l.state === 'active') || null,
      server_now: new Date(now()).toISOString(),
    };
  }

  async function start(user, outingId, raw) {
    const parsed = parseLegStart(raw);
    if (parsed.error) throw err(parsed.error, 400);
    const { destination, scope, clientId } = parsed.value;
    const m = await requireMember(user, outingId, { fresh: true });
    if (scope === 'group' && !canLead(m)) throw err('leader_only', 403);
    if (m.outing_status !== 'active') throw err(m.outing_status === 'ended' ? 'outing_ended' : 'outing_not_active', 409);
    const owner = scope === 'personal' ? user.id : null;
    const out = await tx(async (run) => {
      const [o] = await run(`SELECT status FROM sary.outings WHERE id = $1 FOR UPDATE`, [outingId]);
      if (!o || o.status !== 'active') throw err('outing_not_active', 409);
      if (clientId) {
        const [dup] = await run(`SELECT ${COLS} FROM sary.outing_legs WHERE outing_id = $1 AND client_id = $2`, [outingId, clientId]);
        if (dup) {
          if (!visibleTo(user.id)(dup)) throw err('invalid_client_id', 409);
          return { row: dup, duplicate: true };
        }
      }
      const [{ n, top }] = await run(`SELECT count(*)::int AS n, COALESCE(max(seq), 0)::int AS top FROM sary.outing_legs WHERE outing_id = $1`, [outingId]);
      if (n >= MAX_LEGS) throw err('too_many_legs', 409);
      await run(
        `UPDATE sary.outing_legs SET state = 'cancelled', closed_at = now()
         WHERE outing_id = $1 AND state = 'active' AND scope = $2 AND owner_user_id IS NOT DISTINCT FROM $3`,
        [outingId, scope, owner],
      );
      const [row] = await run(
        `INSERT INTO sary.outing_legs (outing_id, seq, scope, owner_user_id, started_by, dest_name, dest_lat, dest_lng, client_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING ${COLS}`,
        [outingId, top + 1, scope, owner, user.id, destination.name, destination.lat, destination.lng, clientId],
      );
      let plan = null;
      if (scope === 'group') {
        /* Builds 20–22 read the plan's destination: the current leg's, for them. */
        const [p] = await run(
          `UPDATE sary.outings SET plan_destination = $2::jsonb, plan_updated_at = now(), updated_at = now() WHERE id = $1
           RETURNING plan_route, plan_notes, plan_destination, plan_updated_at`,
          [outingId, JSON.stringify(destination)],
        );
        plan = { route: p.plan_route || null, notes: p.plan_notes || '', destination: p.plan_destination || null, updated_at: iso(p.plan_updated_at) };
      }
      return { row, plan, duplicate: false };
    });
    const leg = legOut(out.row);
    if (!out.duplicate && scope === 'group') {
      hub().emit(outingId, { type: 'leg_updated', leg });
      if (out.plan) hub().emit(outingId, { type: 'plan_updated', plan: out.plan });
    }
    return out.duplicate ? { leg, duplicate: true } : { leg };
  }

  async function mayClose(user, outingId, legId) {
    if (!v.isUuid(legId)) throw err('leg_not_found', 404);
    const m = await requireMember(user, outingId, { fresh: true });
    const [r] = await q(`SELECT ${COLS} FROM sary.outing_legs WHERE id = $1 AND outing_id = $2`, [legId, outingId]);
    if (!r || !visibleTo(user.id)(r)) throw err('leg_not_found', 404);
    if (r.scope === 'group' && !canLead(m)) throw err('leader_only', 403);
    return { m, r };
  }

  /** «وصلنا»: ends this leg only. Arriving twice answers the same leg. */
  async function arrive(user, outingId, legId, raw) {
    const { r } = await mayClose(user, outingId, legId);
    if (r.state === 'arrived') return { leg: legOut(r) };
    if (r.state !== 'active') throw err('leg_closed', 409);
    const t = parseLegTotals(raw);
    const [row] = await q(
      `UPDATE sary.outing_legs SET state = 'arrived', arrived_at = now(), closed_at = now(),
              distance_m = COALESCE($3, distance_m),
              duration_s = COALESCE($4, GREATEST(0, EXTRACT(EPOCH FROM (now() - started_at)))::int)
       WHERE id = $1 AND outing_id = $2 AND state = 'active' RETURNING ${COLS}`,
      [legId, outingId, t.distance_m, t.duration_s],
    );
    if (!row) {
      const [again] = await q(`SELECT ${COLS} FROM sary.outing_legs WHERE id = $1`, [legId]);
      if (again?.state === 'arrived') return { leg: legOut(again) };
      throw err('leg_closed', 409);
    }
    const leg = legOut(row);
    if (leg.scope === 'group') hub().emit(outingId, { type: 'leg_updated', leg });
    return { leg };
  }

  async function cancel(user, outingId, legId) {
    const { r } = await mayClose(user, outingId, legId);
    if (r.state === 'cancelled') return { leg: legOut(r) };
    if (r.state !== 'active') throw err('leg_closed', 409);
    const [row] = await q(
      `UPDATE sary.outing_legs SET state = 'cancelled', closed_at = now() WHERE id = $1 AND state = 'active' RETURNING ${COLS}`,
      [legId],
    );
    if (!row) throw err('leg_closed', 409);
    const leg = legOut(row);
    if (leg.scope === 'group') hub().emit(outingId, { type: 'leg_updated', leg });
    return { leg };
  }

  return { list, start, arrive, cancel };
}

module.exports = { createLegs, parseLegStart, parseLegTotals, legOut, MAX_LEGS };
