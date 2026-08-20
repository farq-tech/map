'use strict';

const CATEGORY_GROUPS = Object.freeze([
  { id: 'burgers', terms: Object.freeze(['برجر', 'برغر', 'burger', 'burgers']) },
  { id: 'pizza', terms: Object.freeze(['بيتزا', 'pizza']) },
  { id: 'coffee', terms: Object.freeze(['قهوة', 'كوفي', 'coffee']) },
  { id: 'shawarma', terms: Object.freeze(['شاورما', 'shawarma']) },
  { id: 'grocery', terms: Object.freeze(['بقالة', 'تموين', 'grocery']) },
]);

const CHEAPEST_RE = /أرخص|ارخص|أوفر|اوفر|cheapest|cheap/i;
const EVERYWHERE_RE =
  /كل\s*(?:الرياض|مكان)|بكل\s*مكان|everywhere|all\s+(?:of\s+)?riyadh/i;
const NEAR_ME_RE = /حول[يى]|قريب(?:\s*من[يى])?|near\s+me/i;
const VIEWPORT_RE =
  /هالنطاق|هذا النطاق|الظاهر|على الشاشة|on\s+screen|visible(?:\s+map)?|اللي\s+(?:أشوفه|شايفه)/i;
const PLACE_RE = /(?:في|بـ|بحي|حي|حارة|منطقة)\s+([^\s،,؟?.!]{2,40})/u;

const PLACE_STOP = new Set([
  'كل',
  'مكان',
  'الرياض',
  'riyadh',
  'النطاق',
  'الخريطة',
  'الشاشة',
]);

function isFiniteNum(n) {
  return typeof n === 'number' && Number.isFinite(n);
}

function normTerm(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function isCategoryTerm(text) {
  const n = normTerm(text);
  return CATEGORY_GROUPS.some((g) => g.terms.some((t) => normTerm(t) === n));
}

function extractQueryTerms(message) {
  const text = normTerm(message);
  const terms = [];
  const seen = new Set();
  for (const group of CATEGORY_GROUPS) {
    if (!group.terms.some((t) => text.includes(normTerm(t)))) continue;
    for (const t of group.terms) {
      const n = normTerm(t);
      if (n.length < 3 || seen.has(n)) continue;
      seen.add(n);
      terms.push(n);
    }
  }
  return terms.slice(0, 8);
}

function extractPlace(message) {
  const text = String(message || '').trim();
  if (!text || EVERYWHERE_RE.test(text)) return null;
  const m = text.match(PLACE_RE);
  if (!m) return null;
  const place = String(m[1] || '').trim();
  if (place.length < 2) return null;
  if (PLACE_STOP.has(normTerm(place))) return null;
  if (isCategoryTerm(place)) return null;
  return place;
}

/**
 * Named places / city-wide / near-me hit the Farq comparison source.
 * Viewport is only used when the user asks about what is on screen.
 */
function resolveChatSearch(message, ctx = {}) {
  const text = String(message || '').trim();
  const sort = CHEAPEST_RE.test(text) ? 'cheapest' : 'gap';
  const qTerms = extractQueryTerms(text);
  const viewportOnly = VIEWPORT_RE.test(text);
  const everywhere = EVERYWHERE_RE.test(text);
  const nearMe = NEAR_ME_RE.test(text);
  const place = extractPlace(text);
  const hasUser =
    isFiniteNum(ctx.userLat) &&
    isFiniteNum(ctx.userLng);

  if (place) {
    return {
      tool: 'search_source_opportunities',
      place,
      qTerms,
      sort,
      bboxSource: 'place',
    };
  }
  if (viewportOnly && !everywhere) {
    return {
      tool: 'get_visible_opportunities',
      place: null,
      qTerms,
      sort,
      bboxSource: 'viewport',
    };
  }
  if (nearMe && hasUser) {
    return {
      tool: 'search_source_opportunities',
      place: null,
      qTerms,
      sort,
      bboxSource: 'user',
    };
  }
  return {
    tool: 'search_source_opportunities',
    place: null,
    qTerms,
    sort,
    bboxSource: 'city',
  };
}

module.exports = {
  CATEGORY_GROUPS,
  extractPlace,
  extractQueryTerms,
  resolveChatSearch,
};
