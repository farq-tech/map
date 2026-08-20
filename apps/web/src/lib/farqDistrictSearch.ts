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

export function normalizeDistrictText(raw: string): string {
	return String(raw || "")
		.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))
		.replace(/[ً-ْـ]/g, "")
		.replace(/[أإآ]/g, "ا")
		.replace(/ة/g, "ه")
		.replace(/ى/g, "ي")
		.normalize("NFKD")
		.replace(/[̀-ͯ]/g, "")
		.toLowerCase()
		.replace(/[^\p{L}\p{N}\s]/gu, " ")
		.replace(/\s+/g, " ")
		.trim()
		.replace(/^حي\s+/, "")
		.replace(/^district\s+/, "");
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
