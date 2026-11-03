/**
 * The group's last known picture, kept on this device while the outing is open.
 *
 * In the desert the network goes and comes back; a reload in a dead zone must
 * still show where everyone was last seen — with its age, never as live.
 * Wiped when the outing ends or you leave. Session storage: it dies with the tab.
 */

import { safeGet, safeRemove, safeSet } from "../safeStorage";
import type { OutingSnapshot } from "./api";
import { fromSnapshot, type OutingView } from "./outingState";

const key = (id: string) => `sary.outings.lastKnown.${id}`;

export function saveCachedView(outingId: string, v: OutingView): void {
	const snapshot: OutingSnapshot = {
		...v.snapshot,
		members: [...v.members.values()],
		positions: [...v.positions.values()],
		server_now: new Date(Date.now() + v.clockOffsetMs).toISOString(),
	};
	safeSet("sessionStorage", key(outingId), JSON.stringify({ savedAt: Date.now(), snapshot }));
}

export function loadCachedView(outingId: string, now = Date.now()): OutingView | null {
	try {
		const raw = safeGet("sessionStorage", key(outingId));
		if (!raw) return null;
		const { savedAt, snapshot } = JSON.parse(raw) as { savedAt: number; snapshot: OutingSnapshot };
		if (!snapshot?.outing?.id || snapshot.outing.id !== outingId) return null;
		/* Rebuild the clock offset from when it was saved, so ages keep counting honestly. */
		return fromSnapshot(snapshot, savedAt ?? now);
	} catch {
		return null;
	}
}

export function clearCachedView(outingId: string): void {
	safeRemove("sessionStorage", key(outingId));
}
