/**
 * When to send a fix, and how to describe someone else's — tuned for off-road
 * driving: 140 km/h on asphalt, walking pace on dunes, long gaps in coverage.
 *
 * Starting values from the field-design review (2026-11-03). They are
 * engineering defaults to calibrate on a real desert run, not published
 * standards.
 *
 * Three things are never mixed:
 *   fix         where the device says it is (and how sure it is)
 *   connection  whether it can talk to us now (heartbeats)
 *   freshness   how old the last real fix is
 */

import { haversineMeters } from "../sary/domain";

export type ShareMode = "precise" | "balanced" | "saver";

export type Tier = { intervalMs: number; distanceM: number };

/** Speed tiers, m/s. */
export const FAST_MPS = 25; // 90 km/h
export const SLOW_MPS = 5.5; // 20 km/h
export const STILL_MPS = 1.5;

/** While moving: send every `intervalMs` or every `distanceM`, whichever comes first. */
const TIERS = {
	fast: { intervalMs: 2_500, distanceM: 50 },
	normal: { intervalMs: 4_000, distanceM: 35 },
	slow: { intervalMs: 6_000, distanceM: 15 },
} as const;

/** Never two fixes closer than this, whatever the tier. */
export const SEND_FLOOR_MS = 1_000;

/** The person's choice scales the tiers: saver halves the rate, precise speeds it up. */
const MODE_SCALE: Record<ShareMode, number> = { precise: 0.6, balanced: 1, saver: 2 };

export function tierFor(speedMps: number | null | undefined, mode: ShareMode = "balanced"): Tier {
	const s = speedMps ?? 0;
	const base = s >= FAST_MPS ? TIERS.fast : s >= SLOW_MPS ? TIERS.normal : TIERS.slow;
	const k = MODE_SCALE[mode];
	return { intervalMs: Math.round(base.intervalMs * k), distanceM: Math.round(base.distanceM * k) };
}

/** Parked: a fresh real fix this often, so others still see you as there. */
export function heartbeatMs(mode: ShareMode = "balanced"): number {
	return mode === "saver" ? 60_000 : 30_000;
}

/** Connection heartbeat (no coordinates) — separate from fixes. */
export const LINK_HEARTBEAT_MS = 15_000;

/** Accuracy grades. */
export const GOOD_ACCURACY_M = 30;
export const WEAK_ACCURACY_M = 60;
/** Worse than this, the fix is not sent at all. */
export const SEND_MAX_ACCURACY_M = 150;

export type AccuracyGrade = "good" | "fair" | "poor";

export function accuracyGrade(m: number | null | undefined): AccuracyGrade {
	if (m == null || !Number.isFinite(m)) return "fair";
	if (m <= GOOD_ACCURACY_M) return "good";
	if (m <= WEAK_ACCURACY_M) return "fair";
	return "poor";
}

export type DeviceFix = {
	lat: number;
	lng: number;
	accuracy: number | null;
	heading: number | null;
	speed: number | null;
	/** Device timestamp of the fix (ms). */
	at: number;
};

/** Speed the movement implies, after giving both fixes the benefit of their error. */
export function impliedSpeedMps(a: DeviceFix, b: DeviceFix): number {
	const dt = (b.at - a.at) / 1000;
	if (dt <= 0) return Infinity;
	const slack = (a.accuracy ?? 0) + (b.accuracy ?? 0);
	return Math.max(0, haversineMeters(a, b) - slack) / dt;
}

/** Above this, a jump is a GPS glitch until the next fix agrees (~200 km/h). */
export const MAX_PLAUSIBLE_MPS = 55;

/**
 * Holds back an implausible jump until the next fix confirms it, so one bad
 * reading never moves you across the dunes on everyone's map.
 */
export class FixFilter {
	private trusted: DeviceFix | null = null;
	private suspect: DeviceFix | null = null;
	/** Why the last `accept` returned null (for the field diagnostics); null after an accept. */
	lastReject: "accuracy" | "out_of_order" | "glitch" | null = null;

	accept(fix: DeviceFix): DeviceFix | null {
		this.lastReject = null;
		if (fix.accuracy != null && fix.accuracy > SEND_MAX_ACCURACY_M) {
			this.lastReject = "accuracy";
			return null;
		}
		if (this.trusted && fix.at <= this.trusted.at) {
			this.lastReject = "out_of_order";
			return null;
		}
		/* No reference, or the reference is too old to judge a jump by. */
		if (!this.trusted || fix.at - this.trusted.at > 120_000) return this.trust(fix);
		if (impliedSpeedMps(this.trusted, fix) <= MAX_PLAUSIBLE_MPS) return this.trust(fix);
		/* Implausible from the trusted fix — but if it agrees with the previous suspect, the jump was real. */
		if (this.suspect && impliedSpeedMps(this.suspect, fix) <= MAX_PLAUSIBLE_MPS) return this.trust(fix);
		this.suspect = fix;
		this.lastReject = "glitch";
		return null;
	}

	private trust(fix: DeviceFix): DeviceFix {
		this.trusted = fix;
		this.suspect = null;
		return fix;
	}

	reset(): void {
		this.trusted = null;
		this.suspect = null;
	}
}

export function shouldSend(
	fix: DeviceFix,
	last: { fix: DeviceFix; sentAt: number } | null,
	mode: ShareMode,
	now = Date.now(),
): boolean {
	if (fix.accuracy != null && fix.accuracy > SEND_MAX_ACCURACY_M) return false;
	if (!last) return true;
	if (fix.at <= last.fix.at) return false;
	const since = now - last.sentAt;
	if (since < SEND_FLOOR_MS) return false;
	const tier = tierFor(fix.speed, mode);
	const moved = haversineMeters(last.fix, fix);
	if (moved >= tier.distanceM) return true;
	const moving = (fix.speed ?? 0) >= STILL_MPS || moved >= Math.max(10, fix.accuracy ?? 0);
	if (moving && since >= tier.intervalMs) return true;
	return since >= heartbeatMs(mode);
}

/**
 *   live     a real fix recent enough for its motion (15 s moving, 45 s parked)
 *   recent   reachable, but the last fix is older — «آخر موقع معروف»
 *   lost     nothing heard for 60 s — «انقطع الاتصال»
 */
export type Freshness = "live" | "recent" | "lost";

export const LIVE_MOVING_MS = 15_000;
/** Parked phones get a fresh fix every 30 s; a parked position does not go stale by standing still. */
export const LIVE_PARKED_MS = 45_000;
export const CONNECTION_LOST_MS = 60_000;

export function freshness({
	fixAgeMs,
	speedMps,
	lastSeenAgeMs,
}: {
	fixAgeMs: number;
	speedMps: number | null | undefined;
	/** Time since the server last heard anything from this person; null if unknown. */
	lastSeenAgeMs: number | null;
}): Freshness {
	const seenAge = Math.min(lastSeenAgeMs ?? Infinity, fixAgeMs);
	const moving = (speedMps ?? 0) >= STILL_MPS;
	if (fixAgeMs <= (moving ? LIVE_MOVING_MS : LIVE_PARKED_MS)) return "live";
	return seenAge > CONNECTION_LOST_MS ? "lost" : "recent";
}

/** Initial bearing from a to b, degrees clockwise from north. */
export function bearingDeg(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
	const r = Math.PI / 180;
	const y = Math.sin((b.lng - a.lng) * r) * Math.cos(b.lat * r);
	const x =
		Math.cos(a.lat * r) * Math.sin(b.lat * r) -
		Math.sin(a.lat * r) * Math.cos(b.lat * r) * Math.cos((b.lng - a.lng) * r);
	return (Math.atan2(y, x) / r + 360) % 360;
}

const DIRS_AR = ["شمال", "شمال شرق", "شرق", "جنوب شرق", "جنوب", "جنوب غرب", "غرب", "شمال غرب"];
const DIRS_EN = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];

export function directionLabel(deg: number, isRTL: boolean): string {
	const i = Math.round((((deg % 360) + 360) % 360) / 45) % 8;
	return (isRTL ? DIRS_AR : DIRS_EN)[i];
}

/** GPS course only while really moving; a parked car gets no arrow. */
export const HEADING_MIN_SPEED_MPS = 3;

export function trustedHeading(heading: number | null | undefined, speed: number | null | undefined): number | null {
	if (heading == null || !Number.isFinite(heading)) return null;
	if (speed == null || !Number.isFinite(speed) || speed < HEADING_MIN_SPEED_MPS) return null;
	return ((heading % 360) + 360) % 360;
}

export function formatDistance(m: number, isRTL: boolean): string {
	if (m < 1000) {
		const v = Math.max(10, Math.round(m / 10) * 10);
		return isRTL ? `${v.toLocaleString("ar-SA")} م` : `${v} m`;
	}
	const km = m < 10_000 ? Math.round(m / 100) / 10 : Math.round(m / 1000);
	return isRTL ? `${km.toLocaleString("ar-SA")} كم` : `${km} km`;
}

export function formatAgo(ms: number, isRTL: boolean): string {
	const s = Math.max(0, Math.round(ms / 1000));
	if (s < 10) return isRTL ? "الآن" : "now";
	if (s < 60) return isRTL ? `قبل ${s.toLocaleString("ar-SA")} ث` : `${s}s ago`;
	const m = Math.round(s / 60);
	if (m < 60) return isRTL ? `قبل ${m.toLocaleString("ar-SA")} د` : `${m} min ago`;
	const h = Math.round(m / 60);
	return isRTL ? `قبل ${h.toLocaleString("ar-SA")} س` : `${h} h ago`;
}

export function initials(name: string): string {
	const parts = name.trim().split(/\s+/).filter(Boolean);
	return parts.slice(0, 2).map((p) => [...p][0]).join("") || "؟";
}
