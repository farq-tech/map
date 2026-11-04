/**
 * «مؤقت الرجوع» — the public watch link (/watch#<token>), opened by the
 * person a group told "if we are not back by …, worry".
 *
 * The token is a capability: it rides in the URL fragment (never sent to any
 * server by the browser), is read once, then wiped from the address bar. It
 * is kept for this tab in sessionStorage so a reload still works, and in
 * localStorage only if the watcher turns on «نبّهني إذا تأخروا» — so tapping
 * that notification later can reopen the page.
 *
 * The API answers positions only once the timer is overdue, and only the
 * snapshot taken at that moment. This page never shows anything as live.
 */

import { API_BASE_URL } from "../api";
import { safeGet, safeRemove, safeSet } from "../safeStorage";
import { ensureWorker } from "../sw/worker";
import { fetchPushConfig, pushSupport, readPushEnv, urlBase64ToUint8Array } from "./push";

export type WatchState = "armed" | "overdue" | "arrived" | "cancelled";

export type WatchStatus = {
	outing_name: string;
	owner_name: string;
	contact_name: string;
	due_at: string;
	state: WatchState;
	members: Array<{ name: string }>;
	server_now?: string;
	/** Only when overdue: the snapshot taken when the timer went overdue. */
	last_known?: Array<{ name: string; lat: number; lng: number; at: string }>;
	/** Only when overdue: the timer owner's own phone, if they put one on their profile. */
	owner_phone?: string | null;
};

export type WatchResult = { ok: true; status: WatchStatus } | { ok: false; reason: "invalid" | "rate_limited" | "network" };

const SESSION_KEY = "sary.watch.token.v1";
const PERSIST_KEY = "sary.watch.token.persist.v1";

export const WATCH_POLL_MS = 30_000;

export function isWatchToken(v: unknown): v is string {
	return typeof v === "string" && /^[A-Za-z0-9_-]{43}$/.test(v);
}

/** "#<token>" → token, or null. Tolerates a leading "#", "#token=", stray whitespace. */
export function tokenFromHash(hash: string): string | null {
	const raw = decodeURIComponent(String(hash || "").replace(/^#/, "").replace(/^token=/, "").trim());
	return isWatchToken(raw) ? raw : null;
}

/**
 * Read the token from the fragment (then wipe it from the address bar and
 * history entry), else from this tab, else from a «نبّهني» subscription.
 */
export function takeWatchToken(win: Window = window): string | null {
	const fromHash = tokenFromHash(win.location.hash);
	if (fromHash) {
		safeSet("sessionStorage", SESSION_KEY, fromHash);
		try {
			win.history.replaceState(win.history.state, "", win.location.pathname + win.location.search);
		} catch {
			/* an old browser keeps the fragment; the token still never reached a server */
		}
		return fromHash;
	}
	const s = safeGet("sessionStorage", SESSION_KEY);
	if (isWatchToken(s)) return s;
	const p = safeGet("localStorage", PERSIST_KEY);
	return isWatchToken(p) ? p : null;
}

export function forgetWatchToken(): void {
	safeRemove("sessionStorage", SESSION_KEY);
	safeRemove("localStorage", PERSIST_KEY);
}

export async function fetchWatchStatus(token: string, fetchImpl: typeof fetch = fetch): Promise<WatchResult> {
	try {
		const res = await fetchImpl(`${API_BASE_URL}/api/outings/watch/status`, {
			method: "POST",
			headers: { "content-type": "application/json", accept: "application/json" },
			body: JSON.stringify({ token }),
			cache: "no-store",
			referrerPolicy: "no-referrer",
		});
		if (res.status === 404) return { ok: false, reason: "invalid" };
		if (res.status === 429) return { ok: false, reason: "rate_limited" };
		if (!res.ok) return { ok: false, reason: "network" };
		const j = (await res.json()) as WatchStatus & { ok?: boolean };
		return { ok: true, status: j };
	} catch {
		return { ok: false, reason: "network" };
	}
}

export type WatchPushResult = { ok: true } | { ok: false; reason: "disabled" | "denied" | "unsupported" | "ios-needs-home-screen" | "closed" | "failed" };

/** «نبّهني إذا تأخروا» — must run from a tap. Uses the same service worker and VAPID key as outings. */
export async function subscribeWatcher(token: string): Promise<WatchPushResult> {
	const support = pushSupport(readPushEnv());
	if (support !== "available") return { ok: false, reason: support };
	const cfg = await fetchPushConfig();
	if (!cfg.enabled || !cfg.public_key) return { ok: false, reason: "disabled" };
	try {
		const permission = await Notification.requestPermission();
		if (permission !== "granted") return { ok: false, reason: permission === "denied" ? "denied" : "failed" };
		const reg = await ensureWorker();
		let sub = await reg.pushManager.getSubscription();
		if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(cfg.public_key) });
		const res = await fetch(`${API_BASE_URL}/api/outings/watch/subscribe`, {
			method: "POST",
			headers: { "content-type": "application/json", accept: "application/json" },
			body: JSON.stringify({ token, subscription: sub.toJSON() }),
			referrerPolicy: "no-referrer",
		});
		if (res.status === 410) return { ok: false, reason: "closed" };
		if (res.status === 503) return { ok: false, reason: "disabled" };
		if (!res.ok) return { ok: false, reason: "failed" };
		/* So tapping the notification later can reopen this page. */
		safeSet("localStorage", PERSIST_KEY, token);
		return { ok: true };
	} catch {
		return { ok: false, reason: "failed" };
	}
}

const AR_DIGITS = "٠١٢٣٤٥٦٧٨٩";
export function arabicDigits(s: string | number): string {
	return String(s).replace(/[0-9]/g, (d) => AR_DIGITS[Number(d)]);
}

/** «الساعة ٧:٣٠ م» (+ the day if not today), in Riyadh time. */
export function formatDue(iso: string, now = Date.now()): string {
	const d = new Date(iso);
	const opts: Intl.DateTimeFormatOptions = { hour: "numeric", minute: "2-digit", timeZone: "Asia/Riyadh", numberingSystem: "arab" };
	const sameDay = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Riyadh" }).format(d) === new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Riyadh" }).format(new Date(now));
	if (!sameDay) Object.assign(opts, { weekday: "long", day: "numeric", month: "long" });
	return new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-arab", opts).format(d);
}

/** Time left / late, in words: «باقي ساعة و١٠ دقائق», «متأخرين ٢٥ دقيقة». */
export function relativeDue(iso: string, now = Date.now()): string {
	const diff = new Date(iso).getTime() - now;
	const mins = Math.max(1, Math.round(Math.abs(diff) / 60_000));
	const h = Math.floor(mins / 60);
	const m = mins % 60;
	const hours = h === 0 ? "" : h === 1 ? "ساعة" : h === 2 ? "ساعتين" : `${arabicDigits(h)} ساعات`;
	const minutes = m === 0 ? "" : m === 1 ? "دقيقة" : m === 2 ? "دقيقتين" : `${arabicDigits(m)} ${m <= 10 ? "دقائق" : "دقيقة"}`;
	const span = [hours, minutes].filter(Boolean).join(" و");
	return diff >= 0 ? `باقي ${span}` : `متأخرين ${span}`;
}

/** «قبل ٥ دقائق» for a snapshot time — never "now", never "live". */
export function ago(iso: string, now = Date.now()): string {
	const mins = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60_000));
	if (mins < 1) return "قبل أقل من دقيقة";
	if (mins < 60) return `قبل ${mins === 1 ? "دقيقة" : mins === 2 ? "دقيقتين" : `${arabicDigits(mins)} ${mins <= 10 ? "دقائق" : "دقيقة"}`}`;
	const h = Math.round(mins / 60);
	return `قبل ${h === 1 ? "ساعة" : h === 2 ? "ساعتين" : `${arabicDigits(h)} ساعات`}`;
}

/** tel: link for an E.164 number we got from the API, or null. */
export function telHref(phone: string | null | undefined): string | null {
	return typeof phone === "string" && /^\+\d{8,15}$/.test(phone) ? `tel:${phone}` : null;
}
