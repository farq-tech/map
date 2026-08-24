'use strict';

/**
 * What a person actually orders for dinner.
 *
 * The read layer's biggest observed gaps are dominated by party boxes, trays
 * and bulk packs: 7.1% of Riyadh's gapped items match the sharing lexicon
 * below, but their average gap is 15.6 SAR against 5.5 for everything else
 * (measured 2026-08-20). Ranked by raw gap, that 7% owns the top of every
 * list, and the first thing a person sees is "بوكس المشاركة" — real, but not
 * the decision they came to make.
 *
 * So a restaurant's representative opportunity is the largest observed gap
 * among items **one person plausibly orders**. Sharing items are not deleted
 * and not hidden — they stay in the source, stay in the restaurant's own
 * list, and are still shown when a restaurant has nothing else. They are
 * marked, and they lose the tie. The number on the map is always the observed
 * gap in riyals; nothing here invents a score.
 *
 * The lexicon is deliberately high-precision: a term earns its place only if
 * it almost always means "for a group". Ambiguous words a single person also
 * orders (كومبو، ميكس، تريو، علبة) are left out on purpose — a wrongly
 * demoted dish is a lie about the restaurant, and we would rather miss.
 */

const { CATEGORY_GROUPS, normalizeArabic } = require('./copilot-intent');

/**
 * Written against text that has already been normalised (ة→ه, ى→ي, Arabic-Indic
 * digits → Western). Every construct here exists in both JS RegExp and
 * PostgreSQL ARE, so one pattern drives the SQL and the JS. That rules out
 * `\b` — in Postgres it means backspace, not a word boundary — so English
 * terms match as bare substrings, which is safe for this small vocabulary.
 */
const SHARE_TERM_SOURCES = Object.freeze([
  /* Arabic: containers and occasions that only make sense for a group */
  'بوكس',
  /* Tray-of, not the adjective "Chinese". The following letter must be
   * Arabic — name_ar+' '+name_en would otherwise make "نودلز صينية
   * Chinese Noodles" look like a platter. */
  'صينيه\\s+[ء-ي]',
  'باكيت',
  'كرتون',
  'درزن',
  'دسته',
  'كيلو',
  'جالون',
  'بارتي',
  'بوفيه',
  'مشاركه',
  'عائليه',
  'ضيافه',
  'وليمه',
  'تورته',
  'سفره',
  'عزيمه',
  'دلو',
  'سطل',
  'باكج',
  /* "تريو كبير كومبو" — 25 items, average gap 21.7 SAR against 5.5 city-wide.
   * A trio is three plates; كومبو and ميكس on their own are not, and stay out. */
  'تريو',
  /* "24 قطعة" · "12 عبوة" · "30 كيس" · "5 أشخاص" */
  '[0-9]+\\s*(قطعه|قطع|حبه|حبات|كيس|اكياس|عبوه|عبوات|شخص|اشخاص|سيخ|اسياخ)',
  /* "لـ 5 أشخاص" and the spelled-out forms */
  'ل\\s*[0-9]+\\s*(اشخاص|شخص)',
  'لثلاثه|لاربعه|لخمسه|لسته',
  /* English */
  'box',
  'platter',
  'tray',
  'family',
  'sharing',
  'party',
  'dozen',
  'bucket',
  'feast',
  'catering',
  /* "for 2" is a table; "Meal For 1" / "for 69SR" are a single plate and a price. */
  'for\\s*[2-9]([^0-9]|$)',
  'serves',
]);

/**
 * Packaged retail a food app happens to carry — supplements, powders, pills.
 * Some merchants classified as restaurants are really supplement shops, and
 * their 300-gram tubs carry big gaps that outrank every dish in the city.
 *
 * Every term here was counted against the live read layer before it was
 * accepted (2026-08-20). What that measurement rejected matters as much as
 * what it kept: `سعره [0-9]+` looked like a scraped price and matches **10,248
 * items — 18% of Riyadh** — but the English side reads "cal 250": it is a
 * calorie count, and excluding it would have thrown away an eighth of the
 * data. `بروتين` catches "وعاء أرز مع نوعين من البروتين", a rice bowl, and
 * a bare `mg` catches "MG shrimp bowl", so both are required to follow a
 * number instead. Guessing a lexicon is how a map starts lying quietly.
 */
const RETAIL_TERM_SOURCES = Object.freeze([
  'كرياتين',
  'فيتامين',
  'مكمل',
  'امينو',
  'جلوتامين',
  'كبسول',
  'اقراص',
  'بي سي ايه ايه',
  'واي بروتين',
  '[0-9]+\\s*(جرام|غرام)',
  '[0-9]+\\s*(ملجم|ملغم|mg)',
  'creatine',
  'vitamin',
  'supplement',
  'bcaa',
  'whey',
  'pre-workout',
]);

const SHARE_PATTERN = SHARE_TERM_SOURCES.join('|');
const RETAIL_PATTERN = RETAIL_TERM_SOURCES.join('|');
const SHARE_RE = new RegExp(SHARE_PATTERN, 'i');
const RETAIL_RE = new RegExp(RETAIL_PATTERN, 'i');
/** Half a kilo of dessert, or an eighth-gallon pint, is one person's order. */
const PERSONAL_SIZE_RE =
  /½\s*كيلو|نصف\s*كيلو|نص\s*كيلو|[12]\s*\/\s*[12]\s*كيلو|half\s+(a\s+)?kilo|ثمن\s*جالون/;
const PERSONAL_SIZE_SQL =
  "نصف\\s*كيلو|نص\\s*كيلو|[12]/[12]\\s*كيلو|½\\s*كيلو|half\\s+(a\\s+)?kilo|ثمن\\s*جالون";
const SHARE_PATTERN_WITHOUT_SIZE = SHARE_TERM_SOURCES.filter(
  (t) => t !== 'كيلو' && t !== 'جالون',
).join('|');
const SHARE_RE_WITHOUT_SIZE = new RegExp(SHARE_PATTERN_WITHOUT_SIZE, 'i');

/** The same patterns the SQL uses, so the server and its query cannot disagree. */
function shareItemPattern() {
  return SHARE_PATTERN;
}

function retailItemPattern() {
  return RETAIL_PATTERN;
}

/** True when the item reads as something bought for a group rather than for one person. */
function isShareItem(name) {
  const norm = normalizeArabic(name);
  if (!norm || !SHARE_RE.test(norm)) return false;
  if (PERSONAL_SIZE_RE.test(norm) && !SHARE_RE_WITHOUT_SIZE.test(norm)) return false;
  return true;
}

function shareMatchSql(nameExpr) {
  const norm = normalizedNameSql(nameExpr);
  return `(${norm} ~ '${SHARE_PATTERN}' AND (NOT (${norm} ~ '${PERSONAL_SIZE_SQL}') OR ${norm} ~ '${SHARE_PATTERN_WITHOUT_SIZE}'))`;
}

/** True when the item reads as packaged retail rather than something cooked to order. */
function isRetailItem(name) {
  const norm = normalizeArabic(name);
  return norm ? RETAIL_RE.test(norm) : false;
}

/**
 * Why an item is not the one we put in front of a person, or null when it is
 * exactly that. The reason travels with the row so the interface can say
 * "بوكس مشاركة" instead of silently ranking something down.
 */
function demoteReason(name) {
  if (isShareItem(name)) return 'share';
  if (isRetailItem(name)) return 'retail';
  return null;
}

/**
 * The scraper leaves its residue in item names: a trailing calorie count
 * ("سعره 250" / "cal 250") and catalogue SKUs ("لؤلؤ مالح 03003641"). The
 * dish is real, the noise is not part of its name — so it is trimmed for
 * display only. The source string is never modified, and if trimming would
 * leave nothing, the original is kept.
 */
function displayItemName(name) {
  const raw = String(name || '').trim();
  if (!raw) return '';
  const trimmed = raw
    .replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '')
    .replace(/\s*[-–—]?\s*(سعره|سعرة|سعرات)\s*[٠-٩0-9]+\s*/g, ' ')
    .replace(
      /\s*[\(（]?\s*(?:k\s*)?cal(?:ories)?\s*[:：]?\s*[٠-٩0-9]+\s*[\)）]?\s*/gi,
      ' ',
    )
    .replace(/_[٠-٩0-9]{5,}/g, '')
    .replace(/\s*[-–—]?\s*[٠-٩0-9]{6,}(?=$|[\s,،)）])/g, ' ')
    .replace(/([\u0600-\u06FF])[0-9]{5,}/g, '$1')
    .replace(/\s*\b0[0-9]{4,}\b\s*/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .replace(/\s*[-–—]\s*$/, '')
    .replace(/\s*[,،()（）]+\s*$/, '')
    .trim();
  return trimmed || raw;
}

/**
 * Normalise an Arabic name inside SQL the same way `normalizeArabic` does in
 * JS — hamza forms, taa marbuta, alef maqsura, diacritics, tatweel, and
 * Arabic-Indic digits. Without this, the shared term lists (written in
 * normalised form) would miss the way the source actually spells things.
 */
function normalizedNameSql(expr) {
  /* Six letters → six letters: أإآٱ→ا, ة→ه, ى→ي. A shorter dest mapped
   * ة to ي and deleted ى, so SQL missed every ة-spelling the JS caught
   * (صينية, سفرة, وليمة) and the pin stayed mint while the sheet said share. */
  return `translate(translate(lower(${expr}), 'أإآٱةىًٌٍَُِّْـ', 'ااااهي'), '٠١٢٣٤٥٦٧٨٩', '0123456789')`;
}

/**
 * `<category id>` for an item name, from the one list the copilot already
 * uses (`CATEGORY_GROUPS`) so a category means the same thing whether it was
 * typed, spoken to the copilot, or filtered on the map. First match wins, in
 * the list's own order.
 */
function categoryOfItem(name) {
  const norm = normalizeArabic(name);
  if (!norm) return null;
  for (const group of CATEGORY_GROUPS) {
    if (group.terms.some((t) => norm.includes(normalizeArabic(t)))) return group.id;
  }
  return null;
}

/** The same first-match-wins mapping as a SQL CASE, built from the same list. */
function categoryCaseSql(expr) {
  const norm = normalizedNameSql(expr);
  const branches = CATEGORY_GROUPS.map((group) => {
    const pattern = group.terms.map((t) => normalizeArabic(t)).join('|').replace(/'/g, "''");
    return `WHEN ${norm} ~ '${pattern}' THEN '${group.id}'`;
  });
  return `CASE ${branches.join(' ')} ELSE NULL END`;
}

/**
 * What the person actually pays apart, once delivery is counted.
 *
 * Returns null unless **both** sides are observed: on 2026-08-20 not one
 * Riyadh restaurant had a delivery fee recorded for both its cheapest and its
 * dearest provider (2,813 had one, 3,157 the other, 0 had both), so this
 * answers null everywhere today. It is written and tested now so that the
 * moment the crawler records both, the honest number appears by itself —
 * and so that nobody is tempted to fill the gap with an average.
 */
/**
 * Shared ranking for the one item a pin, list card, and getPlace sheet name.
 * A displayable gap (≥ 1 ر.س, the pin's own floor) beats a same-price or
 * halala-only row — share trays must not vanish behind a stew the map
 * would not number. Share/retail lose the tie among those gaps; equal
 * gaps take the cheaper dish; item id is last so 1479 cannot be fries
 * on the pin and sambosa on the sheet.
 */
const ITEM_NAME_SQL = "coalesce(ips.name_ar,'') || ' ' || coalesce(ips.name_en,'')";

function representativeSpreadOrderSql() {
  return `((ips.dearest_price - ips.cheapest_price) >= 1) DESC,
          (${shareMatchSql(ITEM_NAME_SQL)}
        OR ${normalizedNameSql(ITEM_NAME_SQL)} ~ '${retailItemPattern()}') ASC,
          (ips.dearest_price - ips.cheapest_price) DESC NULLS LAST,
          ips.cheapest_price ASC NULLS LAST,
          ips.canonical_item_id ASC`;
}

function deliveryAdjustedGap({ cheapestPrice, dearestPrice, cheapestFee, dearestFee } = {}) {
  /* An unobserved fee is missing, not zero — Number(null) is 0, which would
   * quietly turn "we don't know" into "delivery is free". */
  const observed = (v) => (v === null || v === undefined || v === '' ? NaN : Number(v));
  const cp = observed(cheapestPrice);
  const dp = observed(dearestPrice);
  const cf = observed(cheapestFee);
  const df = observed(dearestFee);
  if (![cp, dp, cf, df].every((n) => Number.isFinite(n))) return null;
  if (cf < 0 || df < 0) return null;
  const adjusted = dp + df - (cp + cf);
  return Math.round(adjusted * 100) / 100;
}

module.exports = {
  CATEGORY_GROUPS,
  RETAIL_TERM_SOURCES,
  SHARE_TERM_SOURCES,
  categoryCaseSql,
  categoryOfItem,
  deliveryAdjustedGap,
  demoteReason,
  displayItemName,
  isRetailItem,
  isShareItem,
  normalizedNameSql,
  representativeSpreadOrderSql,
  retailItemPattern,
  shareItemPattern,
  shareMatchSql,
};
