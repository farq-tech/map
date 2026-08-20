'use strict';

/**
 * Copilot intent — what the person asked, decided in code before any model.
 *
 * Arabic is normalised first (Arabic-Indic digits, hamza forms, taa marbuta,
 * alef maqsura, tatweel, diacritics), then a small set of readable rules
 * picks an intent, a scope and the slots the tools need. Follow-ups such as
 * "الأرخص؟", "ليش؟" and "خذني له" resolve against the session, never against
 * the model's imagination. Anything the rules cannot place becomes SEARCH.
 */

const { classifyQuestion } = require('./chat-policy');

const ARABIC_INDIC = '٠١٢٣٤٥٦٧٨٩';
const EXTENDED_INDIC = '۰۱۲۳۴۵۶۷۸۹';

/* نسخة الويب: normalizeSearchText في apps/web/src/lib/farqTextSearch.ts — عدّل الاثنين معاً. */
function normalizeArabic(raw) {
  let s = String(raw || '');
  s = s.replace(/[٠-٩]/g, (ch) => String(ARABIC_INDIC.indexOf(ch)));
  s = s.replace(/[۰-۹]/g, (ch) => String(EXTENDED_INDIC.indexOf(ch)));
  s = s.replace(/[ً-ْٰـ]/g, '');
  s = s.replace(/[أإآٱ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي');
  s = s.replace(/[؟?!.,،;:"'()\[\]{}«»]/g, ' ');
  s = s.toLowerCase().replace(/\s+/g, ' ').trim();
  return s;
}

/** Provider names as people type them → canonical provider keys. */
const PROVIDER_ALIASES = Object.freeze([
  ['hungerstation', /هنقرستيشن|هنجرستيشن|هنقر ستيشن|هنقر|hunger\s*station|\bhs\b/],
  ['jahez', /جاهز|jahez/],
  ['mrsool', /مرسول|mrsool/],
  ['toyou', /تويو|تو يو|to\s*you/],
  ['thechefz', /ذا شفز|الشفز|شفز|chefz/],
  ['ninja', /نينجا|ninja/],
  ['keeta', /كيتا|keeta/],
  ['mrmandoob', /مرمندوب|مر مندوب|مندوب|mandoob/],
  ['brand_app', /تطبيق المطعم|تطبيق المحل|brand app|restaurant app/],
]);

const PROVIDER_LABELS_AR = Object.freeze({
  hungerstation: 'هنقرستيشن',
  jahez: 'جاهز',
  mrsool: 'مرسول',
  toyou: 'تويو',
  thechefz: 'ذا شفز',
  ninja: 'نينجا',
  keeta: 'كيتا',
  mrmandoob: 'مرمندوب',
  brand_app: 'تطبيق المطعم',
});

const PROVIDER_LABELS_EN = Object.freeze({
  hungerstation: 'HungerStation',
  jahez: 'Jahez',
  mrsool: 'Mrsool',
  toyou: 'ToYou',
  thechefz: 'The Chefz',
  ninja: 'Ninja',
  keeta: 'Keeta',
  mrmandoob: 'Mr. Mandoob',
  brand_app: 'the restaurant app',
});

function providerLabel(key, language = 'ar') {
  const table = language === 'en' ? PROVIDER_LABELS_EN : PROVIDER_LABELS_AR;
  return table[key] || key;
}

function providersIn(text) {
  const found = [];
  for (const [key, re] of PROVIDER_ALIASES) {
    if (re.test(text)) found.push(key);
  }
  return found;
}

/** Category vocabulary — the words people use, mapped to search terms over item/restaurant names. */
const CATEGORY_GROUPS = Object.freeze([
  { id: 'burgers', terms: ['برجر', 'برغر', 'برقر', 'همبرجر', 'burger'] },
  { id: 'pizza', terms: ['بيتزا', 'pizza'] },
  { id: 'coffee', terms: ['قهوه', 'كوفي', 'كافيه', 'لاتيه', 'اسبريسو', 'coffee', 'latte'] },
  { id: 'shawarma', terms: ['شاورما', 'shawarma'] },
  { id: 'chicken', terms: ['بروستد', 'دجاج', 'فرايد تشكن', 'تشكن', 'chicken'] },
  { id: 'sushi', terms: ['سوشي', 'sushi'] },
  { id: 'desserts', terms: ['حلا', 'حلى', 'كيك', 'كيكه', 'دونات', 'ايس كريم', 'dessert', 'cake'] },
  { id: 'sandwiches', terms: ['ساندويتش', 'ساندوتش', 'سندويش', 'sandwich'] },
  { id: 'breakfast', terms: ['فطور', 'فول', 'breakfast'] },
  { id: 'juice', terms: ['عصير', 'juice', 'smoothie'] },
  { id: 'pasta', terms: ['باستا', 'معكرونه', 'pasta'] },
  { id: 'seafood', terms: ['سمك', 'روبيان', 'جمبري', 'seafood', 'fish'] },
  { id: 'grill', terms: ['مشاوي', 'مشويات', 'كباب', 'grill', 'kebab'] },
  { id: 'grocery', terms: ['بقاله', 'تموين', 'سوبرماركت', 'grocery'] },
]);

function categoryIn(text) {
  for (const group of CATEGORY_GROUPS) {
    const hit = group.terms.find((t) => text.includes(normalizeArabic(t)));
    if (hit) return { id: group.id, terms: group.terms.map((t) => normalizeArabic(t)) };
  }
  return null;
}

/* JS \b is ASCII-only, so Arabic filler is removed token by token. */
const FILLER = new Set(
  'وين فين وش ايش ايه كم ابي ابغي ابغى ودي اريد اعطني عطني ورني وريني شوف لي لنا يا فرق من في على هو هي اللي الي ال حولي جنبي قريب مني هنا هالنطاق النطاق الشاشه الظاهر الان الليله اليوم الحين ارخص الارخص اغلى الاغلى اكبر افضل احسن اعلى اقل مطعم مطاعم محل فرصه فرص توفير اوفر وفر شي شيء يستاهل يسوى please show me the a an what where is are i want find near cheapest biggest gap best'.split(' '),
);
function stripFiller(norm) {
  return norm
    .split(' ')
    .filter((w) => w && !FILLER.has(w))
    .join(' ')
    .trim();
}
const FORECAST_RE =
  /بكره|غدا|باكر|بعد اسبوع|الاسبوع الجاي|الشهر الجاي|المستقبل|بيرخص|بيغلى|بيزيد|بينزل|راح يرخص|راح يغلى|راح يزيد|توقع|تنبؤ|forecast|predict|tomorrow|next week|next month|will (it|the price|prices)/;

const PLACE_RE = /(?:في|ب|بحي|حي|حاره|منطقه|بمنطقه|عند)\s+([^\s]{2,40}(?:\s+[^\s]{2,40})?)/u;
const PLACE_STOP = new Set([
  'كل', 'مكان', 'الرياض', 'riyadh', 'النطاق', 'الخريطه', 'الشاشه', 'هذا', 'هذي', 'هنا', 'المطعم', 'المكان',
  'جاهز', 'مرسول', 'هنقرستيشن', 'تويو', 'كيتا', 'نينجا',
]);

function extractPlaceText(norm, raw = '') {
  const m = norm.match(PLACE_RE);
  if (!m) return null;
  let place = String(m[1] || '').trim();
  /* "في حي النرجس" → "النرجس"; drop a trailing filler the regex swallowed */
  place = place.replace(/^حي\s+/, '');
  place = place.replace(/\s+(الان|الليله|اليوم|حولي|وش|فرق).*$/, '').trim();
  if (place.length < 2) return null;
  if (PLACE_STOP.has(place)) return null;
  if (categoryIn(place)) return null;
  return originalSpan(raw, place) || place;
}

/** Give the place back in the person's own spelling (hamza, taa marbuta) for the reply. */
function originalSpan(raw, placeNorm) {
  const words = String(raw || '').replace(/[؟?!.,،;:"'()\[\]{}«»]/g, ' ').split(/\s+/).filter(Boolean);
  const target = placeNorm.split(' ');
  for (let i = 0; i + target.length <= words.length; i += 1) {
    const slice = words.slice(i, i + target.length);
    if (slice.map((w) => normalizeArabic(w)).join(' ') === placeNorm) return slice.join(' ');
  }
  return null;
}

const RE = Object.freeze({
  returnToUser: /(رجعني|رجع|ارجع|وديني|خذني|روح|وصلني)\s*(ل|الى|ال)?\s*(موقعي|مكاني)|وين انا|my location|where am i|back to me/,
  gotoReferent: /^(خذني|وديني|روح|وصلني|اذهب|take me)(\s+(له|لها|هناك|عنده|عندها|لهذا|there|to it))?$|(خذني|وديني|وصلني)\s+(له|لها|هناك|عنده)/,
  explain: /^(ليش|ليه|لماذا|وش السبب|why)(\s|$)/,
  topN: /(افضل|اكبر|اعلى|اعطني|عطني|ورني|وريني|اهم)\s*(\d{1,2})\b|\b(\d{1,2})\s*(فرص|مطاعم|خيارات|اماكن)|top\s*(\d{1,2})|best\s*(\d{1,2})/,
  minGap: /(فوق|اكثر من|اكبر من|اعلى من|فوق ال|above|over|more than)\s*(\d{1,4})/,
  appChoice: /(اي|ايش|وش|which|what)\s*(تطبيق|app)|(ارخص|افضل|احسن)\s*تطبيق|cheapest app|which app/,
  pair: /(فرق|الفرق|بين|قارن|مقارنه|compare|vs|versus|difference)/,
  aroundPoint: /(حول|حوالين|جنب|قريب من|عند)\s*(هذا|هذي|هالمكان|المكان|المطعم|ها)(\s|$)|around (this|here|it)/,
  compareNearest: /قارن.*(جنب|قريب|المجاور)|compare.*(next|nearby|neighbou?r)/,
  biggestGap: /(اكبر|اعلى|اضخم)\s*(فرق|فروق|فارق)|biggest gap|largest gap/,
  cheapest: /(^|\s)(ال)?ارخص(\s|$)|cheapest|cheaper/,
  save: /اوفر|وفر|توفير|اقدر اوفر|save money|save/,
  nearMe: /حولي|حواليني|جنبي|قريب مني|قريبه مني|near me|around me|nearby/,
  viewport: /هالنطاق|هذا النطاق|الظاهر|على الشاشه|في الشاشه|on screen|visible|in view/,
  everywhere: /كل الرياض|بكل الرياض|كل مكان|بكل مكان|everywhere|all riyadh/,
  price: /بكم|كم سعر|سعر|price|how much/,
});

function topNFrom(norm) {
  const m = norm.match(RE.topN);
  if (!m) return null;
  const n = Number(m[2] || m[3] || m[5] || m[6]);
  if (!Number.isFinite(n) || n < 1) return null;
  return Math.min(10, n);
}

function minGapFrom(norm) {
  const m = norm.match(RE.minGap);
  if (!m) return null;
  const n = Number(m[2]);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function wordCount(norm) {
  return norm ? norm.split(' ').filter(Boolean).length : 0;
}

/**
 * @param {string} message
 * @param {{ hasSession?: boolean, hasSelected?: boolean, hasUser?: boolean, hasViewport?: boolean }} ctx
 */
function classifyIntent(message, ctx = {}) {
  const raw = String(message || '').trim();
  const norm = normalizeArabic(raw);
  if (!norm) return { intent: 'EMPTY', norm, slots: {} };
  if (classifyQuestion(raw) === 'forecast' || FORECAST_RE.test(norm)) return { intent: 'FORECAST', norm, slots: {} };

  const providers = providersIn(norm);
  const category = categoryIn(norm);
  const placeText = extractPlaceText(norm, raw);
  const words = wordCount(norm);
  const scope = RE.everywhere.test(norm)
    ? 'city'
    : placeText
      ? 'place'
      : RE.viewport.test(norm)
        ? 'viewport'
        : RE.nearMe.test(norm)
          ? 'near'
          : null;
  const slots = { providers, category: category ? category.id : null, terms: category ? category.terms : [], placeText, scope, topN: topNFrom(norm), minGap: minGapFrom(norm) };

  if (RE.returnToUser.test(norm)) return { intent: 'RETURN_TO_USER', norm, slots };
  if (RE.gotoReferent.test(norm) && !placeText) return { intent: 'GOTO_REFERENT', norm, slots };
  if (RE.explain.test(norm)) return { intent: 'EXPLAIN_SELECTED', norm, slots };
  if (RE.compareNearest.test(norm) && ctx.hasSelected) return { intent: 'COMPARE_NEAREST', norm, slots };
  if (RE.aroundPoint.test(norm) && ctx.hasSelected) return { intent: 'AROUND_POINT', norm, slots };
  if (providers.length >= 2 && RE.pair.test(norm)) return { intent: 'APP_PAIR', norm, slots };
  if (RE.appChoice.test(norm) || (providers.length === 1 && RE.cheapest.test(norm) && !category)) {
    return { intent: 'APP_CHOICE', norm, slots };
  }
  if (slots.minGap != null) return { intent: 'SET_MIN_GAP', norm, slots };
  if (slots.topN != null) return { intent: 'TOP_N', norm, slots };
  if (RE.cheapest.test(norm) && words <= 3 && !category && !placeText && ctx.hasSession && !RE.biggestGap.test(norm)) {
    return { intent: 'FOLLOWUP_CHEAPEST', norm, slots };
  }
  if (RE.biggestGap.test(norm)) return { intent: 'BIGGEST_GAP', norm, slots };
  if (category && RE.cheapest.test(norm)) return { intent: 'CHEAPEST_IN_CATEGORY', norm, slots };
  if (category && placeText) return { intent: 'SEARCH', norm, slots: { ...slots, q: category.terms[0] } };
  if (category) {
    const leftover = stripFiller(norm);
    const onlyCategory = category.terms.some((t) => leftover === t || leftover === `ال${t}`) || leftover.length <= 3;
    return { intent: onlyCategory ? 'SET_CATEGORY' : 'SEARCH', norm, slots: { ...slots, q: onlyCategory ? category.terms[0] : leftover } };
  }
  if (placeText && !RE.price.test(norm)) return { intent: 'PLACE_SCOPE', norm, slots };
  if (RE.save.test(norm)) return { intent: 'VAGUE_SAVE', norm, slots };
  const leftover = stripFiller(norm);
  if (!leftover || leftover.length < 2) return { intent: 'BIGGEST_GAP', norm, slots };
  return { intent: 'SEARCH', norm, slots: { ...slots, q: leftover } };
}

module.exports = {
  CATEGORY_GROUPS,
  PROVIDER_ALIASES,
  categoryIn,
  classifyIntent,
  extractPlaceText,
  normalizeArabic,
  providerLabel,
  providersIn,
};
