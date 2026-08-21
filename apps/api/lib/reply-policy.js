'use strict';

const INSUFFICIENT_COMPARISON_AR =
  'ما عندنا مقارنة كافية في هذا النطاق حتى الآن.';

const PLACE_NOT_FOUND_AR = 'ما قدرت أحدد الحي من المصدر. ما بخترع موقع.';

const FORECAST_REFUSAL_AR =
  'ما أقدر أتوقع أسعار مستقبلية. أقدر أفسّر الفروقات المرصودة من مصدر المقارنة فقط.';

const FORECAST_INTENT_RE =
  /(?:توقع(?:ات)?|تنبؤ|forecast|predict(?:ion)?s?|future\s+pric|(?:سعر|السعر).{0,32}بعد\s*(?:أسبوع|شهر|سنة|يوم)|بعد\s*(?:أسبوع|شهر|سنة|يوم).{0,32}(?:سعر|السعر)|سعر\s*(?:بكرة|غداً?)|(?:will|gonna)\s+(?:be|cost|rise|drop|go)|price\s+(?:forecast|prediction|next)|بتصير|بيصير|راح\s+يصير)/i;

function classifyQuestion(text) {
  const q = String(text || '').trim();
  if (!q) return 'empty';
  if (FORECAST_INTENT_RE.test(q)) return 'forecast';
  return 'map';
}

function refuseForecast() {
  return FORECAST_REFUSAL_AR;
}

function insufficientComparison(area) {
  const name = String(area || '').trim();
  if (name) return `ما عندنا مقارنة كافية في ${name} حتى الآن.`;
  return INSUFFICIENT_COMPARISON_AR;
}

function placeNotFound(place) {
  const name = String(place || '').trim();
  if (name) return `ما قدرت أحدد «${name}» من المصدر. ما بخترع موقع.`;
  return PLACE_NOT_FOUND_AR;
}

function easternToWesternDigits(s) {
  return String(s || '').replace(/[٠-٩]/g, (ch) =>
    String('٠١٢٣٤٥٦٧٨٩'.indexOf(ch)),
  );
}

function normalizeNumber(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return null;
  return String(Number(v.toFixed(4)));
}

function numbersFromOpportunities(opportunities) {
  const allowed = new Set();
  for (const row of opportunities || []) {
    for (const key of [
      'cheapest_price',
      'highest_price',
      'difference_amount',
      /* The percentage and the app count are observed values on the same row and
       * the templates already print them — leaving them out made the copilot
       * refuse its own draft, so a model reply could never pass and the phrasing
       * step spent a call on every answer only to discard the result. */
      'pct',
      'provider_count',
      'lat',
      'lng',
    ]) {
      const norm = normalizeNumber(row[key]);
      if (norm != null) allowed.add(norm);
    }
  }
  return allowed;
}

/**
 * Price-like or coordinate-like numbers in the reply must appear in tool JSON.
 * Small integers 1–12 are allowed as counts of the capped list.
 */
function replyUsesOnlyToolNumbers(reply, opportunities) {
  const allowed = numbersFromOpportunities(opportunities);
  const text = easternToWesternDigits(reply || '');
  const matches = text.match(/\d+(?:\.\d+)?/g) || [];
  for (const raw of matches) {
    const n = Number(raw);
    if (!Number.isFinite(n)) continue;
    if (Number.isInteger(n) && n >= 0 && n <= 12) continue;
    const norm = normalizeNumber(n);
    const loose = normalizeNumber(Number(n.toFixed(2)));
    if (allowed.has(norm) || allowed.has(loose)) continue;
    /* Prices are printed to one decimal (109.95 → "110.0"), so a reply that
     * shows an observed number the way the product shows it must pass. The
     * window is half of that last displayed decimal — wide enough for the
     * rounding we do ourselves, far too narrow to admit a made-up figure. */
    const rounded = [...allowed].some((a) => {
      const av = Number(a);
      return Number.isFinite(av) && Math.abs(av - n) <= 0.05;
    });
    if (!rounded) return false;
  }
  return true;
}

function formatObservedReply(opportunities) {
  const rows = Array.isArray(opportunities) ? opportunities : [];
  if (!rows.length) return INSUFFICIENT_COMPARISON_AR;
  const top = rows[0];
  const place = String(top.place || '').trim();
  const item = String(top.item || '').trim();
  const cheap = top.cheapest_provider ? String(top.cheapest_provider) : '';
  const pricey = top.expensive_provider ? String(top.expensive_provider) : '';
  const parts = [];
  if (place) parts.push(place);
  if (item) parts.push(`صنف ${item}`);
  if (top.cheapest_price != null && cheap) {
    parts.push(`أرخص مرصود ${cheap} بـ ${top.cheapest_price}`);
  }
  if (top.highest_price != null && pricey) {
    parts.push(`أعلى ${pricey} بـ ${top.highest_price}`);
  }
  if (top.difference_amount != null) {
    parts.push(`فرق ${top.difference_amount} ر.س`);
  }
  if (parts.length < 2) return INSUFFICIENT_COMPARISON_AR;
  return `${parts.join(' — ')}.`;
}

function applyReplyPolicy(reply, opportunities) {
  const text = String(reply || '').trim();
  if (!text) return INSUFFICIENT_COMPARISON_AR;
  if (!Array.isArray(opportunities) || opportunities.length === 0) {
    return INSUFFICIENT_COMPARISON_AR;
  }
  if (!replyUsesOnlyToolNumbers(text, opportunities)) {
    return INSUFFICIENT_COMPARISON_AR;
  }
  return text;
}

module.exports = {
  INSUFFICIENT_COMPARISON_AR,
  PLACE_NOT_FOUND_AR,
  FORECAST_REFUSAL_AR,
  classifyQuestion,
  refuseForecast,
  insufficientComparison,
  placeNotFound,
  replyUsesOnlyToolNumbers,
  applyReplyPolicy,
  formatObservedReply,
  numbersFromOpportunities,
};
