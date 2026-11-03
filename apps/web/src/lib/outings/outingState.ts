/**
 * The client's picture of one outing, as a pure reducer over the server's
 * snapshot and live events — so every transition is testable without a map.
 */

import type { Member, OutingSnapshot, Position } from "./api";
import type { LiveEvent } from "./live";

export type OutingView = {
	snapshot: OutingSnapshot;
	members: Map<string, Member>;
	positions: Map<string, Position>;
	/** server clock − device clock, ms; ages are measured on the server's clock. */
	clockOffsetMs: number;
};

export function fromSnapshot(s: OutingSnapshot, deviceNow = Date.now()): OutingView {
	return {
		snapshot: s,
		members: new Map(s.members.map((m) => [m.user_id, m])),
		positions: new Map(s.positions.map((p) => [p.user_id, p])),
		clockOffsetMs: new Date(s.server_now).getTime() - deviceNow,
	};
}

/** A snapshot replaces what we had, but never moves a marker back to an older fix. */
export function mergeSnapshot(prev: OutingView | null, s: OutingSnapshot, deviceNow = Date.now()): OutingView {
	const next = fromSnapshot(s, deviceNow);
	if (!prev) return next;
	for (const [uid, p] of next.positions) {
		const old = prev.positions.get(uid);
		if (old && new Date(old.recorded_at) > new Date(p.recorded_at)) next.positions.set(uid, old);
	}
	return next;
}

function withMembers(v: OutingView, members: Map<string, Member>, positions = v.positions): OutingView {
	return { ...v, members, positions, snapshot: { ...v.snapshot, members: [...members.values()] } };
}

export function applyEvent(v: OutingView, e: LiveEvent): OutingView {
	switch (e.type) {
		case "position": {
			const p = e.position;
			if (!v.members.get(p.user_id)?.sharing) return v;
			if (v.snapshot.outing.status !== "active") return v;
			const old = v.positions.get(p.user_id);
			if (old && new Date(old.recorded_at) >= new Date(p.recorded_at)) return v;
			const positions = new Map(v.positions);
			positions.set(p.user_id, p);
			return { ...v, positions };
		}
		case "presence": {
			const m = v.members.get(e.user_id);
			if (!m) return v;
			const members = new Map(v.members);
			members.set(e.user_id, { ...m, online: e.online, away: e.away });
			return withMembers(v, members);
		}
		case "member_link": {
			const m = v.members.get(e.user_id);
			if (!m) return v;
			const members = new Map(v.members);
			/* Older servers send no battery field: keep what we had rather than blanking it. */
			members.set(e.user_id, { ...m, last_seen_at: e.last_seen_at, gps: e.gps, online: true, ...(e.battery !== undefined ? { battery: e.battery } : {}) });
			return withMembers(v, members);
		}
		case "member_note": {
			const m = v.members.get(e.user_id);
			if (!m) return v;
			const members = new Map(v.members);
			members.set(e.user_id, { ...m, note: e.note });
			return withMembers(v, members);
		}
		case "sos": {
			const m = v.members.get(e.user_id);
			if (!m) return v;
			const members = new Map(v.members);
			members.set(e.user_id, { ...m, sos: e.sos });
			return withMembers(v, members);
		}
		case "rally":
			return { ...v, snapshot: { ...v.snapshot, outing: { ...v.snapshot.outing, rally: e.rally } } };
		case "member_joined": {
			const members = new Map(v.members);
			members.set(e.member.user_id, { ...e.member, joined_at: new Date().toISOString(), online: false });
			return withMembers(v, members);
		}
		case "member_updated": {
			const m = v.members.get(e.member.user_id);
			if (!m) return v;
			const members = new Map(v.members);
			members.set(m.user_id, { ...m, ...e.member });
			return withMembers(v, members);
		}
		case "member_left": {
			const members = new Map(v.members);
			members.delete(e.user_id);
			const positions = new Map(v.positions);
			positions.delete(e.user_id);
			return withMembers(v, members, positions);
		}
		case "member_sharing": {
			const m = v.members.get(e.user_id);
			if (!m) return v;
			const members = new Map(v.members);
			members.set(e.user_id, { ...m, sharing: e.sharing });
			const positions = new Map(v.positions);
			if (!e.sharing) positions.delete(e.user_id);
			const me = e.user_id === v.snapshot.me.user_id ? { ...v.snapshot.me, sharing: e.sharing } : v.snapshot.me;
			const next = withMembers(v, members, positions);
			return { ...next, snapshot: { ...next.snapshot, me } };
		}
		case "owner_changed": {
			const members = new Map(v.members);
			for (const [id, m] of members) members.set(id, { ...m, role: id === e.owner_id ? "owner" : "member" });
			const next = withMembers(v, members);
			const me = { ...v.snapshot.me, role: e.owner_id === v.snapshot.me.user_id ? ("owner" as const) : ("member" as const) };
			return { ...next, snapshot: { ...next.snapshot, me, outing: { ...next.snapshot.outing, owner_id: e.owner_id } } };
		}
		case "outing_status": {
			const outing = { ...v.snapshot.outing, status: e.status };
			/* Paused or ended: the server deleted every fix; so do we. */
			const positions = e.status === "active" ? v.positions : new Map<string, Position>();
			return { ...v, positions, snapshot: { ...v.snapshot, outing } };
		}
		default:
			return v;
	}
}

export function serverNow(v: OutingView, deviceNow = Date.now()): number {
	return deviceNow + v.clockOffsetMs;
}

/** Time since the server last heard this member at all; null when unknown. */
export function lastSeenAgeMs(v: OutingView, m: Member, deviceNow = Date.now()): number | null {
	if (!m.last_seen_at) return null;
	return Math.max(0, serverNow(v, deviceNow) - new Date(m.last_seen_at).getTime());
}

export function positionAgeMs(v: OutingView, p: Position, deviceNow = Date.now()): number {
	return Math.max(0, serverNow(v, deviceNow) - new Date(p.recorded_at).getTime());
}
