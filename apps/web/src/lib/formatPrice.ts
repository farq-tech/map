interface FormatPriceOptions {
	isRTL?: boolean;
	freeWhenZero?: boolean;
	withCurrency?: boolean;
	/**
	 * Accepted for backward compatibility with existing call sites, but IGNORED:
	 * prices are always rendered as whole riyals (see below). Kept in the type so
	 * callers that still pass `decimals` keep compiling.
	 */
	decimals?: number;
}

/**
 * Localise a number's digits: Arabic-Indic (٠١٢٣) when `isRTL`, Western otherwise.
 * Use for counts, ETAs, ratings, percents — anything shown next to Arabic/English copy.
 * Non-integers keep a short fraction (e.g. ٤٫٥ / 4.5).
 */
export function localizeDigits(value: number, isRTL: boolean): string {
	if (!Number.isFinite(value)) return String(value);
	const locale = isRTL ? "ar-SA" : "en-US";
	const fractionDigits = Number.isInteger(value) ? 0 : 2;
	return value.toLocaleString(locale, {
		useGrouping: false,
		maximumFractionDigits: fractionDigits,
		minimumFractionDigits: 0,
	});
}

const ARABIC_INDIC_DIGITS = "٠١٢٣٤٥٦٧٨٩";

/**
 * Localise digit characters inside an arbitrary string (sizes like "500ml",
 * "1.5L"). Non-digit characters are left untouched.
 */
export function localizeDigitString(value: string, isRTL: boolean): string {
	const s = String(value ?? "");
	if (!isRTL || !s) return s;
	return s.replace(/[0-9]/g, (d) => ARABIC_INDIC_DIGITS[Number(d)] ?? d);
}

/** Ratings always show one decimal (4.0 / ٤٫٠) with locale digits. */
export function localizeRating(value: number, isRTL: boolean): string {
	if (!Number.isFinite(value)) return String(value);
	const locale = isRTL ? "ar-SA" : "en-US";
	return value.toLocaleString(locale, {
		useGrouping: false,
		minimumFractionDigits: 1,
		maximumFractionDigits: 1,
	});
}

export function toNumericPrice(
	value: number | string | null | undefined,
): number {
	if (typeof value === "number") {
		return Number.isFinite(value) ? value : 0;
	}

	if (typeof value === "string") {
		const parsed = Number.parseFloat(value);
		return Number.isFinite(parsed) ? parsed : 0;
	}

	return 0;
}

export function toNumericPriceOrNull(
	value: number | string | null | undefined,
): number | null {
	if (typeof value === "number") {
		return Number.isFinite(value) ? value : null;
	}
	if (typeof value === "string") {
		const parsed = Number.parseFloat(value);
		return Number.isFinite(parsed) ? parsed : null;
	}
	return null;
}

/**
 * Compact price for tight UI (chips, mini store rows, deal badges). Prices are
 * shown as whole riyals (rounded to the nearest integer) — no halalas.
 *
 * Digits follow the locale: Arabic-Indic (٠١٢٣) when `isRTL`, Western otherwise
 * — so the grocery card matches the restaurant menu (which already localises
 * via `formatPrice`) instead of mixing Western chips under an Arabic headline.
 * `isRTL` defaults to false, so every existing Western-digit call site is
 * unchanged.
 *
 * Crucially it coerces first via toNumericPrice, so a string price from the
 * API (grocery `storePrices[].price`, `lowestPrice`; restaurant `price` is
 * typed `string | number`) can never reach a numeric method on a non-number.
 * That exact gap produced the production crash "s.toFixed is not a function".
 */
export function formatCompactPrice(
	value: number | string | null | undefined,
	isRTL = false,
): string {
	const amount = Math.round(toNumericPrice(value));
	return isRTL
		? amount.toLocaleString("ar-SA", { useGrouping: false })
		: amount.toString();
}

export function formatPrice(
	value: number | string | null | undefined,
	{
		isRTL = false,
		freeWhenZero = false,
		withCurrency = false,
	}: FormatPriceOptions = {},
): string {
	// Product decision: prices are always whole riyals — round to the nearest
	// integer and never show halalas (the `decimals` option is ignored).
	const amount = Math.round(toNumericPrice(value));

	if (freeWhenZero && amount === 0) {
		return isRTL ? "مجاني" : "Free";
	}

	const locale = isRTL ? "ar-SA" : "en-US";
	const displayValue = amount.toLocaleString(locale, {
		maximumFractionDigits: 0,
		useGrouping: false,
	});

	if (!withCurrency) {
		return displayValue;
	}

	return isRTL ? `${displayValue} ريال` : `${displayValue} SAR`;
}
