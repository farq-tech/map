/**
 * The live link to one outing.
 *
 *   WebSocket first (auth in the first frame), reconnecting with capped
 *   exponential backoff + jitter. If sockets never get through — a proxy that
 *   strips upgrades, a captive network, a host that cannot carry them — fall
 *   back to HTTP polling and keep retrying the socket quietly in the back.
 *
 * Only the latest fix is ever kept while disconnected: an old position sent
 * late is not news, and the server refuses fixes older than 60 s anyway.
 */

import { API_BASE_URL } from "../api";
import { OutingApiError, OutingsApi, type GpsState, type Member, type MemberNote, type OutingSnapshot, type Position } from "./api";
import type { DeviceFix, ShareMode } from "./policy";

export type LiveState = "connecting" | "live" | "polling" | "offline" | "closed";

export type LiveEvent =
	| { type: "position"; position: Position }
	| { type: "presence"; user_id: string; online: boolean; away: boolean }
	| { type: "member_joined"; member: Member }
	| { type: "member_updated"; member: Pick<Member, "user_id" | "display_name" | "avatar" | "phone"> }
	| { type: "member_left"; user_id: string; reason: "left" | "removed" }
	| { type: "member_sharing"; user_id: string; sharing: boolean }
	| { type: "owner_changed"; owner_id: string }
	| { type: "member_link"; user_id: string; last_seen_at: string; gps: GpsState | null }
	| { type: "member_note"; user_id: string; note: MemberNote | null }
	| { type: "outing_status"; status: OutingSnapshot["outing"]["status"] };

export type ClosedReason = "outing_ended" | "removed" | "left" | "not_a_member" | "unauthorized" | "replaced";

export type AckReason = string | undefined;

/** Counts and timings only, for the opt-in field diagnostics — never a coordinate. */
export type ChannelDiagEvent =
	| { kind: "send"; transport: "ws" | "http" }
	| { kind: "ack"; transport: "ws" | "http"; ok: boolean; reason: AckReason; latencyMs: number | null }
	| { kind: "drop"; reason: "too_old" };

type Handlers = {
	onSnapshot: (s: OutingSnapshot) => void;
	onEvent: (e: LiveEvent) => void;
	onState: (s: LiveState) => void;
	onClosed: (reason: ClosedReason) => void;
	onAck?: (ok: boolean, reason: AckReason) => void;
	onDiag?: (e: ChannelDiagEvent) => void;
};

type Deps = {
	WebSocketImpl?: typeof WebSocket;
	poll?: (id: string) => Promise<OutingSnapshot>;
	beat?: (id: string, gps: GpsState) => Promise<unknown>;
	post?: (id: string, fix: unknown) => Promise<unknown>;
	now?: () => number;
	setTimeout?: typeof setTimeout;
	clearTimeout?: typeof clearTimeout;
	online?: () => boolean;
};

const TERMINAL_CODES: Record<number, ClosedReason> = {
	4401: "unauthorized",
	4403: "removed",
	4404: "not_a_member",
	4409: "replaced",
	4410: "outing_ended",
};

export const BACKOFF_BASE_MS = 1_000;
export const BACKOFF_MAX_MS = 30_000;
/** Socket attempts that never reached `ready` before we start polling. */
export const FAILS_BEFORE_POLLING = 3;
export const POLL_MS = 4_000;
/** No frame at all for this long means a half-open socket. */
export const SILENCE_MS = 45_000;
export const PING_MS = 20_000;

export function backoffMs(attempt: number, rand = Math.random()): number {
	const cap = Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** Math.max(0, attempt));
	/* "Equal jitter": never zero, never the whole cap for everyone at once. */
	return Math.round(cap / 2 + (cap / 2) * rand);
}

/**
 * The deployed web app is served by Vercel, whose rewrites (vercel.json) proxy
 * /api to the Railway API but cannot carry a WebSocket. On those hosts the
 * socket goes straight to the same Railway API vercel.json already names.
 */
export const DEPLOYED_API_WS = "wss://api-production-ddc84.up.railway.app/api/outings/live";

export function liveSocketUrl(): string {
	const explicit = import.meta.env?.VITE_LIVE_WS_URL;
	if (explicit && String(explicit).trim()) return String(explicit).trim();
	if (typeof window !== "undefined" && window.location.hostname.endsWith(".vercel.app")) return DEPLOYED_API_WS;
	const base = API_BASE_URL || (typeof window !== "undefined" ? window.location.origin : "");
	return `${base.replace(/^http/, "ws")}/api/outings/live`;
}

/** Serialise a device fix for the wire. Age is measured on this device's clock, now. */
export function wireFix(fix: DeviceFix, mode: ShareMode, now = Date.now()) {
	return {
		lat: fix.lat,
		lng: fix.lng,
		accuracy: fix.accuracy,
		heading: fix.heading,
		speed: fix.speed,
		mode,
		age_ms: Math.max(0, now - fix.at),
	};
}

export class LiveChannel {
	state: LiveState = "connecting";
	private ws: WebSocket | null = null;
	private attempts = 0;
	private everReady = false;
	private stopped = false;
	private retryTimer: ReturnType<typeof setTimeout> | null = null;
	private pollTimer: ReturnType<typeof setTimeout> | null = null;
	private pingTimer: ReturnType<typeof setTimeout> | null = null;
	private lastFrameAt = 0;
	private pending: { fix: DeviceFix; mode: ShareMode } | null = null;
	private seq = 0;
	/** seq → send time, for ack latency. Bounded: acks for very old frames are not news. */
	private inflight = new Map<number, number>();
	private away = false;
	private wasPolling = false;
	private deps: Required<Deps>;

	constructor(
		private outingId: string,
		private token: string,
		private h: Handlers,
		deps: Deps = {},
		private url = liveSocketUrl(),
	) {
		this.deps = {
			WebSocketImpl: deps.WebSocketImpl ?? (typeof WebSocket !== "undefined" ? WebSocket : (undefined as never)),
			poll: deps.poll ?? OutingsApi.poll,
			beat: deps.beat ?? OutingsApi.heartbeat,
			post: deps.post ?? OutingsApi.sendPosition,
			now: deps.now ?? Date.now,
			setTimeout: deps.setTimeout ?? setTimeout.bind(globalThis),
			clearTimeout: deps.clearTimeout ?? clearTimeout.bind(globalThis),
			online: deps.online ?? (() => (typeof navigator === "undefined" ? true : navigator.onLine !== false)),
		};
	}

	start(): void {
		if (typeof window !== "undefined") {
			window.addEventListener("online", this.onOnline);
			window.addEventListener("offline", this.onOffline);
		}
		this.connect();
	}

	stop(): void {
		this.stopped = true;
		this.pending = null;
		if (typeof window !== "undefined") {
			window.removeEventListener("online", this.onOnline);
			window.removeEventListener("offline", this.onOffline);
		}
		this.clearTimers();
		const ws = this.ws;
		this.ws = null;
		try {
			ws?.close(1000, "bye");
		} catch {
			/* */
		}
		this.setState("closed");
	}

	/** Send now if we can; otherwise keep it as the one pending fix. */
	sendFix(fix: DeviceFix, mode: ShareMode): void {
		if (this.stopped) return;
		this.pending = { fix, mode };
		this.flush();
	}

	/** "Still here", with no coordinates — kept apart from fixes so others can tell no-GPS from no-network. */
	heartbeat(gps: GpsState): void {
		if (this.stopped) return;
		if (this.state === "live") this.sendFrame({ type: "heartbeat", gps });
		else if (this.state === "polling") this.deps.beat(this.outingId, gps).catch(() => undefined);
	}

	setAway(away: boolean): void {
		this.away = away;
		this.sendFrame({ type: "presence", away });
		if (!away && this.state === "offline" && this.deps.online()) this.reconnectNow();
	}

	private onOnline = () => {
		if (this.stopped) return;
		this.reconnectNow();
	};

	private onOffline = () => {
		if (this.stopped) return;
		this.setState("offline");
	};

	reconnectNow(): void {
		if (this.stopped) return;
		this.attempts = 0;
		this.clearRetry();
		/* Sockets never worked on this network: keep the fallback going while we retry. */
		if (this.wasPolling && !this.everReady) this.startPolling();
		/* A healthy live socket stays. Anything else — including a socket that
		 * looked open through an outage — is replaced: it may be half-dead. */
		if (this.ws && this.ws.readyState <= 1 && this.state === "live") return;
		const old = this.ws;
		this.ws = null;
		try {
			old?.close();
		} catch {
			/* */
		}
		this.connect();
	}

	private setState(s: LiveState) {
		if (this.state === s) return;
		this.state = s;
		this.h.onState(s);
	}

	private clearRetry() {
		if (this.retryTimer) this.deps.clearTimeout(this.retryTimer);
		this.retryTimer = null;
	}

	private clearTimers() {
		this.clearRetry();
		if (this.pollTimer) this.deps.clearTimeout(this.pollTimer);
		if (this.pingTimer) this.deps.clearTimeout(this.pingTimer);
		this.pollTimer = null;
		this.pingTimer = null;
	}

	private sendFrame(msg: unknown): boolean {
		if (!this.ws || this.ws.readyState !== 1 || this.state !== "live") return false;
		try {
			this.ws.send(JSON.stringify(msg));
			return true;
		} catch {
			return false;
		}
	}

	private flush() {
		const p = this.pending;
		if (!p) return;
		const fix = wireFix(p.fix, p.mode, this.deps.now());
		if (fix.age_ms > 55_000) {
			this.pending = null; // too old to be worth sending
			this.h.onDiag?.({ kind: "drop", reason: "too_old" });
			return;
		}
		if (this.state === "live") {
			this.seq += 1;
			if (this.sendFrame({ type: "position", id: this.seq, fix })) {
				this.pending = null;
				this.inflight.set(this.seq, this.deps.now());
				if (this.inflight.size > 32) this.inflight.delete(this.inflight.keys().next().value as number);
				this.h.onDiag?.({ kind: "send", transport: "ws" });
			}
			return;
		}
		if (this.state === "polling") {
			this.pending = null;
			const sentAt = this.deps.now();
			this.h.onDiag?.({ kind: "send", transport: "http" });
			this.deps.post(this.outingId, fix).then(
				() => {
					this.h.onDiag?.({ kind: "ack", transport: "http", ok: true, reason: undefined, latencyMs: this.deps.now() - sentAt });
					this.h.onAck?.(true, undefined);
				},
				(e: unknown) => {
					const code = e instanceof OutingApiError ? e.code : "network";
					/* A network failure is no answer at all: it stays unacknowledged, not refused. */
					if (code !== "network") this.h.onDiag?.({ kind: "ack", transport: "http", ok: false, reason: code, latencyMs: this.deps.now() - sentAt });
					if (code === "not_a_member") return this.terminal("not_a_member");
					this.h.onAck?.(false, code);
				},
			);
		}
	}

	private terminal(reason: ClosedReason) {
		if (this.stopped) return;
		this.stop();
		this.h.onClosed(reason);
	}

	private connect() {
		if (this.stopped) return;
		if (!this.deps.online()) {
			this.setState("offline");
			return;
		}
		if (this.state !== "polling") this.setState("connecting");
		const Impl = this.deps.WebSocketImpl;
		if (!Impl) return this.startPolling();
		let ws: WebSocket;
		try {
			ws = new Impl(this.url);
		} catch {
			return this.onSocketFailed();
		}
		this.ws = ws;
		let reachedReady = false;
		ws.onopen = () => {
			ws.send(JSON.stringify({ type: "auth", token: this.token, outing_id: this.outingId }));
		};
		ws.onmessage = (ev: MessageEvent) => {
			if (this.ws !== ws) return;
			this.lastFrameAt = this.deps.now();
			let msg: { type?: string; [k: string]: unknown };
			try {
				msg = JSON.parse(String(ev.data));
			} catch {
				return;
			}
			if (msg.type === "ready") {
				reachedReady = true;
				this.everReady = true;
				this.attempts = 0;
				this.stopPolling();
				this.setState("live");
				this.h.onSnapshot(msg.snapshot as OutingSnapshot);
				if (this.away) this.sendFrame({ type: "presence", away: true });
				this.flush();
				this.schedulePing();
				return;
			}
			if (msg.type === "ack") {
				const id = typeof msg.id === "number" ? msg.id : null;
				const sentAt = id != null ? this.inflight.get(id) : undefined;
				if (id != null) this.inflight.delete(id);
				this.h.onDiag?.({
					kind: "ack",
					transport: "ws",
					ok: msg.ok === true,
					reason: msg.reason as AckReason,
					latencyMs: sentAt != null ? this.deps.now() - sentAt : null,
				});
				return this.h.onAck?.(msg.ok === true, msg.reason as AckReason);
			}
			if (msg.type === "pong" || msg.type === "error") return;
			if (msg.type === "closed") return; // the close code follows
			this.h.onEvent(msg as unknown as LiveEvent);
		};
		ws.onclose = (ev: CloseEvent) => {
			if (this.ws !== ws) return;
			this.ws = null;
			this.inflight.clear();
			if (this.pingTimer) this.deps.clearTimeout(this.pingTimer);
			const reason = TERMINAL_CODES[ev.code];
			if (reason) return this.terminal(reason);
			if (this.stopped) return;
			if (!reachedReady) return this.onSocketFailed();
			this.scheduleReconnect();
		};
		ws.onerror = () => {
			/* onclose follows */
		};
	}

	private onSocketFailed() {
		this.attempts += 1;
		if (!this.everReady && this.attempts >= FAILS_BEFORE_POLLING) this.startPolling();
		this.scheduleReconnect();
	}

	private scheduleReconnect() {
		if (this.stopped) return;
		if (!this.deps.online()) return this.setState("offline");
		if (this.state !== "polling") this.setState("connecting");
		this.clearRetry();
		const wait = backoffMs(this.attempts);
		this.attempts += 1;
		this.retryTimer = this.deps.setTimeout(() => this.connect(), wait);
	}

	private schedulePing() {
		if (this.pingTimer) this.deps.clearTimeout(this.pingTimer);
		this.pingTimer = this.deps.setTimeout(() => {
			if (this.stopped || !this.ws) return;
			if (this.deps.now() - this.lastFrameAt > SILENCE_MS) {
				/* Half-open: the tunnel ate the socket without a close frame. */
				const ws = this.ws;
				this.ws = null;
				try {
					ws.close();
				} catch {
					/* */
				}
				return this.scheduleReconnect();
			}
			this.sendFrame({ type: "ping" });
			this.schedulePing();
		}, PING_MS);
	}

	private startPolling() {
		if (this.stopped || this.state === "polling") return;
		this.wasPolling = true;
		this.setState("polling");
		const tick = async () => {
			if (this.stopped || this.state !== "polling") return;
			try {
				const s = await this.deps.poll(this.outingId);
				if (this.stopped || this.state !== "polling") return;
				this.h.onSnapshot(s);
				if (s.outing.status === "ended") return this.terminal("outing_ended");
				this.flush();
			} catch (e) {
				const code = e instanceof OutingApiError ? e.code : "network";
				if (code === "not_a_member") return this.terminal("not_a_member");
				if (code === "unauthorized") return this.terminal("unauthorized");
			}
			if (!this.stopped && this.state === "polling") this.pollTimer = this.deps.setTimeout(tick, POLL_MS);
		};
		void tick();
	}

	private stopPolling() {
		if (this.pollTimer) this.deps.clearTimeout(this.pollTimer);
		this.pollTimer = null;
	}
}
