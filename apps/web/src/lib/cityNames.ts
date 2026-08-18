/**
 * Localize raw backend city slugs ("riyadh", lowercase) for display. The
 * discovery/search payloads carry English lowercase city codes; the Arabic UI
 * was printing them verbatim (QA: chip said "riyadh" under an Arabic card).
 * Unknown cities fall back to Title Case rather than raw lowercase.
 */
const CITY_NAMES_AR: Record<string, string> = {
	riyadh: "الرياض",
	jeddah: "جدة",
	makkah: "مكة المكرمة",
	mecca: "مكة المكرمة",
	madinah: "المدينة المنورة",
	medina: "المدينة المنورة",
	dammam: "الدمام",
	khobar: "الخبر",
	alkhobar: "الخبر",
	dhahran: "الظهران",
	jubail: "الجبيل",
	taif: "الطائف",
	abha: "أبها",
	tabuk: "تبوك",
	buraydah: "بريدة",
	buraidah: "بريدة",
	unaizah: "عنيزة",
	unayzah: "عنيزة",
	onaizah: "عنيزة",
	bukayriyah: "البكيرية",
	"al bukayriyah": "البكيرية",
	mithnab: "المذنب",
	"al mithnab": "المذنب",
	badayea: "البدائع",
	"al badayea": "البدائع",
	"riyadh al khabra": "رياض الخبراء",
	zulfi: "الزلفي",
	hail: "حائل",
	"khamis mushait": "خميس مشيط",
	najran: "نجران",
	jazan: "جازان",
	jizan: "جازان",
	yanbu: "ينبع",
	alkharj: "الخرج",
	kharj: "الخرج",
	hofuf: "الهفوف",
	ahsa: "الأحساء",
	alahsa: "الأحساء",
	qatif: "القطيف",
};

function titleCase(value: string): string {
	return value
		.split(/\s+/)
		.map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w))
		.join(" ");
}

export function localizeCity(
	raw: string | null | undefined,
	isRTL: boolean,
): string {
	const trimmed = (raw ?? "").trim();
	if (!trimmed) return "";
	// Already Arabic (or any non-Latin) — pass through untouched.
	if (/[؀-ۿ]/.test(trimmed)) return trimmed;
	const key = trimmed.toLowerCase().replace(/[_-]+/g, " ").trim();
	if (isRTL) return CITY_NAMES_AR[key] ?? titleCase(trimmed);
	return titleCase(trimmed);
}
