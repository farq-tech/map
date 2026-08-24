/**
 * Display-only trim of scraper residue. Same rules as apps/api/lib/consumer-items.js.
 * Source strings stay as observed; the sheet never shows "سعره 250" as a price,
 * "(Cal: 236)" as a dish, or a catalogue SKU as the name.
 */
export function displayItemName(name: unknown): string {
	const raw = String(name || "").trim();
	if (!raw) return "";
	const trimmed = raw
		.replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
		.replace(/\s*[-–—]?\s*(سعره|سعرة|سعرات)\s*[٠-٩0-9]+\s*/g, " ")
		.replace(
			/\s*[\(（]?\s*(?:k\s*)?cal(?:ories)?\s*[:：]?\s*[٠-٩0-9]+\s*[\)）]?\s*/gi,
			" ",
		)
		.replace(/_[٠-٩0-9]{5,}/g, "")
		.replace(/\s*[-–—]?\s*[٠-٩0-9]{6,}(?=$|[\s,،)）])/g, " ")
		.replace(/([\u0600-\u06FF])[0-9]{5,}/g, "$1")
		.replace(/\s*\b0[0-9]{4,}\b\s*/g, " ")
		.replace(/\s{2,}/g, " ")
		.replace(/\s*[-–—]\s*$/, "")
		.replace(/\s*[,،()（）]+\s*$/, "")
		.trim();
	return trimmed || raw;
}
