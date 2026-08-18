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
 * Official «ف» — rightmost letter of farq-wordmark-mint.svg (viewBox 0 0 480 223).
 * The leftmost subpath is «ق» and reads as a Latin F when isolated — never use it.
 */
export const FARQ_FAA_PATH =
	"M255.212 53.3324H295.06V71.8409C299.316 65.0836 304.527 59.9425 310.691 56.4175C316.856 52.7448 324.048 50.9087 332.267 50.9087C333.294 50.9087 334.395 50.9087 335.57 50.9087C336.89 50.9087 338.358 51.0558 339.973 51.3496V89.4675C334.689 86.8238 328.965 85.5015 322.8 85.5015C313.554 85.5015 306.582 88.2928 301.885 93.8744C297.335 99.3093 295.06 107.315 295.06 117.891V166.365H255.212V53.3324ZM389.663 109.518C389.663 113.19 390.323 116.643 391.645 119.874C392.966 122.959 394.727 125.676 396.928 128.027C399.277 130.377 401.992 132.213 405.074 133.535C408.303 134.857 411.753 135.518 415.422 135.518C418.944 135.518 422.247 134.857 425.329 133.535C428.558 132.213 431.273 130.377 433.475 128.027C435.823 125.676 437.658 122.959 438.979 119.874C440.447 116.643 441.18 113.264 441.18 109.739C441.18 106.213 440.447 102.908 438.979 99.8236C437.658 96.739 435.823 94.0215 433.475 91.6712C431.273 89.3208 428.558 87.4847 425.329 86.1629C422.247 84.8406 418.944 84.1797 415.422 84.1797C411.899 84.1797 408.524 84.8406 405.294 86.1629C402.212 87.4847 399.497 89.3208 397.149 91.6712C394.947 94.0215 393.113 96.739 391.645 99.8236C390.323 102.761 389.663 105.993 389.663 109.518ZM439.859 222.771V155.348C430.613 165.043 418.944 169.891 404.854 169.891C396.782 169.891 389.296 168.348 382.398 165.263C375.5 162.179 369.482 157.919 364.345 152.484C359.354 147.049 355.392 140.733 352.456 133.535C349.667 126.191 348.273 118.405 348.273 110.179C348.273 101.66 349.741 93.7277 352.676 86.3829C355.612 79.0386 359.648 72.6489 364.785 67.214C369.922 61.7786 375.94 57.5188 382.838 54.4342C389.736 51.3496 397.222 49.8072 405.294 49.8072C419.825 49.8072 431.347 55.169 439.859 65.8917V53.3324H479.928V222.771H439.859Z";

/** Leftmost «ق» block — looks like a Latin F. Never paint this as the mark. */
export const FARQ_QAF_BLOCK_PATH =
	"M95.5686 36.8074H43.6112V64.5698H90.9455V101.145H43.6112V166.365H0.459961V0.231567H95.5686V36.8074";

/** Center the official ف in a 32×32 circle with padding. */
export const FARQ_FAA_TRANSFORM = "translate(-13.44 5.08) scale(0.0801)";

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
