'use strict';

/**
 * Arabic text normalization for matching — not for display.
 *
 * There are two opposite normalizations of Arabic and conflating them is a real
 * source of bugs. The DISPLAY direction restores orthography: it puts the hamza
 * back on أحمد, keeps ة distinct from ه, writes مستشفى with alif maqsura. The
 * RETRIEVAL direction does the opposite — it folds every distinction a user is
 * likely to get wrong, so «الروضه» finds «الروضة» and «مستشفي» finds «مستشفى».
 *
 * Everything here is the retrieval direction. It must never touch what we show.
 *
 * The rule that makes it work: the SAME function normalizes the stored value and
 * the query. Two functions drift, and the drift is invisible — a name indexed
 * with Arabic-Indic digits never matches a query normalized to ASCII ones.
 */

/* Tashkeel, plus the dagger alif and the Quranic marks that ride along with
 * copy-pasted names. U+064B–U+0652 is the common set; U+0670 and U+0653–U+0655
 * show up in text lifted from religious sources, which is common in place names. */
const DIACRITICS = /[ً-ْٓ-ٰٕۖ-ۭ]/g;

/* Tatweel: a pure typographic stretch with no phonetic value. «الــرياض». */
const TATWEEL = /ـ/g;

/* Bidi controls. These arrive from PDFs, spreadsheets and Windows clipboards and
 * are invisible in every tool a human would inspect the data with. */
const BIDI_CONTROLS = /[‎‏؜‪-‮⁦-⁩​-‍]/g;

/**
 * Arabic Presentation Forms (U+FB50–FDFF, U+FE70–FEFF) are per-position glyph
 * variants that legacy pipelines emit instead of base letters. They look
 * identical on screen and compare unequal. NFKC decomposes them correctly,
 * including the lam-alef ligatures which become two code points.
 */
function foldPresentationForms(value) {
	return value.normalize('NFKC');
}

/* Every digit system that appears in Saudi place names, folded to ASCII.
 * Arabic-Indic ٠-٩ (U+0660) and Eastern Arabic-Indic ۰-۹ (U+06F0). Folding one
 * and not the other is worse than folding neither, because it looks handled. */
function foldDigits(value) {
	let out = '';
	for (const ch of value) {
		const code = ch.codePointAt(0);
		if (code >= 0x0660 && code <= 0x0669) out += String(code - 0x0660);
		else if (code >= 0x06f0 && code <= 0x06f9) out += String(code - 0x06f0);
		else out += ch;
	}
	return out;
}

/**
 * Letter folding, in the retrieval direction.
 *
 * Alif forms collapse because users type ا for all of them. Ta marbuta folds to
 * ha because «الروضة» and «الروضه» are the same place to everyone except a
 * spell-checker. Alif maqsura folds to ya for the same reason. Hamza carriers
 * fold to their base letters. Perso-Arabic letters appear in imported data.
 */
const LETTER_FOLD = new Map(Object.entries({
	'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا', 'ٲ': 'ا', 'ٳ': 'ا',
	'ة': 'ه',
	'ى': 'ي', 'ی': 'ي', 'ئ': 'ي',
	'ؤ': 'و',
	'ء': '',
	'پ': 'ب', 'چ': 'ج', 'ڤ': 'ف', 'ژ': 'ز', 'گ': 'ك', 'ک': 'ك', 'ھ': 'ه', 'ہ': 'ه',
}));

function foldLetters(value) {
	let out = '';
	for (const ch of value) {
		const mapped = LETTER_FOLD.get(ch);
		out += mapped === undefined ? ch : mapped;
	}
	return out;
}

/**
 * Three or more of the same letter collapse to one. «كووول» is «كول» with
 * enthusiasm, and it is a real pattern in restaurant names. Two is left alone
 * because doubled letters are legitimate in both scripts (شدّة written out,
 * "coffee").
 */
const REPEATS = /(.)\1{2,}/gu;

/* Anything that is not a letter or a digit is a separator. Dots, dashes,
 * apostrophes and the Arabic comma all split tokens rather than joining them —
 * «dr.paws» and «dr paws» must reach the same place. */
const NON_WORD = /[^\p{L}\p{N}]+/gu;

/**
 * The full retrieval normalizer. Use it on both sides of every comparison.
 */
function normalizeArabic(input) {
	if (input === null || input === undefined) return '';
	let value = String(input);
	value = foldPresentationForms(value);
	value = value.replace(BIDI_CONTROLS, '');
	value = value.replace(DIACRITICS, '');
	value = value.replace(TATWEEL, '');
	value = foldDigits(value);
	value = foldLetters(value);
	/**
	 * Latin diacritics, folded so «Al Narjās» and «Al Narjas» are one name —
	 * transliterated Saudi place names arrive with macrons and dots from
	 * scholarly sources and without them from everyone else.
	 *
	 * The order matters and is the reason this runs HERE and not earlier.
	 * Compatibility decomposition splits an Arabic hamza carrier into its base
	 * letter plus a combining hamza; if that happens while the punctuation pass
	 * is still ahead, the combining mark becomes a space and «مؤسسة» is torn into
	 * «مو سسه». Folding the Arabic carriers first leaves nothing for the
	 * decomposition to break.
	 */
	value = value.normalize('NFKD').replace(/[\u0300-\u036f]/g, '');
	value = value.toLowerCase();
	value = value.replace(REPEATS, '$1');
	value = value.replace(NON_WORD, ' ');
	return value.trim().replace(/\s+/g, ' ');
}

/**
 * Words that say what KIND of place or road something is. They carry almost no
 * discriminative power — every district contains «حي» — but they carry all of
 * the type information, so they are stripped for comparison and kept for
 * interpretation. «حي النرجس» and «النرجس» must resolve to the same حي.
 *
 * Stored normalized, because that is how they will be compared.
 */
const PLACE_TYPE_WORDS = new Set([
	'حي', 'حى', 'شارع', 'طريق', 'ممر', 'جاده', 'ميدان', 'دوار', 'مخرج',
	'district', 'neighborhood', 'neighbourhood', 'street', 'st', 'road', 'rd',
	'avenue', 'ave', 'exit',
].map(normalizeArabic));

/**
 * Words that say what kind of BUSINESS this is. In a corpus where every row is a
 * restaurant, «مطعم» is the least informative token in the language — it appears
 * in a large share of names and makes «مطعم الشرق» and «مطعم الغرب» look 80%
 * alike to any edit-distance measure, because edit distance has no idea that a
 * token shared by thousands of rows carries no information.
 *
 * A search engine solves this with inverse document frequency. A pure function
 * cannot see the corpus, so it uses the next best thing: an explicit list of the
 * tokens we know are corpus-wide. Keep it short and obvious. A word only belongs
 * here if a customer would never use it alone to mean one specific place.
 */
const VENUE_TYPE_WORDS = new Set([
	'مطعم', 'مطاعم', 'مقهى', 'مقاهي', 'كافيه', 'كافي', 'كوفي',
	'restaurant', 'restaurants', 'cafe', 'caffe', 'coffee', 'shop', 'store',
	'branch', 'فرع',
].map(normalizeArabic));

/** The Arabic definite article, folded as a prefix variant rather than deleted. */
function stripDefiniteArticle(token) {
	return token.length > 3 && token.startsWith('ال') ? token.slice(2) : token;
}

/**
 * Tokens for comparison: normalized, type words removed, definite article folded.
 * Returns [] rather than [''] for empty input so callers can test truthiness.
 */
function nameTokens(input, { stripArticle = true } = {}) {
	const normalized = normalizeArabic(input);
	if (!normalized) return [];
	return normalized
		.split(' ')
		.filter((t) => t && !PLACE_TYPE_WORDS.has(t) && !VENUE_TYPE_WORDS.has(t))
		.map((t) => (stripArticle ? stripDefiniteArticle(t) : t))
		.filter(Boolean);
}

/**
 * Many listings in this data are written «Brand - Branch», where the branch part
 * is a transliterated district: «ترندي كيك - Al Yarmuk». Comparing the whole
 * string makes every two brands at one address look alike, because the branch
 * halves are identical and long — measured, this single pattern produced 5 of
 * the 7 false positives in the first duplicate sweep over Riyadh.
 *
 * So split it. The brand half answers "which chain", the branch half answers
 * "which of its branches", and they must never be averaged into one number.
 *
 * Only a separator with whitespace on both sides counts. A bare hyphen inside a
 * name («بن-دايت») is part of the name, not a delimiter.
 */
const BRANCH_SEPARATOR = /\s[-–—|/]\s|\s[-–—]\s*(?=[A-Za-z])/;

function splitBranchQualifier(input) {
	const value = String(input ?? '').trim();
	if (!value) return { brand: '', branch: '' };
	const match = BRANCH_SEPARATOR.exec(value);
	if (!match) return { brand: value, branch: '' };
	return {
		brand: value.slice(0, match.index).trim(),
		branch: value.slice(match.index + match[0].length).trim(),
	};
}

/** The comparison key: tokens rejoined. Two names with this key equal are the same string to us. */
function matchKey(input) {
	return nameTokens(input).join(' ');
}

/**
 * Which script is this text in? Arabic-Indic digits count as an Arabic signal
 * because they appear in no other script we serve; ASCII digits count for
 * neither, because everyone uses them.
 */
function scriptOf(input) {
	const value = String(input ?? '');
	const arabic = /[؀-ۿݐ-ݿ]/.test(value) || /[٠-٩۰-۹]/.test(value);
	const latin = /[A-Za-z]/.test(value);
	if (arabic && latin) return 'mixed';
	if (arabic) return 'ar';
	if (latin) return 'en';
	return 'none';
}

module.exports = {
	normalizeArabic,
	nameTokens,
	matchKey,
	scriptOf,
	stripDefiniteArticle,
	splitBranchQualifier,
	PLACE_TYPE_WORDS,
	VENUE_TYPE_WORDS,
};
