/**
 * Shared outings REST client. The identity token lives on this device only
 * (localStorage) and travels as a Bearer header; invite tokens travel in
 * request bodies, never in a URL.
 */

import { API_BASE_URL } from "../api";
import { safeGet, safeRemove, safeSet } from "../safeStorage";
import type { ShareMode } from "./policy";
import { wakePreference } from "./wakeLock";
import type { ClipMeta } from "./voice";
import type { TripTotals } from "./trip";

const IDENTITY_KEY = "sary.outings.identity.v1";
const INVITES_KEY = "sary.outings.invites.v1";
const MODE_KEY = "sary.outings.mode.v1";
const WAKE_KEY = "sary.outings.wake.v1";
const GAP_KEY = "sary.outings.gapKm.v1";

export type Identity = { token: string; user: PublicUser };
export type PublicUser = { id: string; display_name: string; avatar: string | null; phone?: string | null };
export type OutingStatus = "created" | "active" | "paused" | "ended";

export type Member = {
	user_id: string;
	/** How the trip shows them: for a personal invite, the name the inviter gave them («فهد أخوي»). */
	display_name: string;
	/** Their own name, shown secondarily, when it differs from the inviter's name for them. */
	nickname?: string | null;
	/** Joined through a personal invite. */
	invited?: boolean;
	/** Last four digits of the number the inviter invited (personal invites only). */
	phone_last4?: string | null;
	avatar: string | null;
	/** Optional, shown only to fellow members (E.164, e.g. +9665…). */
	phone?: string | null;
	role: "owner" | "member";
	/** «مساعد»: may start/pause/resume and manage the invite link. */
	co_leader?: boolean;
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
	/** Battery Status API reading from their heartbeat; null where the phone cannot tell (iOS). */
	battery?: Battery | null;
	/** An active call for help, until they say «أنا بخير». */
	sos?: Sos | null;
};

export type MemberNote = { text: string; at: string };

export type Battery = { level: number; charging: boolean; at: string };

/** The sender's last real fix at the moment of the SOS, with that fix's own time. */
export type SosFix = { lat: number; lng: number; accuracy: number | null; recorded_at: string };
export type Sos = { at: string; fix: SosFix | null };

export type Rally = { lat: number; lng: number; label: string | null; set_at: string | null; set_by: string | null };

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
		/** «قفل الانضمام»: invite links admit nobody new. */
		join_locked?: boolean;
		created_at: string;
		started_at: string | null;
		ended_at: string | null;
		/** The owner's meeting pin («نقطة التجمع»), if any. */
		rally?: Rally | null;
	};
	me: { user_id: string; role: "owner" | "member"; co_leader?: boolean; can_lead?: boolean; sharing: boolean };
	members: Member[];
	positions: Position[];
	invite: { active: boolean; expires_at: string | null; open_links?: boolean } | null;
	/** Leaders only: one line per person invited personally. */
	personal_invites?: PersonalInvite[] | null;
	/** Push-to-talk clips still held (10 min, memory only on the server). */
	voice_clips?: ClipMeta[];
	/** Once ended: the totals people chose to share («شارك ملخصي»). */
	summaries?: SharedSummary[];
	/** «المحادثات»: my unread chat messages in this outing. */
	chat_unread?: number;
	server_now: string;
};

/** One person's opt-in totals — never a point. */
export type SharedSummary = TripTotals & { user_id: string; display_name: string; shared_at: string };

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
	summaries?: SharedSummary[];
};

export type InvitePreview = {
	outing_id: string;
	name: string;
	status: OutingStatus;
	owner_name: string;
	member_count: number;
	expires_at: string;
	join_locked?: boolean;
	/** "personal": one link for one person — whoever joins becomes `invitee_name` in the trip. */
	kind?: "group" | "personal";
	invitee_name?: string | null;
	/** open · yours (used by you: rejoin) · taken (used by someone else) · claimed (used; anonymous viewer). */
	claim?: "open" | "yours" | "taken" | "claimed";
	already_member?: boolean;
};

/** «دعوة شخصية» as the leader sees it. */
export type PersonalInvite = {
	id: string;
	kind: "personal";
	invitee_name: string;
	phone_last4: string | null;
	status: "sent" | "opened" | "joined" | "expired" | "revoked";
	opened: boolean;
	created_at: string;
	expires_at: string;
	member_user_id: string | null;
	token?: string;
};

export type RecoveryStatus = { active: boolean; created_at: string | null };

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

/** Keep-the-screen-on during an outing: on unless this device saved "off". */
export function loadWakeLock(): boolean {
	return wakePreference(safeGet("localStorage", WAKE_KEY));
}

export function saveWakeLock(on: boolean): void {
	safeSet("localStorage", WAKE_KEY, on ? "1" : "0");
}

/** Gap alert distance in km; 0 = off. Default 3. */
export function loadGapKm(): number {
	const n = Number(safeGet("localStorage", GAP_KEY));
	return safeGet("localStorage", GAP_KEY) != null && Number.isFinite(n) && n >= 0 && n <= 50 ? n : 3;
}

export function saveGapKm(km: number): void {
	safeSet("localStorage", GAP_KEY, String(km));
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
	async updateProfile(patch: { display_name?: string; avatar?: string | null; phone?: string | null }): Promise<PublicUser> {
		const r = await call<{ user: PublicUser }>("PATCH", "/me", patch);
		const cur = loadIdentity();
		if (cur) saveIdentity({ ...cur, user: r.user });
		return r.user;
	},
	recoveryStatus: () => call<{ user: PublicUser; recovery: RecoveryStatus }>("GET", "/me").then((r) => r.recovery),
	/** A new recovery code, shown once. Replaces any earlier one. */
	createRecoveryCode: () => call<{ recovery: { code: string; created_at: string } }>("POST", "/me/recovery").then((r) => r.recovery),
	/** Redeem a recovery code on this device: the old device's key stops working. */
	async recover(code: string): Promise<Identity> {
		const r = await call<{ user: PublicUser; token: string }>("POST", "/me/recover", { code }, { auth: false });
		const id = { token: r.token, user: r.user };
		saveIdentity(id);
		return id;
	},
	list: () => call<{ current: OutingSummary[]; history: OutingSummary[] }>("GET", ""),
	async create(name: string): Promise<{ outing_id: string; invite: { token: string; expires_at: string } }> {
		const r = await call<{ outing_id: string; invite: { token: string; expires_at: string } }>("POST", "", { name });
		saveInviteToken(r.outing_id, r.invite.token);
		return r;
	},
	get: (id: string) => call<OutingSnapshot>("GET", `/${id}`),
	poll: (id: string) => call<OutingSnapshot>("GET", `/${id}/live`),
	heartbeat: (id: string, gps: GpsState, battery?: { level: number; charging: boolean } | null) =>
		call<{ ok: true }>("POST", `/${id}/heartbeat`, battery ? { gps, battery } : { gps }, { timeoutMs: 8_000 }),
	sendPosition: (id: string, fix: unknown) => call<{ ok: true }>("POST", `/${id}/positions`, { fix }, { timeoutMs: 8_000 }),
	/** Opt-in field-test aggregates: numbers only, re-validated by the server. */
	sendDiagnostics: (id: string, report: unknown) => call<{ ok: true }>("POST", `/${id}/diagnostics`, { report }),
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
	sos: (id: string, fix: unknown | null) => call<{ sos: Sos }>("POST", `/${id}/sos`, { fix }),
	cancelSos: (id: string) => call<{ sos: null }>("DELETE", `/${id}/sos`),
	setRally: (id: string, rally: { lat: number; lng: number; label?: string | null }) => call<{ rally: Rally }>("PUT", `/${id}/rally`, rally),
	clearRally: (id: string) => call<{ rally: null }>("DELETE", `/${id}/rally`),
	setSharing: (id: string, sharing: boolean) => call<{ sharing: boolean }>("PATCH", `/${id}/me`, { sharing }),
	/** Push-to-talk: the recording itself is the body; its length rides in a header. */
	async uploadClip(id: string, blob: Blob, durationMs: number): Promise<ClipMeta> {
		const ident = loadIdentity();
		const controller = new AbortController();
		const timer = setTimeout(() => controller.abort(), 20_000);
		let res: Response;
		try {
			res = await fetch(`${API_BASE_URL}/api/outings/${id}/clips`, {
				method: "POST",
				signal: controller.signal,
				headers: {
					accept: "application/json",
					"content-type": blob.type || "application/octet-stream",
					"x-clip-duration-ms": String(Math.round(durationMs)),
					...(ident ? { authorization: `Bearer ${ident.token}` } : {}),
				},
				body: blob,
			});
		} catch {
			throw new OutingApiError(controller.signal.aborted ? "timeout" : "network", 0);
		} finally {
			clearTimeout(timer);
		}
		const json = (await res.json().catch(() => null)) as { ok?: boolean; error?: string; clip?: ClipMeta } | null;
		if (!res.ok || !json?.clip) throw new OutingApiError(json?.error || `http_${res.status}`, res.status);
		return json.clip;
	},
	/** A clip's bytes, with the member's token; gone after its ten minutes. */
	async fetchClip(url: string): Promise<Blob> {
		const ident = loadIdentity();
		let res: Response;
		try {
			res = await fetch(`${API_BASE_URL}${url}`, { headers: ident ? { authorization: `Bearer ${ident.token}` } : {} });
		} catch {
			throw new OutingApiError("network", 0);
		}
		if (!res.ok) throw new OutingApiError(res.status === 404 ? "clip_gone" : `http_${res.status}`, res.status);
		return res.blob();
	},
	shareSummary: (id: string, summary: TripTotals) => call<{ summary: SharedSummary }>("PUT", `/${id}/summary`, { summary }),
	withdrawSummary: (id: string) => call<{ withdrawn: boolean }>("DELETE", `/${id}/summary`),
	leave: (id: string) => call<{ ended: boolean }>("POST", `/${id}/leave`),
	removeMember: (id: string, userId: string) => call("DELETE", `/${id}/members/${userId}`),
	setCoLeader: (id: string, userId: string, co_leader: boolean) =>
		call<{ user_id: string; co_leader: boolean }>("POST", `/${id}/members/${userId}/co-leader`, { co_leader }),
	setJoinLock: (id: string, locked: boolean) => call<{ join_locked: boolean }>("POST", `/${id}/lock`, { locked }),
	/* With this device's identity when there is one, so a used personal invite can say «yours» or «taken». */
	previewInvite: (token: string) => call<{ invite: InvitePreview }>("POST", "/invites/preview", { token }),
	join: (token: string) => call<{ outing_id: string; already: boolean }>("POST", "/invites/join", { token }),
};

/** Error codes → a sentence a person can act on. */
export function outingErrorText(code: string, isRTL: boolean): string {
	const ar: Record<string, string> = {
		invite_invalid: "رابط الدعوة غير صحيح.",
		invite_expired: "انتهت صلاحية رابط الدعوة. اطلب من أمير الرحلة رابطًا جديدًا.",
		invite_revoked: "ألغى أمير الرحلة هذا الرابط. اطلب رابطًا جديدًا.",
		invite_taken: "هذه الدعوة لشخص آخر. اطلب من أمير الرحلة دعوة باسمك.",
		open_links_disabled: "أوقف أمير الرحلة الرابط المفتوح. اطلب منه دعوة شخصية باسمك.",
		invite_used: "استُخدمت هذه الدعوة، وصاحبها في الطلعة.",
		invite_replaced: "أُرسلت لهذا الشخص دعوة أحدث.",
		invite_not_found: "لم نجد هذه الدعوة.",
		invalid_invitee_name: "اكتب اسم الشخص كما تعرفه.",
		too_many_invites: "وصلت الحد الأعلى للدعوات في هذه الطلعة.",
		outing_ended: "انتهت هذه الطلعة.",
		outing_full: "اكتمل عدد المشاركين في هذه الطلعة.",
		removed_from_outing: "أزالك أمير الرحلة منها، فلا يمكنك الانضمام مرة ثانية.",
		not_a_member: "لست عضوًا في هذه الطلعة.",
		owner_only: "هذا الإجراء لأمير الرحلة فقط.",
		leader_only: "هذا الإجراء لأمير الرحلة أو نائبه فقط.",
		join_locked: "قفل أمير الرحلة الانضمام، فلا يمكن لأحد جديد الدخول الآن.",
		recovery_invalid: "رمز الاسترجاع غير صحيح أو استُخدم من قبل.",
		invalid_name: "اكتب اسمًا يظهر لأصحابك.",
		invalid_outing_name: "اكتب اسمًا للطلعة.",
		rate_limited: "محاولات كثيرة. انتظر قليلًا ثم أعد المحاولة.",
		too_frequent: "انتظر ثانيتين ثم أرسل.",
		invalid_note: "اكتب عبارة قصيرة.",
		invalid_phone: "اكتب رقم جوال صحيح، مثل 05XXXXXXXX.",
		invalid_rally: "تعذّر تحديد نقطة التجمع. حرّك الخريطة وأعد المحاولة.",
		sos_fix_stale: "آخر موقع لك قديم جدًا؛ أُرسل النداء بدون موقع.",
		invalid_fix: "تعذّر قراءة موقعك.",
		network: "لا يوجد اتصال بالإنترنت.",
		timeout: "الشبكة بطيئة. أعد المحاولة.",
		outings_unconfigured: "الطلعات المشتركة غير مفعّلة على الخادم.",
		unauthorized: "انتهت جلستك على هذا الجهاز. ادخل باسمك مرة ثانية.",
		too_large: "المقطع الصوتي أكبر من المسموح.",
		invalid_clip: "تعذّر قراءة التسجيل. أعد المحاولة.",
		invalid_clip_duration: "المقطع قصير جدًا أو أطول من ١٥ ثانية.",
		clip_gone: "انتهت صلاحية الرسالة الصوتية (١٠ دقائق).",
		outing_not_ended: "الملخص يُشارك بعد انتهاء الطلعة.",
		summary_window_closed: "مضى أكثر من أسبوع على الطلعة.",
		implausible_summary: "الملخص غير منطقي، لم يُرسل.",
		invalid_summary: "الملخص غير صالح.",
	};
	const en: Record<string, string> = {
		invite_invalid: "This invite link is not valid.",
		invite_expired: "This invite has expired. Ask for a new link.",
		invite_revoked: "This invite was cancelled. Ask for a new link.",
		invite_taken: "This invite is for someone else. Ask the leader for one in your name.",
		open_links_disabled: "The leader turned the open link off. Ask for a personal invite.",
		invite_used: "This invite was already used; that person is in the outing.",
		invite_replaced: "A newer invite was sent to this person.",
		invite_not_found: "Invite not found.",
		invalid_invitee_name: "Enter the person's name as you know them.",
		too_many_invites: "This outing reached the invite limit.",
		outing_ended: "This outing has ended.",
		outing_full: "This outing is full.",
		removed_from_outing: "You were removed from this outing and cannot rejoin.",
		not_a_member: "You are not a member of this outing.",
		owner_only: "Only the outing owner can do that.",
		leader_only: "Only the owner or a co-leader can do that.",
		join_locked: "The owner locked joining; nobody new can join right now.",
		recovery_invalid: "That recovery code is wrong or was already used.",
		invalid_name: "Enter a name your friends will see.",
		invalid_outing_name: "Name the outing.",
		rate_limited: "Too many attempts. Wait a moment.",
		too_frequent: "Wait a couple of seconds, then send.",
		invalid_note: "Write a short line.",
		invalid_phone: "Enter a valid phone number, e.g. +9665XXXXXXXX.",
		invalid_rally: "Could not set the rally point. Move the map and try again.",
		sos_fix_stale: "Your last position is too old; the alert went out without it.",
		invalid_fix: "Could not read your position.",
		network: "You are offline.",
		timeout: "The network is slow. Try again.",
		outings_unconfigured: "Shared outings are not enabled on the server.",
		unauthorized: "Your session on this device ended. Enter your name again.",
		too_large: "That voice clip is too large.",
		invalid_clip: "Could not read the recording. Try again.",
		invalid_clip_duration: "Too short, or longer than 15 seconds.",
		clip_gone: "That voice message expired (10 minutes).",
		outing_not_ended: "Summaries are shared after the outing ends.",
		summary_window_closed: "The outing ended more than a week ago.",
		implausible_summary: "That summary does not add up; not sent.",
		invalid_summary: "That summary is not valid.",
	};
	return (isRTL ? ar : en)[code] || (isRTL ? "حدث خطأ. أعد المحاولة." : "Something went wrong. Try again.");
}
