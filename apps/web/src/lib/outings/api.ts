/**
 * Shared outings REST client. The identity token lives on this device only
 * (localStorage) and travels as a Bearer header; invite tokens travel in
 * request bodies, never in a URL.
 */

import { API_BASE_URL } from "../api";
import { safeGet, safeRemove, safeSet } from "../safeStorage";
import type { ShareMode } from "./policy";

const IDENTITY_KEY = "sary.outings.identity.v1";
const INVITES_KEY = "sary.outings.invites.v1";
const MODE_KEY = "sary.outings.mode.v1";
const WAKE_KEY = "sary.outings.wake.v1";

export type Identity = { token: string; user: PublicUser };
export type PublicUser = { id: string; display_name: string; avatar: string | null };
export type OutingStatus = "created" | "active" | "paused" | "ended";

export type Member = {
	user_id: string;
	display_name: string;
	avatar: string | null;
	role: "owner" | "member";
	sharing: boolean;
	joined_at: string;
	online?: boolean;
	away?: boolean;
	/** When the server last heard anything from this member (fix, heartbeat, poll). */
	last_seen_at?: string | null;
	/** What their GPS last reported in a heartbeat. */
	gps?: GpsState | null;
	/** A short line they put over their car («بوقف عند المحطة»); gone after 15 min. */
	note?: MemberNote | null;
};

export type MemberNote = { text: string; at: string };

export type GpsState = "ok" | "weak" | "unavailable" | "denied";

export type Position = {
	user_id: string;
	lat: number;
	lng: number;
	accuracy: number | null;
	heading: number | null;
	speed: number | null;
	mode: ShareMode | null;
	recorded_at: string;
	received_at: string;
};

export type OutingSnapshot = {
	outing: {
		id: string;
		name: string;
		status: OutingStatus;
		owner_id: string;
		created_at: string;
		started_at: string | null;
		ended_at: string | null;
	};
	me: { user_id: string; role: "owner" | "member"; sharing: boolean };
	members: Member[];
	positions: Position[];
	invite: { active: boolean; expires_at: string | null } | null;
	server_now: string;
};

export type OutingSummary = {
	id: string;
	name: string;
	status: OutingStatus;
	role: "owner" | "member";
	my_status: "active" | "left" | "removed";
	member_count: number;
	created_at: string;
	started_at: string | null;
	ended_at: string | null;
};

export type InvitePreview = {
	outing_id: string;
	name: string;
	status: OutingStatus;
	owner_name: string;
	member_count: number;
	expires_at: string;
};

export class OutingApiError extends Error {
	constructor(
		public code: string,
		public status: number,
	) {
		super(code);
	}
}

export function loadIdentity(): Identity | null {
	try {
		const raw = safeGet("localStorage", IDENTITY_KEY);
		const v = raw ? (JSON.parse(raw) as Identity) : null;
		return v?.token && v.user?.id ? v : null;
	} catch {
		return null;
	}
}

function saveIdentity(id: Identity | null): void {
	if (!id) safeRemove("localStorage", IDENTITY_KEY);
	else safeSet("localStorage", IDENTITY_KEY, JSON.stringify(id));
}

/** The owner keeps the invite link on their device; the server only has its hash. */
export function loadInviteToken(outingId: string): string | null {
	try {
		const all = JSON.parse(safeGet("localStorage", INVITES_KEY) || "{}") as Record<string, string>;
		return all[outingId] || null;
	} catch {
		return null;
	}
}

export function saveInviteToken(outingId: string, token: string | null): void {
	let all: Record<string, string> = {};
	try {
		all = JSON.parse(safeGet("localStorage", INVITES_KEY) || "{}");
	} catch {
		/* */
	}
	if (token) all[outingId] = token;
	else delete all[outingId];
	safeSet("localStorage", INVITES_KEY, JSON.stringify(all));
}

export function inviteUrl(token: string): string {
	return `${window.location.origin}/outings/join#${token}`;
}

export function loadShareMode(): ShareMode {
	const v = safeGet("localStorage", MODE_KEY);
	return v === "precise" || v === "saver" ? v : "balanced";
}

export function saveShareMode(mode: ShareMode): void {
	safeSet("localStorage", MODE_KEY, mode);
}

export function loadWakeLock(): boolean {
	return safeGet("localStorage", WAKE_KEY) === "1";
}

export function saveWakeLock(on: boolean): void {
	safeSet("localStorage", WAKE_KEY, on ? "1" : "0");
}

async function call<T>(method: string, path: string, body?: unknown, { auth = true, timeoutMs = 12_000 } = {}): Promise<T> {
	const id = loadIdentity();
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), timeoutMs);
	let res: Response;
	try {
		res = await fetch(`${API_BASE_URL}/api/outings${path}`, {
			method,
			signal: controller.signal,
			headers: {
				accept: "application/json",
				...(body !== undefined ? { "content-type": "application/json" } : {}),
				...(auth && id ? { authorization: `Bearer ${id.token}` } : {}),
			},
			body: body !== undefined ? JSON.stringify(body) : undefined,
		});
	} catch {
		throw new OutingApiError(controller.signal.aborted ? "timeout" : "network", 0);
	} finally {
		clearTimeout(timer);
	}
	const json = (await res.json().catch(() => null)) as { ok?: boolean; error?: string } | null;
	if (!res.ok || !json || json.ok === false) {
		if (res.status === 401) saveIdentity(null);
		throw new OutingApiError(json?.error || `http_${res.status}`, res.status);
	}
	return json as T;
}

export const OutingsApi = {
	async createIdentity(display_name: string, avatar: string | null): Promise<Identity> {
		const r = await call<{ user: PublicUser; token: string }>("POST", "/me", { display_name, avatar }, { auth: false });
		const id = { token: r.token, user: r.user };
		saveIdentity(id);
		return id;
	},
	async updateProfile(patch: { display_name?: string; avatar?: string | null }): Promise<PublicUser> {
		const r = await call<{ user: PublicUser }>("PATCH", "/me", patch);
		const cur = loadIdentity();
		if (cur) saveIdentity({ ...cur, user: r.user });
		return r.user;
	},
	list: () => call<{ current: OutingSummary[]; history: OutingSummary[] }>("GET", ""),
	async create(name: string): Promise<{ outing_id: string; invite: { token: string; expires_at: string } }> {
		const r = await call<{ outing_id: string; invite: { token: string; expires_at: string } }>("POST", "", { name });
		saveInviteToken(r.outing_id, r.invite.token);
		return r;
	},
	get: (id: string) => call<OutingSnapshot>("GET", `/${id}`),
	poll: (id: string) => call<OutingSnapshot>("GET", `/${id}/live`),
	heartbeat: (id: string, gps: GpsState) => call<{ ok: true }>("POST", `/${id}/heartbeat`, { gps }, { timeoutMs: 8_000 }),
	sendPosition: (id: string, fix: unknown) => call<{ ok: true }>("POST", `/${id}/positions`, { fix }, { timeoutMs: 8_000 }),
	setStatus: (id: string, action: "start" | "pause" | "resume" | "end") =>
		call<{ outing: OutingSnapshot["outing"] }>("POST", `/${id}/status`, { action }),
	async rotateInvite(id: string, ttl_hours?: number): Promise<{ token: string; expires_at: string }> {
		const r = await call<{ invite: { token: string; expires_at: string } }>("POST", `/${id}/invites`, { ttl_hours });
		saveInviteToken(id, r.invite.token);
		return r.invite;
	},
	async revokeInvites(id: string): Promise<void> {
		await call("DELETE", `/${id}/invites`);
		saveInviteToken(id, null);
	},
	note: (id: string, text: string) => call<{ note: MemberNote | null }>("POST", `/${id}/note`, { text }),
	setSharing: (id: string, sharing: boolean) => call<{ sharing: boolean }>("PATCH", `/${id}/me`, { sharing }),
	leave: (id: string) => call<{ ended: boolean }>("POST", `/${id}/leave`),
	removeMember: (id: string, userId: string) => call("DELETE", `/${id}/members/${userId}`),
	previewInvite: (token: string) => call<{ invite: InvitePreview }>("POST", "/invites/preview", { token }, { auth: false }),
	join: (token: string) => call<{ outing_id: string; already: boolean }>("POST", "/invites/join", { token }),
};

/** Error codes → a sentence a person can act on. */
export function outingErrorText(code: string, isRTL: boolean): string {
	const ar: Record<string, string> = {
		invite_invalid: "رابط الدعوة غير صحيح.",
		invite_expired: "انتهت صلاحية رابط الدعوة. اطلب من صاحب الطلعة رابطًا جديدًا.",
		invite_revoked: "ألغى صاحب الطلعة هذا الرابط. اطلب رابطًا جديدًا.",
		outing_ended: "انتهت هذه الطلعة.",
		outing_full: "اكتمل عدد المشاركين في هذه الطلعة.",
		removed_from_outing: "أزالك صاحب الطلعة منها، فلا يمكنك الانضمام مرة ثانية.",
		not_a_member: "لست عضوًا في هذه الطلعة.",
		owner_only: "هذا الإجراء لصاحب الطلعة فقط.",
		invalid_name: "اكتب اسمًا يظهر لأصحابك.",
		invalid_outing_name: "اكتب اسمًا للطلعة.",
		rate_limited: "محاولات كثيرة. انتظر قليلًا ثم أعد المحاولة.",
		too_frequent: "انتظر ثانيتين ثم أرسل.",
		invalid_note: "اكتب عبارة قصيرة.",
		network: "لا يوجد اتصال بالإنترنت.",
		timeout: "الشبكة بطيئة. أعد المحاولة.",
		outings_unconfigured: "الطلعات المشتركة غير مفعّلة على الخادم.",
		unauthorized: "انتهت جلستك على هذا الجهاز. ادخل باسمك مرة ثانية.",
	};
	const en: Record<string, string> = {
		invite_invalid: "This invite link is not valid.",
		invite_expired: "This invite has expired. Ask for a new link.",
		invite_revoked: "This invite was cancelled. Ask for a new link.",
		outing_ended: "This outing has ended.",
		outing_full: "This outing is full.",
		removed_from_outing: "You were removed from this outing and cannot rejoin.",
		not_a_member: "You are not a member of this outing.",
		owner_only: "Only the outing owner can do that.",
		invalid_name: "Enter a name your friends will see.",
		invalid_outing_name: "Name the outing.",
		rate_limited: "Too many attempts. Wait a moment.",
		too_frequent: "Wait a couple of seconds, then send.",
		invalid_note: "Write a short line.",
		network: "You are offline.",
		timeout: "The network is slow. Try again.",
		outings_unconfigured: "Shared outings are not enabled on the server.",
		unauthorized: "Your session on this device ended. Enter your name again.",
	};
	return (isRTL ? ar : en)[code] || (isRTL ? "حدث خطأ. أعد المحاولة." : "Something went wrong. Try again.");
}
