/**
 * Product analytics — what people do on this map, and nothing else.
 *
 * We currently guess at every product decision: whether people pick districts,
 * ask the copilot, switch list↔map or press "search here". This module answers
 * that with counted events, and is built so it can never be the reason the map
 * stutters or a render throws: `track()` buffers into memory, returns
 * immediately, swallows every error, and the batch is posted with
 * `navigator.sendBeacon` on a 3s timer or when the page goes away.
 *
 * PRIVACY: we never send free text a person typed. No search query, no copilot
 * question, no place name, no coordinates. `meta` may only carry small scalars
 * (`has_query: true`, not the query), the server drops anything outside its own
 * per-event allowlist, and the session id is an opaque per-tab UUID that dies
 * with the tab.
 *
 * ALLOWLIST SOURCE OF TRUTH: this list is mirrored in apps/api/lib/analytics.js
 * and apps/api/lib/analytics.test.js asserts the two still match (the
 * workspaces cannot import each other). Change one, change both.
 */
import { API_BASE_URL } from "./api";
import { safeGet, safeSet } from "./safeStorage";

/** The only event names the API will accept. Mirror of ALLOWED_EVENT_TYPES in apps/api/lib/analytics.js. */
export const ANALYTICS_EVENTS = [
	"map_view",
	"district_select",
	"district_clear",
	"place_select",
	"list_open",
	"map_open",
	"sort_change",
	"search_submit",
	"search_here",
	"copilot_ask",
	"copilot_action",
	"legend_open",
	"locate_click",
	"open_menu_click",
	"lens_change",
] as const;

export type AnalyticsEvent = (typeof ANALYTICS_EVENTS)[number];

/** Scalars only — a nested object is where free text hides. */
export type AnalyticsMeta = Record<string, string | number | boolean>;

const SESSION_KEY = "farq.analytics.session";
const ENDPOINT = `${API_BASE_URL}/api/analytics`;
const FLUSH_MS = 3_000;
/** One request may carry 20 events (the server's cap); we never hold more than this. */
const MAX_BATCH = 20;
const MAX_BUFFER = 50;

interface QueuedEvent {
	type: AnalyticsEvent;
	session_id: string | null;
	path: string | null;
	language: string | null;
	device: string | null;
	meta?: AnalyticsMeta;
}

let buffer: QueuedEvent[] = [];
let timer: ReturnType<typeof setTimeout> | null = null;
let listening = false;
let sessionId: string | null = null;

/** Do Not Track is a request, not a suggestion; `__farqAnalyticsOff` is the same switch for us. */
function disabled(): boolean {
	if ((globalThis as Record<string, unknown>).__farqAnalyticsOff) return true;
	return (
		typeof navigator !== "undefined" &&
		(navigator.doNotTrack === "1" ||
			(globalThis as { doNotTrack?: string }).doNotTrack === "1")
	);
}

/** Per-tab opaque id. sessionStorage can throw (private mode, blocked iframes) — safeStorage swallows that. */
function getSessionId(): string | null {
	if (sessionId) return sessionId;
	try {
		const stored = safeGet("sessionStorage", SESSION_KEY);
		if (stored) {
			sessionId = stored;
			return sessionId;
		}
		const fresh =
			typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
				? crypto.randomUUID()
				: `s-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
		safeSet("sessionStorage", SESSION_KEY, fresh);
		sessionId = fresh;
		return sessionId;
	} catch {
		return null;
	}
}

function currentDevice(): string | null {
	try {
		if (typeof matchMedia !== "function") return null;
		return matchMedia("(max-width: 1023px)").matches ? "mobile" : "desktop";
	} catch {
		return null;
	}
}

/**
 * Language is read from `<html lang>` — the LanguageContext already keeps it in
 * sync for RTL, so there is nothing to initialise and nothing to keep in sync
 * twice. Simplest honest option.
 */
function currentLanguage(): string | null {
	try {
		const lang = document.documentElement.lang;
		return lang.startsWith("ar") ? "ar" : lang.startsWith("en") ? "en" : null;
	} catch {
		return null;
	}
}

/** Route only — a query string is where typed text lives, so it never leaves here. */
function currentPath(): string | null {
	try {
		return location.pathname || null;
	} catch {
		return null;
	}
}

function post(events: QueuedEvent[]): void {
	const payload = JSON.stringify({ events });
	try {
		if (typeof navigator !== "undefined" && navigator.sendBeacon) {
			const blob =
				typeof Blob === "function"
					? new Blob([payload], { type: "application/json" })
					: payload;
			navigator.sendBeacon(ENDPOINT, blob as BodyInit);
			return;
		}
	} catch {
		/* fall through to fetch */
	}
	try {
		void fetch(ENDPOINT, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: payload,
			keepalive: true,
		}).catch(() => {});
	} catch {
		/* analytics is never allowed to matter */
	}
}

/** Send whatever is buffered, in requests of at most MAX_BATCH events. */
export function flush(): void {
	if (timer) {
		clearTimeout(timer);
		timer = null;
	}
	if (!buffer.length) return;
	const pending = buffer;
	buffer = [];
	for (let i = 0; i < pending.length; i += MAX_BATCH) {
		post(pending.slice(i, i + MAX_BATCH));
	}
}

/** A page can be frozen or closed without ever firing `unload`; these two catch it. */
function listen(): void {
	if (listening || typeof document === "undefined") return;
	listening = true;
	try {
		document.addEventListener("visibilitychange", () => {
			if (document.visibilityState === "hidden") flush();
		});
		addEventListener("pagehide", () => flush());
	} catch {
		/* ignore */
	}
}

/**
 * Fire and forget. Never throws, never awaits, never touches the DOM — safe to
 * call from a map handler or inside a render.
 */
export function track(type: AnalyticsEvent, meta?: AnalyticsMeta): void {
	try {
		if (disabled()) return;
		if (buffer.length >= MAX_BUFFER) return; // a stuck effect must not grow forever
		buffer.push({
			type,
			session_id: getSessionId(),
			path: currentPath(),
			language: currentLanguage(),
			device: currentDevice(),
			...(meta && typeof meta === "object" ? { meta } : {}),
		});
		listen();
		if (!timer) timer = setTimeout(flush, FLUSH_MS);
	} catch {
		/* analytics is never allowed to matter */
	}
}

/** Test seam only. */
export function __resetAnalyticsForTests(): void {
	if (timer) clearTimeout(timer);
	timer = null;
	buffer = [];
	sessionId = null;
	listening = false;
}

/** Test seam only. */
export function __bufferSizeForTests(): number {
	return buffer.length;
}
