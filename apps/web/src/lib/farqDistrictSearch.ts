/**
 * Finding a حي by name — the way people type it, not the way the file spells it.
 *
 * "حي النرجس", "النرجس", "نرجس", "Al Narjas", "narjas" all mean one district.
 * Digits, hamza forms, taa marbuta, alef maqsura, diacritics and the article
 * are normalised on both sides; a prefix match outranks a substring match;
 * ties go to the حي with more observed opportunities. Nothing is guessed: an
 * unmatched query returns nothing.
 */
import type { CityDistricts } from "../services/intelligenceService";

export type DistrictFeature = CityDistricts["features"][number];

/**
 * Verbatim mirror of `normalizeArabic` in apps/api/lib/arabic-text.js, plus the
 * حي / district prefix strip this picker needs.
 *
 * It is a hand-kept copy because the web must not import the server's CommonJS,
 * and both sides carry the same vector list in their tests so a change to one
 * fails the other. Before this was a mirror the two disagreed on 7 of 17 real
 * inputs, and the web side had a genuine defect: decomposing an Arabic hamza
 * carrier before the punctuation pass turned the combining hamza into a space,
 * so «مؤسسة» became «مو سسه» and split one district name into two tokens.
 *
 * The pass order below is load-bearing. Do not reorder it to be tidier.
 */
export function normalizeDistrictText(raw: string): string {
	let s = String(raw || "");
	/* 1. Presentation forms (U+FE70–FEFF) → base letters. They arrive from PDFs
	 *    and legacy exports, look identical on screen, and compare unequal. */
	s = s.normalize("NFKC");
	/* 2. Invisible bidi controls, which no human inspecting the data can see. */
	s = s.replace(/[\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069\u200b-\u200d]/g, "");
	/* 3. Tashkeel and the Quranic marks that ride along with copied text. */
	s = s.replace(/[\u064b-\u0652\u0653-\u0655\u0670\u0656-\u065f\u06d6-\u06ed]/g, "");
	/* 4. Tatweel: a typographic stretch with no phonetic value. */
	s = s.replace(/\u0640/g, "");
	/* 5. Both Arabic-Indic digit systems. Folding one and not the other is worse
	 *    than folding neither, because it looks handled. */
	s = s.replace(/[\u0660-\u0669]/g, (ch) => String(ch.charCodeAt(0) - 0x0660));
	s = s.replace(/[\u06f0-\u06f9]/g, (ch) => String(ch.charCodeAt(0) - 0x06f0));
	/* 6. Letter folding, the retrieval direction: every distinction a person is
	 *    likely to get wrong. Carriers are folded BEFORE any decomposition. */
	s = s
		.replace(/[أإآٱٲٳ]/g, "ا")
		.replace(/ة/g, "ه")
		.replace(/[ىیئ]/g, "ي")
		.replace(/ؤ/g, "و")
		.replace(/ء/g, "")
		.replace(/پ/g, "ب").replace(/چ/g, "ج").replace(/ڤ/g, "ف")
		.replace(/ژ/g, "ز").replace(/[گک]/g, "ك").replace(/[ھہ]/g, "ه");
	/* 7. Latin diacritics — «Al Narjās» and «Al Narjas» are one name. Safe here
	 *    only because step 6 already removed every Arabic hamza carrier. */
	s = s.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
	s = s.toLowerCase();
	/* 8. Three or more of a letter collapse to one — «كووول» is «كول». Two is
	 *    left alone, because doubling is legitimate in both scripts. */
	s = s.replace(/(.)\1{2,}/gu, "$1");
	/* 9. Anything that is not a letter or a digit separates rather than joins. */
	s = s.replace(/[^\p{L}\p{N}]+/gu, " ").trim().replace(/\s+/g, " ");
	/* 10. The type word says what kind of place, not which one. */
	return s.replace(/^حي\s+/, "").replace(/^district\s+/, "");
}

function stripArticle(s: string): string {
	return s.replace(/^ال/, "").replace(/^al[\s-]?/, "");
}

function keysOf(f: DistrictFeature): string[] {
	const ar = normalizeDistrictText(f.properties.name_ar);
	const en = normalizeDistrictText(f.properties.name_en);
	return [...new Set([ar, stripArticle(ar), en, stripArticle(en)].filter((k) => k.length >= 2))];
}

/** Busiest first; among equals the bigger gap, then a stable name order. */
export function rankDistricts(features: readonly DistrictFeature[]): DistrictFeature[] {
	return [...features].sort(
		(a, b) =>
			b.properties.opportunities - a.properties.opportunities ||
			(b.properties.max_gap || 0) - (a.properties.max_gap || 0) ||
			a.properties.name_ar.localeCompare(b.properties.name_ar, "ar"),
	);
}

export function filterDistricts(
	features: readonly DistrictFeature[] | null | undefined,
	query: string,
): DistrictFeature[] {
	if (!features?.length) return [];
	const ranked = rankDistricts(features);
	const q = normalizeDistrictText(query);
	if (!q) return ranked;
	const qs = stripArticle(q);
	const scored: Array<{ f: DistrictFeature; score: number }> = [];
	for (const f of ranked) {
		const keys = keysOf(f);
		let score = Infinity;
		for (const k of keys) {
			if (k === q || k === qs) score = Math.min(score, 0);
			else if (k.startsWith(q) || (qs && k.startsWith(qs))) score = Math.min(score, 1);
			else if (k.includes(q) || (qs.length >= 3 && k.includes(qs))) score = Math.min(score, 2);
		}
		if (Number.isFinite(score)) scored.push({ f, score });
	}
	/* stable: ranked order already encodes opportunities; only the match quality reorders */
	return scored.sort((a, b) => a.score - b.score).map((s) => s.f);
}

export function districtDisplayName(f: DistrictFeature | null | undefined, isRTL: boolean): string {
	if (!f) return "";
	return isRTL ? f.properties.name_ar : f.properties.name_en;
}

/**
 * What tells this حي apart from the other one with the same name — a nearby
 * district, chosen server-side. Null for the 734 of 740 أحياء whose name is
 * already unique, so the list stays clean everywhere it can.
 */
export function districtDisambiguation(
	f: DistrictFeature | null | undefined,
	isRTL: boolean,
): string | null {
	if (!f) return null;
	const hint = isRTL ? f.properties.name_hint_ar : f.properties.name_hint_en;
	if (!hint) return null;
	return isRTL ? `قرب ${hint}` : `near ${hint}`;
}
