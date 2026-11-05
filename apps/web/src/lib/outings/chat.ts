/**
 * «المحادثات» on the web — the group chat of one outing («دردشة الطلعة»).
 * The server holds the rules (apps/api/lib/outings/chat.js): membership on
 * every call, order by server `seq`, 30-day retention after the trip ends.
 * Here: the HTTP calls, the live-socket event bus, and pure helpers.
 */

import { API_BASE_URL } from "../api";
import { loadIdentity, OutingApiError } from "./api";

export const CHAT_TEXT_MAX = 1000;
/** The note presets, offered as quick replies (the server sends its own list too). */
export const QUICK_REPLIES = ["بوقف", "محطة بنزين", "انتظروني", "تعبت نرتاح", "وصلت"];

export type ChatPoint = { lat: number; lng: number; label: string | null };

export type ChatMessage = {
	id: string;
	outing_id: string;
	seq: number;
	conv: "group" | "direct";
	sender_id: string;
	recipient_id: string | null;
	sender_name: string | null;
	client_id: string;
	kind: "text" | "quick" | "location";
	text: string | null;
	point: ChatPoint | null;
	created_at: string;
	deleted: boolean;
	deleted_by: "self" | "leader" | null;
	/** Client only: still on its way (no server seq yet), or it failed. */
	pending?: "sending" | "failed";
};

export type ChatRead = { user_id: string; seq: number };

export type ChatPage = {
	with: string;
	messages: ChatMessage[];
	has_more: boolean;
	my_read_seq: number;
	reads: ChatRead[];
	writable: boolean;
	read_only_reason: string | null;
};

export type ChatConversation = {
	with: string;
	conv: "group" | "direct";
	peer_id: string | null;
	unread: number;
	last_message: ChatMessage | null;
	my_read_seq: number;
	writable: boolean;
};

export type ChatOverview = {
	conversations: ChatConversation[];
	unread_total: number;
	writable: boolean;
	read_only_reason: string | null;
	can_moderate: boolean;
	quick_replies: string[];
	retention_days: number;
	purge_at: string | null;
};

export type ChatEvent =
	| { type: "chat_message"; message: ChatMessage }
	| { type: "chat_deleted"; message: ChatMessage }
	| { type: "chat_read"; conv: "group" | "direct"; user_id: string; peer_id: string | null; seq: number }
	| { type: "chat_typing"; conv: "group" | "direct"; user_id: string; peer_id: string | null; on: boolean };

export type SendBody = { client_id: string; kind: ChatMessage["kind"]; text?: string; point?: ChatPoint };

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
	const id = loadIdentity();
	let res: Response;
	try {
		res = await fetch(`${API_BASE_URL}/api/outings${path}`, {
			method,
			headers: {
				accept: "application/json",
				...(body !== undefined ? { "content-type": "application/json" } : {}),
				...(id ? { authorization: `Bearer ${id.token}` } : {}),
			},
			body: body !== undefined ? JSON.stringify(body) : undefined,
		});
	} catch {
		throw new OutingApiError("network", 0);
	}
	const json = (await res.json().catch(() => null)) as { ok?: boolean; error?: string } | null;
	if (!res.ok || !json || json.ok === false) throw new OutingApiError(json?.error || `http_${res.status}`, res.status);
	return json as T;
}

export const ChatApi = {
	overview: (outingId: string) => call<ChatOverview>("GET", `/${outingId}/chat`),
	page: (outingId: string, withId = "group", cursor: { before?: number; after?: number; limit?: number } = {}) => {
		const qs = new URLSearchParams();
		if (cursor.before != null) qs.set("before", String(cursor.before));
		if (cursor.after != null) qs.set("after", String(cursor.after));
		if (cursor.limit != null) qs.set("limit", String(cursor.limit));
		const s = qs.toString();
		return call<ChatPage>("GET", `/${outingId}/chat/${encodeURIComponent(withId)}${s ? `?${s}` : ""}`);
	},
	send: (outingId: string, withId: string, body: SendBody) => call<{ message: ChatMessage; duplicate: boolean }>("POST", `/${outingId}/chat/${encodeURIComponent(withId)}`, body),
	read: (outingId: string, withId: string, seq: number) => call<{ last_read_seq: number }>("POST", `/${outingId}/chat/${encodeURIComponent(withId)}/read`, { seq }),
	remove: (outingId: string, messageId: string) => call<{ message: ChatMessage }>("DELETE", `/${outingId}/chat/messages/${messageId}`),
};

/* ---------- live socket → chat panel ---------- */

type Listener = (e: ChatEvent) => void;
const listeners = new Set<Listener>();

export const chatBus = {
	emit(e: { type?: unknown }) {
		if (typeof e?.type !== "string" || !e.type.startsWith("chat_")) return false;
		for (const l of listeners) l(e as ChatEvent);
		return true;
	},
	on(l: Listener) {
		listeners.add(l);
		return () => void listeners.delete(l);
	},
};

/* ---------- pure helpers ---------- */

export function newClientId(rand: () => number = Math.random, now = Date.now()): string {
	return `w${now.toString(36)}${Math.floor(rand() * 36 ** 6).toString(36).padStart(6, "0")}`;
}

/** A draft → the text to send, or why not. Counts characters like the server (code points). */
export function checkDraft(raw: string): { ok: true; text: string } | { ok: false; reason: "empty" | "too_long" } {
	const t = raw.replace(/\r\n?/g, "\n").trim();
	if (!t) return { ok: false, reason: "empty" };
	if ([...t].length > CHAT_TEXT_MAX) return { ok: false, reason: "too_long" };
	return { ok: true, text: t };
}

/**
 * Merge incoming messages into a list: one entry per message (a pending copy is
 * replaced by the server's, matched on client_id), ordered by server seq, the
 * still-pending ones last in the order they were written.
 */
export function mergeMessages(list: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] {
	const byKey = new Map<string, ChatMessage>();
	for (const m of list) byKey.set(m.client_id ? `${m.sender_id}:${m.client_id}` : m.id, m);
	for (const m of incoming) {
		const key = m.client_id ? `${m.sender_id}:${m.client_id}` : m.id;
		const prev = byKey.get(key);
		/* A server copy always wins over a pending one; a deletion wins over the original. */
		if (prev && !prev.pending && !m.pending && prev.deleted && !m.deleted) continue;
		if (prev && !prev.pending && m.pending) continue;
		byKey.set(key, m);
	}
	return [...byKey.values()].sort((a, b) => {
		if (a.pending && b.pending) return a.created_at.localeCompare(b.created_at);
		if (a.pending) return 1;
		if (b.pending) return -1;
		return a.seq - b.seq;
	});
}

/** ✓ (stored) or ✓✓ (everyone else in the chat has read it). Only for my own messages. */
export function receipt(m: ChatMessage, meId: string, reads: ChatRead[], othersCount: number): "sending" | "failed" | "sent" | "read" | null {
	if (m.sender_id !== meId) return null;
	if (m.pending) return m.pending;
	const readers = reads.filter((r) => r.user_id !== meId && r.seq >= m.seq).length;
	return othersCount > 0 && readers >= othersCount ? "read" : "sent";
}

/** Unread for me: others' visible messages above my read marker. */
export function unreadCount(list: ChatMessage[], meId: string, myReadSeq: number): number {
	return list.filter((m) => !m.pending && !m.deleted && m.sender_id !== meId && m.seq > myReadSeq).length;
}

export function applyRead(reads: ChatRead[], userId: string, seq: number): ChatRead[] {
	const prev = reads.find((r) => r.user_id === userId);
	if (prev && prev.seq >= seq) return reads;
	return [...reads.filter((r) => r.user_id !== userId), { user_id: userId, seq }];
}

export function deletedLabel(m: ChatMessage, isRTL = true): string {
	if (m.deleted_by === "leader") return isRTL ? "حذفها أمير الرحلة" : "Removed by the trip leader";
	return isRTL ? "حُذفت الرسالة" : "Message deleted";
}

export function chatErrorText(code: string, isRTL = true): string {
	const ar: Record<string, string> = {
		outing_ended: "انتهت الطلعة — المحادثة للقراءة فقط.",
		chat_read_only: "غادرت الطلعة — المحادثة للقراءة فقط.",
		text_too_long: `الرسالة أطول من ${CHAT_TEXT_MAX.toLocaleString("ar-SA")} حرف.`,
		too_frequent: "مهلًا، رسائل كثيرة بسرعة.",
		rate_limited: "مهلًا، رسائل كثيرة بسرعة.",
		network: "ما وصلت الرسالة — تحقق من الاتصال وأعد المحاولة.",
		not_allowed: "ما تقدر تحذف هذه الرسالة.",
	};
	const en: Record<string, string> = {
		outing_ended: "The outing ended — chat is read-only.",
		chat_read_only: "You left — chat is read-only.",
		text_too_long: `Longer than ${CHAT_TEXT_MAX} characters.`,
		too_frequent: "Slow down a little.",
		rate_limited: "Slow down a little.",
		network: "Not sent — check the connection and retry.",
		not_allowed: "You can’t delete this message.",
	};
	return (isRTL ? ar : en)[code] || (isRTL ? "تعذّر الإرسال." : "Couldn’t send.");
}
