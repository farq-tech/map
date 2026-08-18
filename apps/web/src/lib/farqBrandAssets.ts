/**
 * Canonical Farq identity — official Arabic wordmark letterforms.
 * Source: /brand/farq-wordmark-mint.svg (launch splash / app icon).
 * Do not invent a second logo. Recolor only (mint on dark, brand-900 on light).
 */

/** Official mint Arabic «فرق» wordmark. */
export const FARQ_WORDMARK_SRC = "/brand/farq-wordmark-mint.svg";

export const FARQ_BRAND_900 = "#043434";
export const FARQ_MINT = "#83F1B1";

/**
 * Official «ف» — first path of farq-wordmark-mint.svg (viewBox 0 0 480 223).
 * Used as the compact circular mark; never a random font «ف».
 */
export const FARQ_FAA_PATH =
	"M95.5686 36.8074H43.6112V64.5698H90.9455V101.145H43.6112V166.365H0.459961V0.231567H95.5686V36.8074";

/** Center the official ف in a 32×32 circle with padding. */
const FARQ_FAA_TRANSFORM = "translate(10.82 7.02) scale(0.1079)";

export function farqCircleMarkSvg(size = 32): string {
	const s = Math.max(8, Math.round(size));
	return `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 32 32" class="farq-brand-mark" focusable="false" aria-hidden="true"><circle cx="16" cy="16" r="16" fill="${FARQ_BRAND_900}"/><g transform="${FARQ_FAA_TRANSFORM}"><path fill="${FARQ_MINT}" d="${FARQ_FAA_PATH}"/></g></svg>`;
}

export function buildFarqCircleMarkElement(size = 10): HTMLElement {
	const wrap = document.createElement("span");
	wrap.className = "farq-brand-mark-host";
	wrap.setAttribute("aria-hidden", "true");
	wrap.insertAdjacentHTML("afterbegin", farqCircleMarkSvg(size));
	return wrap;
}
