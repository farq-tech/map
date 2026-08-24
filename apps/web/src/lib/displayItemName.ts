/**
 * Display-only trim of scraper residue. Same rules as apps/api/lib/consumer-items.js.
 * Source strings stay as observed; the sheet never shows "سعره 250" as a price.
 */
export function displayItemName(name: unknown): string {
	const raw = String(name || "").trim();
	if (!raw) return "";
	const trimmed = raw
		.replace(/\s*[-–—]?\s*(سعره|سعرة|سعرات)\s*[٠-٩0-9]+\s*/g, " ")
		.replace(/\s*\bcal\s*[0-9]+\s*/gi, " ")
		.replace(/\s*\b[0-9]{6,}\b\s*/g, " ")
		.replace(/\s{2,}/g, " ")
		.replace(/\s*[,،-]\s*$/, "")
		.trim();
	return trimmed || raw;
}
