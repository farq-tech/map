/**
 * Moving a marker from where it is drawn to where the person really is.
 * Interpolation only, never extrapolation: the marker never goes past the last
 * real fix, so it is at most one update behind and never somewhere invented.
 */

export type LngLat = { lng: number; lat: number };

export const MAX_TWEEN_MS = 1_000;
/** Farther than this (a reconnect, a long gap) the marker jumps: a slide would be fiction. */
export const SNAP_DISTANCE_M = 2_000;

export function easeInOut(t: number): number {
	const x = Math.min(1, Math.max(0, t));
	return x < 0.5 ? 2 * x * x : 1 - (-2 * x + 2) ** 2 / 2;
}

export function lerp(a: LngLat, b: LngLat, t: number): LngLat {
	const k = easeInOut(t);
	return { lng: a.lng + (b.lng - a.lng) * k, lat: a.lat + (b.lat - a.lat) * k };
}

/** Tween length: the time since the previous fix, capped, so a slow sender glides and a fast one keeps up. */
export function tweenMs(gapMs: number, distanceM: number, reducedMotion: boolean): number {
	if (reducedMotion || distanceM > SNAP_DISTANCE_M || !Number.isFinite(gapMs)) return 0;
	return Math.min(MAX_TWEEN_MS, Math.max(300, gapMs * 0.5));
}
