/**
 * A short fading line behind each car: the last ~2 minutes of that person's
 * real fixes, in their colour.
 *
 * Held in memory on this device only — never stored, never sent. Only real,
 * confident fixes go in: no approximate fix, no interpolated or animated point.
 * A long silence breaks the line rather than drawing a straight jump across
 * ground nobody reported.
 */

export const TRAIL_MS = 2 * 60_000;
/** A gap longer than this between two fixes starts a new piece of line. */
export const TRAIL_GAP_MS = 45_000;
/** Cap per person (fast senders: 1 fix/s for 2 min). */
export const TRAIL_MAX_POINTS = 150;

export type TrailFix = {
	lng: number;
	lat: number;
	/** When the fix was taken, on this device's clock (ms). */
	at: number;
};

export type TrailInput = TrailFix & {
	/** Accuracy too poor to draw a line through. */
	approximate: boolean;
};

export class Trails {
	private byUser = new Map<string, TrailFix[]>();

	/** Adds a real fix; ignores approximate fixes, repeats and out-of-order ones. */
	add(userId: string, fix: TrailInput, now: number): void {
		if (fix.approximate || !Number.isFinite(fix.lng) || !Number.isFinite(fix.lat)) return;
		if (now - fix.at > TRAIL_MS) return;
		const list = this.byUser.get(userId) || [];
		const last = list[list.length - 1];
		if (last && fix.at <= last.at) return;
		if (last && last.lng === fix.lng && last.lat === fix.lat) {
			/* Parked: same place again — keep one point, just newer. */
			last.at = fix.at;
		} else {
			list.push({ lng: fix.lng, lat: fix.lat, at: fix.at });
		}
		if (list.length > TRAIL_MAX_POINTS) list.splice(0, list.length - TRAIL_MAX_POINTS);
		this.byUser.set(userId, list);
	}

	/** Forget one person (left, removed, paused sharing). */
	clear(userId: string): void {
		this.byUser.delete(userId);
	}

	/** Forget everyone (outing paused or ended, screen closed). */
	clearAll(): void {
		this.byUser.clear();
	}

	/** Keeps only the people still allowed on the map. */
	retain(userIds: Iterable<string>): void {
		const keep = new Set(userIds);
		for (const id of [...this.byUser.keys()]) if (!keep.has(id)) this.byUser.delete(id);
	}

	/** Drops points older than the window. */
	prune(now: number): void {
		for (const [id, list] of this.byUser) {
			const kept = list.filter((p) => now - p.at <= TRAIL_MS);
			if (kept.length) this.byUser.set(id, kept);
			else this.byUser.delete(id);
		}
	}

	points(userId: string): readonly TrailFix[] {
		return this.byUser.get(userId) || [];
	}

	users(): string[] {
		return [...this.byUser.keys()];
	}

	/**
	 * One feature per pair of consecutive fixes, so each piece fades by its own
	 * age (newest opaque, two minutes old gone).
	 */
	features(now: number, colorOf: (userId: string) => string): GeoJSON.FeatureCollection<GeoJSON.LineString> {
		const features: GeoJSON.Feature<GeoJSON.LineString>[] = [];
		for (const [id, list] of this.byUser) {
			const color = colorOf(id);
			for (let i = 1; i < list.length; i += 1) {
				const a = list[i - 1];
				const b = list[i];
				if (b.at - a.at > TRAIL_GAP_MS) continue;
				const age = now - b.at;
				if (age > TRAIL_MS) continue;
				features.push({
					type: "Feature",
					properties: { user: id, color, opacity: trailOpacity(age) },
					geometry: { type: "LineString", coordinates: [[a.lng, a.lat], [b.lng, b.lat]] },
				});
			}
		}
		return { type: "FeatureCollection", features };
	}
}

/** 0.85 for a fresh piece, fading to 0 at the end of the window. */
export function trailOpacity(ageMs: number): number {
	const k = 1 - Math.min(1, Math.max(0, ageMs) / TRAIL_MS);
	return Math.round(0.85 * k * 100) / 100;
}
