/**
 * Web Push for outings: a note or an SOS reaches the phone while its screen is
 * off. The browser holds the subscription; the API stores it against this
 * device's outing identity and decides at send time who is a member.
 *
 * Location is never involved — sharing still runs only while the outing
 * screen is open.
 *
 * iOS: Safari delivers web push only to a site added to the home screen
 * (iOS 16.4+), opened from that icon. In a Safari tab PushManager is missing,
 * so we explain the step instead of showing a button that cannot work.
 */

import { ensureWorker, releaseWorkerIfUnused } from "../sw/worker";
import { API_BASE_URL } from "../api";
import { loadIdentity } from "./api";

export type PushSupport =
	/** Everything is there: we can ask. */
	| "available"
	/** iPhone/iPad in a Safari tab: add to the home screen first. */
	| "ios-needs-home-screen"
	/** The person said no; only browser settings can change it. */
	| "denied"
	/** No service worker / PushManager / Notification in this browser. */
	| "unsupported";

export type PushEnv = {
	userAgent: string;
	maxTouchPoints: number;
	standalone: boolean;
	hasServiceWorker: boolean;
	hasPushManager: boolean;
	hasNotification: boolean;
	permission: NotificationPermission | null;
};

export function isIOS(userAgent: string, maxTouchPoints = 0): boolean {
	if (/iPhone|iPad|iPod/i.test(userAgent)) return true;
	/* iPadOS reports itself as a Mac with a touch screen. */
	return /Macintosh/i.test(userAgent) && maxTouchPoints > 1;
}

/** Launched from the home screen (iOS) or installed as an app (others). */
export function isStandalone(win: Window | undefined = typeof window === "undefined" ? undefined : window): boolean {
	if (!win) return false;
	const nav = win.navigator as Navigator & { standalone?: boolean };
	if (nav.standalone === true) return true;
	try {
		return win.matchMedia?.("(display-mode: standalone)").matches || win.matchMedia?.("(display-mode: fullscreen)").matches || false;
	} catch {
		return false;
	}
}

export function readPushEnv(win: Window | undefined = typeof window === "undefined" ? undefined : window): PushEnv {
	if (!win) {
		return { userAgent: "", maxTouchPoints: 0, standalone: false, hasServiceWorker: false, hasPushManager: false, hasNotification: false, permission: null };
	}
	const N = (win as Window & { Notification?: typeof Notification }).Notification;
	const hasNotification = typeof N !== "undefined";
	return {
		userAgent: win.navigator.userAgent || "",
		maxTouchPoints: win.navigator.maxTouchPoints || 0,
		standalone: isStandalone(win),
		hasServiceWorker: "serviceWorker" in win.navigator,
		hasPushManager: "PushManager" in win,
		hasNotification,
		permission: N ? N.permission : null,
	};
}

export function pushSupport(env: PushEnv): PushSupport {
	const ios = isIOS(env.userAgent, env.maxTouchPoints);
	if (ios && !env.standalone) return "ios-needs-home-screen";
	if (!env.hasServiceWorker || !env.hasPushManager || !env.hasNotification) return ios ? "ios-needs-home-screen" : "unsupported";
	if (env.permission === "denied") return "denied";
	return "available";
}

/** VAPID public key (base64url) → the bytes PushManager.subscribe wants. */
export function urlBase64ToUint8Array(base64url: string): Uint8Array<ArrayBuffer> {
	const padded = base64url.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (base64url.length % 4)) % 4);
	const raw = atob(padded);
	const out = new Uint8Array(new ArrayBuffer(raw.length));
	for (let i = 0; i < raw.length; i += 1) out[i] = raw.charCodeAt(i);
	return out;
}

export type PushConfig = { enabled: boolean; public_key: string | null };

let configPromise: Promise<PushConfig> | null = null;

/** Whether the server can push at all (VAPID keys set). Cached per page load. */
export function fetchPushConfig(): Promise<PushConfig> {
	if (!configPromise) {
		configPromise = fetch(`${API_BASE_URL}/api/outings/push/config`, { headers: { accept: "application/json" } })
			.then((r) => (r.ok ? r.json() : null))
			.then((j: { enabled?: boolean; public_key?: string | null } | null) => ({ enabled: Boolean(j?.enabled && j.public_key), public_key: j?.public_key || null }))
			.catch(() => {
				configPromise = null;
				return { enabled: false, public_key: null };
			});
	}
	return configPromise;
}

async function authed(method: string, path: string, body: unknown): Promise<Response> {
	const id = loadIdentity();
	return fetch(`${API_BASE_URL}/api/outings${path}`, {
		method,
		headers: { "content-type": "application/json", accept: "application/json", ...(id ? { authorization: `Bearer ${id.token}` } : {}) },
		body: JSON.stringify(body),
	});
}

/* The worker is shared with offline areas (lib/sw/worker.ts). */
function registration(): Promise<ServiceWorkerRegistration> {
	return ensureWorker();
}

/** The subscription this browser already has, if any (no prompt, no network). */
export async function currentSubscription(): Promise<PushSubscription | null> {
	if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) return null;
	try {
		const reg = await navigator.serviceWorker.getRegistration("/");
		return (await reg?.pushManager.getSubscription()) || null;
	} catch {
		return null;
	}
}

export type EnableResult = { ok: true } | { ok: false; reason: "disabled" | "denied" | "unsupported" | "failed" };

/** Must run from a tap (iOS requires a user gesture for the permission prompt). */
export async function enablePush(): Promise<EnableResult> {
	const support = pushSupport(readPushEnv());
	if (support === "denied") return { ok: false, reason: "denied" };
	if (support !== "available") return { ok: false, reason: "unsupported" };
	const cfg = await fetchPushConfig();
	if (!cfg.enabled || !cfg.public_key) return { ok: false, reason: "disabled" };
	try {
		const permission = await Notification.requestPermission();
		if (permission !== "granted") return { ok: false, reason: permission === "denied" ? "denied" : "failed" };
		const reg = await registration();
		const key = urlBase64ToUint8Array(cfg.public_key);
		let sub = await reg.pushManager.getSubscription();
		/* A subscription made for another server key cannot be used: replace it. */
		const existingKey = sub?.options?.applicationServerKey;
		if (sub && existingKey && !sameBytes(new Uint8Array(existingKey), key)) {
			await sub.unsubscribe().catch(() => undefined);
			sub = null;
		}
		if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
		const res = await authed("POST", "/push/subscribe", { subscription: sub.toJSON() });
		return res.ok ? { ok: true } : { ok: false, reason: res.status === 503 ? "disabled" : "failed" };
	} catch {
		return { ok: false, reason: "failed" };
	}
}

export async function disablePush(): Promise<void> {
	const sub = await currentSubscription();
	if (!sub) return;
	await authed("DELETE", "/push/subscribe", { endpoint: sub.endpoint }).catch(() => undefined);
	await sub.unsubscribe().catch(() => undefined);
	/* Saved offline areas still need the worker; otherwise it can go. */
	await releaseWorkerIfUnused().catch(() => false);
}

/**
 * Re-send an existing subscription quietly (no prompt): the server may have
 * dropped it, or this device has a new outing identity since.
 */
export async function refreshPushSubscription(): Promise<boolean> {
	if (typeof Notification === "undefined" || Notification.permission !== "granted") return false;
	const sub = await currentSubscription();
	if (!sub || !loadIdentity()) return false;
	const cfg = await fetchPushConfig();
	if (!cfg.enabled) return false;
	try {
		return (await authed("POST", "/push/subscribe", { subscription: sub.toJSON() })).ok;
	} catch {
		return false;
	}
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i += 1) if (a[i] !== b[i]) return false;
	return true;
}
