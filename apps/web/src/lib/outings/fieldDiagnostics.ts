/**
 * «وضع الاختبار الميداني» — on-device field diagnostics for shared outings.
 *
 * Opt-in. Records only counts, durations, latencies and buckets — never a
 * coordinate, a name, a token or a timestamp of day. It lives in this phone's
 * localStorage until the person exports it as a JSON file or wipes it; sending
 * the aggregates to the server is a second, separate choice.
 *
 * The recorder is a plain serialisable object driven by explicit `now` values,
 * so it is deterministic under test and survives a page reload mid-drive.
 *
 * Report shape is pinned by docs/field-test/sample-diagnostics.json, which the
 * API validator test and this module's test both read.
 */

export const DIAG_SCHEMA = "sary.field-diagnostics/1";

/** Caps keep a 10-hour drive bounded (~2.5 s per fix at the fastest tier is 14 400). */
export const MAX_SAMPLES = 20_000;
/** A gap longer than this between peer samples is a hidden screen, not time watched. */
const PEER_GAP_CAP_MS = 30_000;
/** Battery drain is only reported after this much time on battery. */
export const MIN_DISCHARGE_MS = 10 * 60_000;

export type DiagLinkState = "connecting" | "live" | "polling" | "offline" | "closed";
export type Transport = "ws" | "http";
export type RejectReason = "accuracy" | "out_of_order" | "glitch" | "too_old";
export type AccuracyBucket = "le10" | "le30" | "le60" | "le150" | "gt150" | "unknown";

export type DiagState = {
	v: 1;
	platform: string;
	browser: string;
	standalone: boolean;
	mode: string;
	sessions: number;
	elapsedMs: number;
	lastAt: number | null;
	visible: boolean;
	visibleMs: number;
	hiddenMs: number;
	link: DiagLinkState;
	linkSince: number | null;
	stateMs: Record<DiagLinkState, number>;
	everLive: boolean;
	sessionStart: number | null;
	connectMs: number[];
	outageStart: number | null;
	reconnectMs: number[];
	sends: { ws: number; http: number };
	acks: { ok: number; refused: number };
	refusedBy: Record<string, number>;
	ackMs: number[];
	fixes: { seen: number; accepted: number; sent: number };
	rejected: Record<RejectReason, number>;
	accuracy: Record<AccuracyBucket, number>;
	accuracySamples: number[];
	battery: {
		supported: boolean;
		first: number | null;
		last: number | null;
		lastCharging: boolean | null;
		lastAt: number | null;
		dischargeMs: number;
		dischargePct: number;
		chargingMs: number;
	};
	wake: { supported: boolean; acquired: number; lost: number; failed: number };
	peers: { max: number; live: number; recent: number; lost: number; lastAt: number | null; last: { live: number; recent: number; lost: number } | null };
	dropped: number;
};

export function detectDevice(ua: string, standalone = false): { platform: string; browser: string; standalone: boolean } {
	const s = ua.toLowerCase();
	const platform = /iphone|ipad|ipod/.test(s) || (/macintosh/.test(s) && /mobile/.test(s))
		? "ios"
		: /android/.test(s)
			? "android"
			: /windows|macintosh|linux|cros/.test(s)
				? "desktop"
				: "other";
	const browser = /samsungbrowser/.test(s)
		? "samsung"
		: /crios|chrome|chromium/.test(s) && !/edg/.test(s)
			? "chrome"
			: /fxios|firefox/.test(s)
				? "firefox"
				: /safari/.test(s)
					? "safari"
					: "other";
	return { platform, browser, standalone };
}

export function createDiagState(device: { platform: string; browser: string; standalone: boolean }, mode: string): DiagState {
	return {
		v: 1,
		...device,
		mode,
		sessions: 0,
		elapsedMs: 0,
		lastAt: null,
		visible: true,
		visibleMs: 0,
		hiddenMs: 0,
		link: "connecting",
		linkSince: null,
		stateMs: { connecting: 0, live: 0, polling: 0, offline: 0, closed: 0 },
		everLive: false,
		sessionStart: null,
		connectMs: [],
		outageStart: null,
		reconnectMs: [],
		sends: { ws: 0, http: 0 },
		acks: { ok: 0, refused: 0 },
		refusedBy: {},
		ackMs: [],
		fixes: { seen: 0, accepted: 0, sent: 0 },
		rejected: { accuracy: 0, out_of_order: 0, glitch: 0, too_old: 0 },
		accuracy: { le10: 0, le30: 0, le60: 0, le150: 0, gt150: 0, unknown: 0 },
		accuracySamples: [],
		battery: { supported: false, first: null, last: null, lastCharging: null, lastAt: null, dischargeMs: 0, dischargePct: 0, chargingMs: 0 },
		wake: { supported: false, acquired: 0, lost: 0, failed: 0 },
		peers: { max: 0, live: 0, recent: 0, lost: 0, lastAt: null, last: null },
		dropped: 0,
	};
}

function push(s: DiagState, arr: number[], v: number) {
	if (!Number.isFinite(v)) return;
	if (arr.length >= MAX_SAMPLES) {
		s.dropped += 1;
		return;
	}
	arr.push(Math.max(0, Math.round(v)));
}

/** Advance the clocks (elapsed, visible/hidden, link state) to `now`; returns `now`, never earlier than the last. */
function tick(s: DiagState, at: number): number {
	const now = s.lastAt != null ? Math.max(at, s.lastAt) : at;
	if (s.lastAt != null && now > s.lastAt) {
		const dt = now - s.lastAt;
		s.elapsedMs += dt;
		if (s.visible) s.visibleMs += dt;
		else s.hiddenMs += dt;
	}
	if (s.linkSince != null && now > s.linkSince) {
		s.stateMs[s.link] += now - s.linkSince;
		s.linkSince = now;
	}
	if (s.lastAt == null || now > s.lastAt) s.lastAt = now;
	return now;
}

/**
 * The recorder. Every method takes `now` (ms, any monotonic-enough clock) and
 * mutates the state in place; `report()` turns it into the exportable numbers.
 */
export const diag = {
	/** A new screen session (first open, or after a reload). Gaps between sessions are not counted. */
	startSession(s: DiagState, now: number, mode?: string) {
		s.sessions += 1;
		s.lastAt = now;
		s.link = "connecting";
		s.linkSince = now;
		s.sessionStart = now;
		s.everLive = false;
		s.outageStart = null;
		s.peers.lastAt = null;
		s.peers.last = null;
		s.battery.lastAt = null;
		if (mode) s.mode = mode;
	},

	endSession(s: DiagState, now: number) {
		tick(s, now);
		s.linkSince = null;
		s.lastAt = null;
		s.outageStart = null;
	},

	setMode(s: DiagState, mode: string) {
		s.mode = mode;
	},

	visibility(s: DiagState, visible: boolean, now: number) {
		tick(s, now);
		s.visible = visible;
		if (!visible) s.peers.lastAt = null;
	},

	link(s: DiagState, next: DiagLinkState, at: number) {
		const now = tick(s, at);
		if (s.linkSince == null) s.linkSince = now;
		const prev = s.link;
		if (prev === next) return;
		s.link = next;
		s.linkSince = now;
		if (next === "live") {
			if (!s.everLive && s.sessionStart != null) push(s, s.connectMs, now - s.sessionStart);
			else if (s.outageStart != null) push(s, s.reconnectMs, now - s.outageStart);
			s.everLive = true;
			s.outageStart = null;
		} else if (prev === "live" && next !== "closed") {
			s.outageStart = now;
		} else if (next === "closed") {
			s.outageStart = null;
		}
	},

	/** A raw fix from the device, before any filter. */
	fixSeen(s: DiagState, accuracy: number | null | undefined, now: number) {
		tick(s, now);
		s.fixes.seen += 1;
		const a = accuracy == null || !Number.isFinite(accuracy) ? null : accuracy;
		const b: AccuracyBucket = a == null ? "unknown" : a <= 10 ? "le10" : a <= 30 ? "le30" : a <= 60 ? "le60" : a <= 150 ? "le150" : "gt150";
		s.accuracy[b] += 1;
		if (a != null) push(s, s.accuracySamples, a);
	},

	fixAccepted(s: DiagState) {
		s.fixes.accepted += 1;
	},

	fixRejected(s: DiagState, reason: RejectReason) {
		s.rejected[reason] += 1;
	},

	/** The send policy decided to send this fix (it may still be dropped as too old). */
	fixSent(s: DiagState) {
		s.fixes.sent += 1;
	},

	/** A fix actually left the device. */
	sendAttempt(s: DiagState, transport: Transport, now: number) {
		tick(s, now);
		s.sends[transport] += 1;
	},

	ack(s: DiagState, ok: boolean, reason: string | undefined, latencyMs: number | null, now: number) {
		tick(s, now);
		if (ok) s.acks.ok += 1;
		else {
			s.acks.refused += 1;
			const r = safeReason(reason);
			if (Object.keys(s.refusedBy).length < 16 || r in s.refusedBy) s.refusedBy[r] = (s.refusedBy[r] ?? 0) + 1;
		}
		if (latencyMs != null) push(s, s.ackMs, latencyMs);
	},

	battery(s: DiagState, level: number, charging: boolean, now: number) {
		if (!Number.isFinite(level)) return;
		const b = s.battery;
		const pct = Math.max(0, Math.min(100, level * 100));
		b.supported = true;
		if (b.first == null) b.first = pct;
		if (b.lastAt != null && b.last != null && b.lastCharging != null && now > b.lastAt) {
			const dt = now - b.lastAt;
			if (!b.lastCharging && !charging) {
				b.dischargeMs += dt;
				b.dischargePct += Math.max(0, b.last - pct);
			} else if (b.lastCharging) {
				b.chargingMs += dt;
			}
		}
		b.last = pct;
		b.lastCharging = charging;
		b.lastAt = now;
	},

	wake(s: DiagState, ev: "supported" | "acquired" | "lost" | "failed") {
		if (ev === "supported") s.wake.supported = true;
		else s.wake[ev] += 1;
	},

	/** How the others look on this screen right now (counts only). */
	peers(s: DiagState, counts: { live: number; recent: number; lost: number }, now: number) {
		const p = s.peers;
		if (!s.visible) {
			p.lastAt = null;
			return;
		}
		p.max = Math.max(p.max, counts.live + counts.recent + counts.lost);
		if (p.lastAt != null && p.last && now > p.lastAt) {
			const dt = Math.min(PEER_GAP_CAP_MS, now - p.lastAt);
			p.live += p.last.live * dt;
			p.recent += p.last.recent * dt;
			p.lost += p.last.lost * dt;
		}
		p.lastAt = now;
		p.last = { ...counts };
	},
};

function safeReason(r: string | undefined): string {
	const v = String(r || "refused").toLowerCase();
	return /^[a-z_]{1,32}$/.test(v) ? v : "other";
}

/** Nearest-rank percentile of an unsorted list; null when empty. */
export function percentile(values: readonly number[], p: number): number | null {
	if (!values.length) return null;
	const sorted = [...values].sort((a, b) => a - b);
	const rank = Math.ceil((p / 100) * sorted.length);
	return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

export type Dist = { count: number; p50: number | null; p90: number | null; p95: number | null; p99: number | null; max: number | null; mean: number | null };

export function summarize(values: readonly number[]): Dist {
	if (!values.length) return { count: 0, p50: null, p90: null, p95: null, p99: null, max: null, mean: null };
	let max = -Infinity;
	let sum = 0;
	for (const v of values) {
		sum += v;
		if (v > max) max = v;
	}
	return {
		count: values.length,
		p50: percentile(values, 50),
		p90: percentile(values, 90),
		p95: percentile(values, 95),
		p99: percentile(values, 99),
		max,
		mean: Math.round(sum / values.length),
	};
}

const round1 = (n: number) => Math.round(n * 10) / 10;

export type DiagReport = ReturnType<typeof buildReport>;

/** The exportable, privacy-safe summary. Numbers and small enums only. */
export function buildReport(src: DiagState, now: number | null = null) {
	/* Never mutate the live state to report it. */
	const s: DiagState = JSON.parse(JSON.stringify(src));
	if (now != null && s.lastAt != null) tick(s, now);
	const attempts = s.sends.ws + s.sends.http;
	const acked = s.acks.ok + s.acks.refused;
	const b = s.battery;
	const hours = b.dischargeMs / 3_600_000;
	const watched = s.peers.live + s.peers.recent + s.peers.lost;
	return {
		schema: DIAG_SCHEMA,
		app: { platform: s.platform, browser: s.browser, standalone: s.standalone },
		mode: s.mode,
		sessions: s.sessions,
		duration_ms: s.elapsedMs,
		visible_ms: s.visibleMs,
		hidden_ms: s.hiddenMs,
		link_ms: {
			connecting: s.stateMs.connecting,
			live: s.stateMs.live,
			polling: s.stateMs.polling,
			offline: s.stateMs.offline,
		},
		sends: {
			attempts,
			ws: s.sends.ws,
			http: s.sends.http,
			acked_ok: s.acks.ok,
			refused: s.acks.refused,
			unacked: Math.max(0, attempts - acked),
			refused_by_reason: { ...s.refusedBy },
		},
		ack_latency_ms: summarize(s.ackMs),
		connect_ms: summarize(s.connectMs),
		reconnects: { ...summarize(s.reconnectMs), total_ms: s.reconnectMs.reduce((a, v) => a + v, 0) },
		fixes: {
			seen: s.fixes.seen,
			accepted: s.fixes.accepted,
			sent: s.fixes.sent,
			rejected: { ...s.rejected },
		},
		accuracy_m: { buckets: { ...s.accuracy }, p50: percentile(s.accuracySamples, 50), p95: percentile(s.accuracySamples, 95) },
		battery: {
			supported: b.supported,
			start_pct: b.first == null ? null : round1(b.first),
			end_pct: b.last == null ? null : round1(b.last),
			discharge_ms: b.dischargeMs,
			charging_ms: b.chargingMs,
			drain_pct_per_hour: b.dischargeMs >= MIN_DISCHARGE_MS ? round1(b.dischargePct / hours) : null,
		},
		wake_lock: { ...s.wake },
		peers: {
			max_members: s.peers.max,
			live_ms: Math.round(s.peers.live),
			recent_ms: Math.round(s.peers.recent),
			lost_ms: Math.round(s.peers.lost),
			live_share: watched > 0 ? Math.round((s.peers.live / watched) * 1000) / 1000 : null,
		},
		samples_dropped: s.dropped,
	};
}

/* ---------- storage (this device only) ---------- */

const FLAG_KEY = "sary.fieldTest.on";
const DATA_PREFIX = "sary.fieldTest.data.";

type Store = { get(k: string): string | null; set(k: string, v: string): unknown; remove(k: string): unknown };

export function isFieldTestOn(store: Store): boolean {
	return store.get(FLAG_KEY) === "1";
}

export function setFieldTestOn(store: Store, on: boolean): void {
	store.set(FLAG_KEY, on ? "1" : "0");
}

export function loadDiag(store: Store, outingId: string): DiagState | null {
	try {
		const raw = store.get(DATA_PREFIX + outingId);
		if (!raw) return null;
		const s = JSON.parse(raw) as DiagState;
		return s && s.v === 1 ? s : null;
	} catch {
		return null;
	}
}

export function saveDiag(store: Store, outingId: string, s: DiagState): void {
	store.set(DATA_PREFIX + outingId, JSON.stringify(s));
}

export function clearDiag(store: Store, outingId: string): void {
	store.remove(DATA_PREFIX + outingId);
}

export function exportFileName(date = new Date()): string {
	const d = date.toISOString().slice(0, 10);
	return `sary-field-test-${d}-${Math.random().toString(36).slice(2, 6)}.json`;
}
