/**
 * البحث بالنص — يلقى اللي يقصده الشخص، مو اللي كتبه حرفياً.
 *
 * "برجر" لازم توصل لـ"برغر" و"برقر" و"Burger"، "شاورما" لـ"شورما"، "قهوه"
 * لـ"قهوة"، و"٥" لـ"5". الطبقة الأولى تطبيع مطابق حرفياً لـ normalizeArabic
 * في apps/api/lib/copilot-intent.js — لا يجوز يفترقان (فيه اختبار يثبّت المخرجات
 * في الملفين). الطبقة الثانية مرادفات لهجة سعودية مبنية على CATEGORY_GROUPS
 * من نفس ملف الـAPI، بنفس المعرّفات، مزيدة بإملاءات الناس الحقيقية.
 *
 * Kept in step with the API by hand, on purpose: the web must not import the
 * server's CommonJS. Any change there → change here, and both test files shout.
 */

const ARABIC_INDIC = "٠١٢٣٤٥٦٧٨٩";
const EXTENDED_INDIC = "۰۱۲۳۴۵۶۷۸۹";

/* Same five passes, same order, as the API's normalizeArabic — do not "improve" one side alone. */
export function normalizeSearchText(raw: string): string {
	let s = String(raw || "");
	s = s.replace(/[٠-٩]/g, (ch) => String(ARABIC_INDIC.indexOf(ch)));
	s = s.replace(/[۰-۹]/g, (ch) => String(EXTENDED_INDIC.indexOf(ch)));
	s = s.replace(/[ً-ْٰـ]/g, "");
	s = s.replace(/[أإآٱ]/g, "ا").replace(/ة/g, "ه").replace(/ى/g, "ي");
	s = s.replace(/[؟?!.,،;:"'()\[\]{}«»]/g, " ");
	s = s.toLowerCase().replace(/\s+/g, " ").trim();
	return s;
}

/**
 * همزة الواو والياء — الـAPI ما يطبّعها، وتطبيعها هناك يغيّر تصنيف النوايا.
 * فتُطوى هنا فوق التطبيع، حرفاً بحرف (بدون تغيير الطول) حتى يبقى تعليم المطابقة
 * في النص الأصلي دقيقاً، ويبقى normalizeSearchText مطابقاً للـAPI بالضبط.
 */
function foldSearchVariants(norm: string): string {
	return norm.replace(/ؤ/g, "و").replace(/ئ/g, "ي");
}

function searchKey(raw: string): string {
	return foldSearchVariants(normalizeSearchText(raw));
}

/**
 * كلمات الأكل كما ينطقها الناس. المعرّفات والمصطلحات من CATEGORY_GROUPS في
 * apps/api/lib/copilot-intent.js، وزيادتها إملاءات سعودية مسموعة فعلاً —
 * ما نخترع كلمات. (لاحظ أن "همبرجر" يحوي "برجر" أصلاً، فالفائدة بالاتجاه العكسي.)
 */
const SYNONYM_GROUPS: ReadonlyArray<{ id: string; terms: readonly string[] }> = Object.freeze([
	{ id: "burgers", terms: ["برجر", "برغر", "برقر", "همبرجر", "همبرغر", "هامبرجر", "burger"] },
	{ id: "pizza", terms: ["بيتزا", "بيزا", "pizza"] },
	{ id: "coffee", terms: ["قهوة", "قهوه", "كوفي", "كافيه", "لاتيه", "اسبريسو", "coffee", "latte", "cafe"] },
	{ id: "shawarma", terms: ["شاورما", "شورما", "shawarma"] },
	{ id: "chicken", terms: ["دجاج", "دياي", "بروست", "بروستد", "تشكن", "فرايد تشكن", "chicken", "broast"] },
	{ id: "sushi", terms: ["سوشي", "sushi"] },
	{ id: "desserts", terms: ["حلا", "حلى", "حلويات", "كيك", "كيكة", "دونات", "ايس كريم", "dessert", "cake"] },
	{ id: "sandwiches", terms: ["ساندويتش", "ساندوتش", "ساندويش", "سندويش", "sandwich"] },
	{ id: "breakfast", terms: ["فطور", "فول", "breakfast"] },
	{ id: "juice", terms: ["عصير", "عصائر", "juice", "smoothie"] },
	{ id: "pasta", terms: ["باستا", "معكرونة", "مكرونة", "pasta"] },
	{ id: "seafood", terms: ["سمك", "أسماك", "روبيان", "جمبري", "seafood", "fish"] },
	{ id: "grill", terms: ["مشاوي", "مشويات", "كباب", "grill", "kebab"] },
	{ id: "grocery", terms: ["بقالة", "تموين", "سوبرماركت", "grocery"] },
	{ id: "box", terms: ["بوكس", "box"] },
]);

/** The same groups, keyed by every normalised spelling → all its siblings (itself first). */
export const SEARCH_SYNONYMS: Record<string, string[]> = (() => {
	const table: Record<string, string[]> = Object.create(null);
	for (const group of SYNONYM_GROUPS) {
		const keys = [...new Set(group.terms.map(searchKey).filter(Boolean))];
		for (const key of keys) table[key] = [key, ...keys.filter((k) => k !== key)];
	}
	return table;
})();

/** Group ids, for a caller that wants to show الفئة behind a match. */
export const SEARCH_SYNONYM_IDS: Record<string, string> = (() => {
	const table: Record<string, string> = Object.create(null);
	for (const group of SYNONYM_GROUPS) {
		for (const term of group.terms) {
			const key = searchKey(term);
			if (key) table[key] = group.id;
		}
	}
	return table;
})();

/**
 * الاستعلام بعد التطبيع، ومعه إخوانه من المرادفات. كلمة ما نعرفها ترجع وحدها —
 * ما نوسّع كلمة بكلمة داخل جملة، لأن "برجر لحم" ما يصح يطابق كل ما فيه "لحم".
 */
export function expandQuery(query: string): string[] {
	const q = searchKey(query);
	if (!q) return [];
	return SEARCH_SYNONYMS[q] ? [...SEARCH_SYNONYMS[q]] : [q];
}

/**
 * هل يطابق هذا الصف؟ استعلام فاضي = لا فلترة.
 *
 * Hot path: called for ~9,000 rows on every keystroke. So the query is
 * normalised once per call, the regexes are module constants (never built per
 * row), fields are normalised once each, and matching is plain indexOf — no
 * per-row regex, no per-row array building beyond the one normalised string.
 */
export function matchesQuery(haystackFields: Array<string | null | undefined>, query: string): boolean {
	const terms = expandQuery(query);
	if (terms.length === 0) return true;
	for (let f = 0; f < haystackFields.length; f += 1) {
		const raw = haystackFields[f];
		if (!raw) continue;
		const hay = searchKey(raw);
		if (!hay) continue;
		for (let t = 0; t < terms.length; t += 1) {
			if (hay.includes(terms[t])) return true;
		}
	}
	return false;
}

/* التشكيل والتطويل يُحذفان، فمواضعها لازم تُحسب حتى يبقى التعليم على النص الأصلي صحيحاً. */
function isDropped(code: number): boolean {
	return (code >= 0x064b && code <= 0x0652) || code === 0x0670 || code === 0x0640;
}

const PUNCT = new Set('؟?!.,،;:"\'()[]{}«»'.split(""));
const ALEF = new Set([0x0623, 0x0625, 0x0622, 0x0671]);
const WS = /\s/;

/**
 * نفس التطبيع، لكن مع خريطة ترجع من موضع الحرف بعد التطبيع إلى موضعه الأصلي.
 * Returns null when a character does not map one-to-one (a locale-dependent
 * lowercase, say) — better no highlight than a highlight on the wrong letters.
 */
function normalizeWithMap(src: string): { norm: string; map: number[] } | null {
	let norm = "";
	const map: number[] = [];
	let pendingSpaceAt = -1;
	for (let i = 0; i < src.length; i += 1) {
		const ch = src[i];
		const code = src.charCodeAt(i);
		let out: string;
		if (code >= 0x0660 && code <= 0x0669) out = String(code - 0x0660);
		else if (code >= 0x06f0 && code <= 0x06f9) out = String(code - 0x06f0);
		else if (isDropped(code)) continue;
		else if (ALEF.has(code)) out = "ا";
		else if (code === 0x0629) out = "ه";
		else if (code === 0x0649) out = "ي";
		else if (PUNCT.has(ch)) out = " ";
		else out = ch.toLowerCase();
		if (out.length !== 1) return null;
		if (WS.test(out)) {
			/* whitespace runs collapse to one space; leading and trailing runs vanish (trim) */
			if (norm.length > 0 && pendingSpaceAt < 0) pendingSpaceAt = i;
			continue;
		}
		if (pendingSpaceAt >= 0) {
			norm += " ";
			map.push(pendingSpaceAt);
			pendingSpaceAt = -1;
		}
		norm += out;
		map.push(i);
	}
	return { norm, map };
}

function mergeRanges(ranges: Array<[number, number]>): Array<[number, number]> {
	if (ranges.length < 2) return ranges;
	ranges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
	const merged: Array<[number, number]> = [ranges[0]];
	for (let i = 1; i < ranges.length; i += 1) {
		const last = merged[merged.length - 1];
		if (ranges[i][0] <= last[1]) last[1] = Math.max(last[1], ranges[i][1]);
		else merged.push(ranges[i]);
	}
	return merged;
}

/**
 * مواضع المطابقة داخل النص الأصلي، عشان المتصل يعلّمها. المطابقة تصير على النص
 * المطبَّع، فنرجع بالخريطة إلى الأصل؛ وإذا ما ضبطت الخريطة نرجّع فاضي —
 * تعليم غلط أسوأ من بدون تعليم.
 */
export function highlightRanges(text: string, query: string): Array<[number, number]> {
	const src = String(text || "");
	if (!src) return [];
	const terms = expandQuery(query);
	if (terms.length === 0) return [];
	const mapped = normalizeWithMap(src);
	if (!mapped || mapped.norm !== normalizeSearchText(src)) return [];
	const hay = foldSearchVariants(mapped.norm);
	const ranges: Array<[number, number]> = [];
	for (let t = 0; t < terms.length; t += 1) {
		const term = terms[t];
		if (!term) continue;
		let from = 0;
		for (;;) {
			const at = hay.indexOf(term, from);
			if (at < 0) break;
			const start = mapped.map[at];
			let end = mapped.map[at + term.length - 1] + 1;
			/* a diacritic sitting on the last matched letter belongs to it */
			while (end < src.length && isDropped(src.charCodeAt(end))) end += 1;
			ranges.push([start, end]);
			from = at + term.length;
		}
	}
	return mergeRanges(ranges);
}
