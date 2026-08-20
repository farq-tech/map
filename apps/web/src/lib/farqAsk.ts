/**
 * "اسأل فرق" — the client side of the copilot contract.
 *
 * One input serves search and questions: a couple of words filter the map,
 * a sentence goes to the copilot. The copilot answers from rows it returns
 * and proposes exactly one validated map action; the app executes it.
 */

export type CopilotActionType =
	| "NOOP"
	| "FOCUS_PLACE"
	| "SHOW_RESULTS"
	| "FIT_BOUNDS"
	| "SET_FILTER"
	| "SET_CATEGORY"
	| "SET_SEARCH"
	| "RETURN_TO_USER";

export type CopilotAction = {
	type: CopilotActionType;
	place_id?: string;
	place_ids?: string[];
	bbox?: [number, number, number, number] | null;
	min_gap?: number;
	category?: string;
	q?: string;
};

export type CopilotRow = {
	id: string;
	place_id: string;
	name: string | null;
	name_en?: string | null;
	product_name: string | null;
	gap: number | null;
	pct: number | null;
	tier: string | null;
	cheapest_provider_id: string | null;
	cheapest_price: number | null;
	expensive_provider_id: string | null;
	expensive_price: number | null;
	provider_count: number | null;
	lat: number;
	lng: number;
	distance_m?: number;
};

export type CopilotResponse = {
	ok: boolean;
	session_id: string;
	intent: string;
	answer: string;
	action: CopilotAction;
	results: CopilotRow[];
	model: string;
	total?: number;
	refused?: string | null;
	clarification?: string | null;
	/** Where the answer looked; a `district_id` is a حي the map can select itself. */
	scope?: {
		kind: string;
		label?: string | null;
		district_id?: string | null;
		bbox?: [number, number, number, number] | null;
	} | null;
};

export type CopilotContext = {
	bbox?: string;
	zoom?: number;
	selected_place_id?: string;
	user_lat?: number;
	user_lng?: number;
	city?: string;
};

/* JS \b is ASCII-only; Arabic needs an explicit boundary. */
const QUESTION_WORDS =
	/^(وين|فين|وش|ايش|إيش|ايه|كم|أبي|ابي|أبغى|ابغى|ودي|ورني|وريني|خذني|وديني|ليش|ليه|قارن|أي|اي|هل|رجعني|رجّعني|what|where|which|how|why|show|take|compare|is|are|find)(\s|$)/u;

/** A couple of words filter the map; anything that reads like a sentence is a question. */
export function looksLikeQuestion(text: string): boolean {
	const t = String(text || "").trim();
	if (!t) return false;
	if (/[؟?]/.test(t)) return true;
	if (QUESTION_WORDS.test(t)) return true;
	return t.split(/\s+/).length >= 4;
}

export const FOLLOW_UPS: Array<{ id: string; ar: string; en: string }> = [
	{ id: "cheapest", ar: "الأرخص؟", en: "Cheapest?" },
	{ id: "why", ar: "ليش؟", en: "Why?" },
	{ id: "goto", ar: "خذني له", en: "Take me there" },
	{ id: "top5", ar: "ورني أفضل 5", en: "Show top 5" },
	{ id: "apps", ar: "أي تطبيق أرخص حولي؟", en: "Which app is cheapest here?" },
];

export const SESSION_KEY = "farq.copilot.session";

export function readSessionId(): string | undefined {
	try {
		return window.sessionStorage.getItem(SESSION_KEY) || undefined;
	} catch {
		return undefined;
	}
}

export function writeSessionId(id: string): void {
	try {
		window.sessionStorage.setItem(SESSION_KEY, id);
	} catch {
		/* private mode — the session simply does not persist across reloads */
	}
}

export async function askCopilot(opts: {
	message: string;
	sessionId?: string;
	language: "ar" | "en";
	context: CopilotContext;
	signal?: AbortSignal;
}): Promise<CopilotResponse> {
	const res = await fetch("/api/copilot", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({
			message: opts.message,
			session_id: opts.sessionId,
			language: opts.language,
			context: opts.context,
		}),
		signal: opts.signal,
	});
	if (!res.ok) throw new Error(`copilot_http_${res.status}`);
	const body = (await res.json()) as CopilotResponse;
	if (!body || typeof body !== "object" || !body.ok) throw new Error("copilot_bad_response");
	if (body.session_id) writeSessionId(body.session_id);
	return body;
}
