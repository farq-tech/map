'use strict';

/**
 * Farq Copilot — a map you can talk to.
 *
 *   message → normalise → intent (code) → tools over the city read model
 *           → rows with ids → answer (template, or Gemini phrasing that may
 *             only use those rows) → ONE validated map action → response
 *
 * The map never depends on the model: every intent has a deterministic
 * Arabic/English answer built from the rows, and the action is built in code
 * from row ids. When a Gemini key is present the model may rephrase the
 * answer; its text is accepted only if every number in it exists in the rows.
 * Short follow-ups ("الأرخص؟", "ليش؟", "خذني له") resolve against the session.
 */

const crypto = require('crypto');
const { classifyIntent, providerLabel } = require('./copilot-intent');
const tools = require('./copilot-tools');
const { replyUsesOnlyToolNumbers } = require('./chat-policy');

const SESSION_TTL_MS = 30 * 60 * 1000;
const sessions = new Map();

const ACTION_TYPES = Object.freeze([
  'NOOP',
  'FOCUS_PLACE',
  'SHOW_RESULTS',
  'FIT_BOUNDS',
  'SET_FILTER',
  'SET_CATEGORY',
  'SET_SEARCH',
  'RETURN_TO_USER',
]);

function now() {
  return Date.now();
}

function getSession(id) {
  const key = String(id || '').trim();
  if (key && sessions.has(key)) {
    const s = sessions.get(key);
    if (now() - s.updatedAt < SESSION_TTL_MS) return s;
    sessions.delete(key);
  }
  const fresh = { id: key || crypto.randomUUID(), rows: [], selectedPlaceId: null, intent: null, scope: null, updatedAt: now() };
  sessions.set(fresh.id, fresh);
  return fresh;
}

function sweepSessions() {
  const t = now();
  for (const [id, s] of sessions) if (t - s.updatedAt > SESSION_TTL_MS) sessions.delete(id);
}

/* ---------- copy ---------- */

function n(v) {
  return String(Math.round(Number(v)));
}

function price(v) {
  const x = Number(v);
  return Number.isInteger(x) ? String(x) : x.toFixed(1);
}

function rowLine(r, lang) {
  const cheap = providerLabel(r.cheapest_provider_id, lang);
  const dear = r.expensive_provider_id ? providerLabel(r.expensive_provider_id, lang) : null;
  const item = r.product_name || (lang === 'en' ? 'an item' : 'صنف');
  if (lang === 'en') {
    const tail = dear && r.expensive_price != null ? ` vs ${price(r.expensive_price)} on ${dear}` : '';
    return `${item} at ${r.name}: ${price(r.cheapest_price)} SAR on ${cheap}${tail} — gap ${n(r.gap)} SAR${r.pct != null ? ` (${n(r.pct)}%)` : ''}`;
  }
  const tail = dear && r.expensive_price != null ? ` مقابل ${price(r.expensive_price)} في ${dear}` : '';
  return `${item} في ${r.name}: ${price(r.cheapest_price)} ر.س في ${cheap}${tail} — فرق ${n(r.gap)} ر.س${r.pct != null ? ` (${n(r.pct)}%)` : ''}`;
}

function scopeLabel(scope, lang) {
  if (!scope) return '';
  if (scope.kind === 'near') return lang === 'en' ? 'around you' : 'حولك';
  if (scope.kind === 'viewport') return lang === 'en' ? 'in this area' : 'في هذا النطاق';
  if (scope.kind === 'place') return lang === 'en' ? `in ${scope.label}` : `في ${scope.label}`;
  return lang === 'en' ? 'in Riyadh' : 'في الرياض';
}

function noneFound(scope, lang) {
  const where = scopeLabel(scope, lang);
  return lang === 'en'
    ? `No observed comparison ${where} yet. Move the map or widen the area.`
    : `ما عندنا مقارنة مرصودة ${where} حتى الآن. حرّك الخريطة أو وسّع النطاق.`;
}

function listAnswer(rows, scope, lang, intro) {
  const lines = rows.map((r, i) => `${i + 1}. ${rowLine(r, lang)}`);
  return `${intro}\n${lines.join('\n')}`;
}

/* ---------- actions ---------- */

function validateAction(action, rows) {
  if (!action || !ACTION_TYPES.includes(action.type)) return { type: 'NOOP' };
  const ids = new Set(rows.map((r) => r.place_id));
  if (action.type === 'FOCUS_PLACE') {
    return ids.has(String(action.place_id)) ? { type: 'FOCUS_PLACE', place_id: String(action.place_id) } : { type: 'NOOP' };
  }
  if (action.type === 'SHOW_RESULTS') {
    const keep = (action.place_ids || []).map(String).filter((id) => ids.has(id));
    if (!keep.length) return { type: 'NOOP' };
    const bbox = tools.bboxOf(rows.filter((r) => keep.includes(r.place_id)));
    return { type: 'SHOW_RESULTS', place_ids: keep, bbox };
  }
  if (action.type === 'FIT_BOUNDS') {
    const b = tools.parseBboxCsv(action.bbox);
    return b ? { type: 'FIT_BOUNDS', bbox: b } : { type: 'NOOP' };
  }
  if (action.type === 'SET_FILTER') {
    const minGap = Number(action.min_gap);
    return Number.isFinite(minGap) && minGap > 0 ? { type: 'SET_FILTER', min_gap: minGap, bbox: tools.bboxOf(rows) } : { type: 'NOOP' };
  }
  if (action.type === 'SET_CATEGORY') {
    return action.category
      ? { type: 'SET_CATEGORY', category: String(action.category), q: action.q ? String(action.q).slice(0, 80) : undefined, bbox: tools.bboxOf(rows) }
      : { type: 'NOOP' };
  }
  if (action.type === 'SET_SEARCH') {
    return action.q ? { type: 'SET_SEARCH', q: String(action.q).slice(0, 80), bbox: tools.bboxOf(rows) } : { type: 'NOOP' };
  }
  if (action.type === 'RETURN_TO_USER') return { type: 'RETURN_TO_USER' };
  return { type: 'NOOP' };
}

/* ---------- optional Gemini phrasing ---------- */

function geminiKey() {
  return String(process.env.GEMINI_API_KEY || process.env.GOOGLE_GENAI_API_KEY || process.env.GOOGLE_GENERATIVE_AI_API_KEY || '').trim();
}

const GEMINI_MODELS = Object.freeze(
  String(process.env.GEMINI_MODEL || 'gemini-3.7-flash,gemini-3.5-flash-lite,gemini-2.5-flash')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
);

const SYSTEM_PROMPT = [
  'أنت "فرق"، مساعد خريطة يفسّر فروقات الأسعار المرصودة بين تطبيقات التوصيل في السعودية.',
  'المصدر الوحيد للحقائق هو الصفوف المرفقة. لا تذكر أي سعر أو فرق أو مطعم أو صنف أو تطبيق غير موجود فيها.',
  'كل رقم تذكره يجب أن يظهر حرفياً في الصفوف. لا تتوقع أسعاراً مستقبلية ولا تحكم على الجودة.',
  'أجب بعربية بسيطة وواضحة (أو بالإنجليزية إذا كان السؤال إنجليزياً)، جملة أو جملتان، بلا مقدمات.',
  'أعد JSON فقط بالشكل {"answer": "..."}.',
].join('\n');

async function phraseWithGemini({ question, rows, intent, lang, draft }, deps = {}) {
  const key = geminiKey();
  if (!key || deps.disableModel) return null;
  const fetchFn = deps.fetch || fetch;
  const slim = rows.map((r) => ({
    id: r.id,
    place: r.name,
    item: r.product_name,
    cheapest_provider: r.cheapest_provider_id,
    cheapest_price: r.cheapest_price,
    highest_provider: r.expensive_provider_id,
    highest_price: r.expensive_price,
    difference_amount: r.gap,
    pct: r.pct,
  }));
  const userText = `السؤال: ${question}\nالنية: ${intent}\nاللغة: ${lang}\nصياغة أولية صحيحة يمكنك تحسينها دون تغيير أي رقم: ${draft}\nالصفوف:\n${JSON.stringify(slim)}`;
  for (const model of GEMINI_MODELS) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
    const body = {
      system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
      contents: [{ role: 'user', parts: [{ text: userText }] }],
      generationConfig: {
        responseMimeType: 'application/json',
        responseSchema: { type: 'OBJECT', properties: { answer: { type: 'STRING' } }, required: ['answer'] },
        maxOutputTokens: 300,
      },
    };
    try {
      const res = await fetchFn(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(6000) });
      if (res.status === 404) continue; // model retired — try the next one
      if (!res.ok) return null;
      const payload = await res.json().catch(() => null);
      const text = payload?.candidates?.[0]?.content?.parts?.map((p) => p.text || '').join('') || '';
      const parsed = JSON.parse(text);
      const answer = String(parsed?.answer || '').trim();
      if (!answer) return null;
      const policyRows = slim.map((r) => ({ cheapest_price: r.cheapest_price, highest_price: r.highest_price, difference_amount: r.difference_amount, lat: null, lng: null }));
      if (!replyUsesOnlyToolNumbers(answer, policyRows)) return null;
      return { answer, model };
    } catch {
      return null;
    }
  }
  return null;
}

/* ---------- orchestration ---------- */

async function handleCopilot(input, deps = {}) {
  sweepSessions();
  const message = String(input?.message || '').trim();
  const ctx = input?.context || {};
  const lang = String(input?.language || 'ar') === 'en' ? 'en' : 'ar';
  const session = getSession(input?.sessionId);
  const selectedPlaceId = String(ctx.selectedPlaceId || session.selectedPlaceId || '').trim() || null;
  const city = 'riyadh';

  const plan = classifyIntent(message, {
    hasSession: session.rows.length > 0,
    hasSelected: Boolean(selectedPlaceId),
    hasUser: Number.isFinite(Number(ctx.userLat)) && Number.isFinite(Number(ctx.userLng)),
    hasViewport: Boolean(ctx.bbox),
  });

  const base = { ok: true, session_id: session.id, intent: plan.intent, source: 'city_read_model', model: 'template' };
  const finish = async (answer, rows, action, extra = {}) => {
    const validated = validateAction(action, rows);
    let model = 'template';
    let text = answer;
    if (rows.length && !extra.skipModel) {
      const phrased = await phraseWithGemini({ question: message, rows, intent: plan.intent, lang, draft: answer }, deps);
      if (phrased) {
        text = phrased.answer;
        model = phrased.model;
      }
    }
    session.rows = rows;
    session.intent = plan.intent;
    session.updatedAt = now();
    if (validated.type === 'FOCUS_PLACE') session.selectedPlaceId = validated.place_id;
    return { ...base, answer: text, action: validated, results: rows, model, ...extra };
  };

  if (plan.intent === 'EMPTY') {
    return finish(lang === 'en' ? 'Ask about a dish, an area, or an app — I answer from observed comparisons only.' : 'اسأل عن طبق أو حي أو تطبيق — أجيب من المقارنات المرصودة فقط.', [], { type: 'NOOP' }, { skipModel: true });
  }
  if (plan.intent === 'FORECAST') {
    return finish(lang === 'en' ? 'I cannot predict prices. I can only explain observed gaps.' : 'ما أقدر أتوقع أسعار مستقبلية. أقدر أفسّر الفروقات المرصودة فقط.', [], { type: 'NOOP' }, { refused: 'forecast', skipModel: true });
  }
  if (plan.intent === 'RETURN_TO_USER') {
    return finish(lang === 'en' ? 'Back to you.' : 'رجّعتك لموقعك.', [], { type: 'RETURN_TO_USER' }, { skipModel: true });
  }

  /* Follow-ups that need a referent */
  if (plan.intent === 'GOTO_REFERENT') {
    const target = selectedPlaceId || session.rows[0]?.place_id || null;
    const row = target ? await tools.getPlaceRow(target, deps, city) : null;
    if (!row) return finish(lang === 'en' ? 'Pick a place first, or ask about an area.' : 'اختر مكاناً أولاً أو اسأل عن منطقة.', [], { type: 'NOOP' }, { clarification: 'no_referent', skipModel: true });
    return finish(lang === 'en' ? `Here it is: ${row.name}.` : `هذا هو: ${row.name}.`, [row], { type: 'FOCUS_PLACE', place_id: row.place_id }, { skipModel: true });
  }
  if (plan.intent === 'EXPLAIN_SELECTED') {
    const target = selectedPlaceId || session.rows[0]?.place_id || null;
    const row = target ? await tools.getPlaceRow(target, deps, city) : null;
    if (!row) return finish(lang === 'en' ? 'Pick a place and ask again — I explain one observed gap at a time.' : 'اختر مكاناً ثم اسأل — أفسّر فرقاً مرصوداً واحداً في كل مرة.', [], { type: 'NOOP' }, { clarification: 'no_referent', skipModel: true });
    if (!row.gap) return finish(lang === 'en' ? `No observed gap at ${row.name} yet.` : `ما رصدنا فرقاً في ${row.name} بعد.`, [row], { type: 'NOOP' }, { skipModel: true });
    const cheap = providerLabel(row.cheapest_provider_id, lang);
    const dear = row.expensive_provider_id ? providerLabel(row.expensive_provider_id, lang) : null;
    const apps = row.provider_count ? (lang === 'en' ? ` across ${row.provider_count} apps` : ` على ${row.provider_count} تطبيقات`) : '';
    const answer =
      lang === 'en'
        ? `Because ${row.product_name || 'the same item'} is ${price(row.cheapest_price)} SAR on ${cheap}${dear ? ` and ${price(row.expensive_price)} on ${dear}` : ` and ${price(row.expensive_price)} at the highest observed price`} — an observed gap of ${n(row.gap)} SAR${row.pct != null ? ` (${n(row.pct)}%)` : ''}${apps}.`
        : `لأن ${row.product_name || 'نفس الصنف'} بـ ${price(row.cheapest_price)} ر.س في ${cheap}${dear ? ` و${price(row.expensive_price)} في ${dear}` : ` و${price(row.expensive_price)} كأعلى سعر مرصود`} — فرق مرصود ${n(row.gap)} ر.س${row.pct != null ? ` (${n(row.pct)}%)` : ''}${apps}.`;
    return finish(answer, [row], { type: 'NOOP' });
  }
  if (plan.intent === 'FOLLOWUP_CHEAPEST') {
    const rows = [...session.rows].sort((a, b) => (a.cheapest_price ?? Infinity) - (b.cheapest_price ?? Infinity));
    const top = rows[0];
    if (!top) return finish(noneFound(session.scope, lang), [], { type: 'NOOP' }, { skipModel: true });
    const re = rows.map((r, i) => ({ ...r, id: `r${i + 1}` }));
    const answer = lang === 'en' ? `Cheapest among the same results: ${rowLine(top, lang)}` : `أرخص خيار ضمن نفس النتائج: ${rowLine(top, lang)}`;
    return finish(answer, re, { type: 'FOCUS_PLACE', place_id: top.place_id });
  }
  if (plan.intent === 'COMPARE_NEAREST') {
    const pair = await tools.nearestComparable(selectedPlaceId, deps, city);
    if (!pair.me || !pair.other) return finish(noneFound(null, lang), pair.me ? [pair.me] : [], { type: 'NOOP' }, { skipModel: true });
    const rows = [pair.me, pair.other];
    const answer = lang === 'en'
      ? `${rowLine(pair.me, lang)}\nNext door (${pair.other.distance_m} m): ${rowLine(pair.other, lang)}`
      : `${rowLine(pair.me, lang)}\nاللي جنبه (${pair.other.distance_m} م): ${rowLine(pair.other, lang)}`;
    return finish(answer, rows, { type: 'SHOW_RESULTS', place_ids: rows.map((r) => r.place_id) });
  }

  /* Everything else resolves a scope first */
  let scope;
  if (plan.intent === 'AROUND_POINT') {
    const me = await tools.getPlaceRow(selectedPlaceId, deps, city);
    scope = me
      ? { kind: 'near', bbox: tools.bboxAround(me.lat, me.lng, 1), center: { lat: me.lat, lng: me.lng }, radiusKm: 1, label: me.name }
      : await tools.resolveScope(plan, ctx, deps);
  } else {
    scope = await tools.resolveScope(plan, ctx, deps);
  }
  session.scope = scope;
  if (scope.kind === 'place_not_found') {
    return finish(
      lang === 'en' ? `I could not place "${scope.placeText}" from the source. I will not guess a location.` : `ما قدرت أحدد «${scope.placeText}» من المصدر. ما بخترع موقع.`,
      [],
      { type: 'NOOP' },
      { refused: 'place_not_found', skipModel: true },
    );
  }

  if (plan.intent === 'APP_CHOICE' || plan.intent === 'APP_PAIR') {
    const stats = await tools.compareApps({ city, scope }, deps);
    const where = scopeLabel(scope, lang);
    if (!stats.verdict) {
      return finish(
        lang === 'en'
          ? `Not enough comparisons ${where} to name a cheapest app (${stats.comparisons} of ${stats.min_comparisons} needed).`
          : `المقارنات ${where} غير كافية لتسمية تطبيق أرخص (${stats.comparisons} من ${stats.min_comparisons} مطلوبة).`,
        [],
        { type: 'NOOP' },
        { stats, skipModel: true },
      );
    }
    if (plan.intent === 'APP_PAIR' && plan.slots.providers.length >= 2) {
      const [a, b] = plan.slots.providers;
      const wa = stats.ranked.find((r) => r.provider === a)?.wins || 0;
      const wb = stats.ranked.find((r) => r.provider === b)?.wins || 0;
      const answer = lang === 'en'
        ? `${where}: ${providerLabel(a, lang)} was cheapest ${wa} times and ${providerLabel(b, lang)} ${wb} times, out of ${stats.comparisons} compared items.`
        : `${where}: ${providerLabel(a, lang)} كان الأرخص ${wa} مرة و${providerLabel(b, lang)} ${wb} مرة، من ${stats.comparisons} صنفاً مقارَناً.`;
      return finish(answer, [], { type: 'NOOP' }, { stats, skipModel: true });
    }
    const v = stats.verdict;
    const second = stats.ranked[1];
    const answer = lang === 'en'
      ? `${where}, ${providerLabel(v.provider, lang)} was cheapest in ${v.wins} of ${stats.comparisons} comparisons${second ? ` (${providerLabel(second.provider, lang)}: ${second.wins})` : ''}.`
      : `${where} ${providerLabel(v.provider, lang)} أرخص في ${v.wins} من ${stats.comparisons} مقارنة${second ? ` (${providerLabel(second.provider, lang)}: ${second.wins})` : ''}.`;
    return finish(answer, [], { type: 'NOOP' }, { stats, skipModel: true });
  }

  /* Row-producing intents */
  const sort = plan.intent === 'CHEAPEST_IN_CATEGORY' || plan.intent === 'FOLLOWUP_CHEAPEST' ? 'cheap' : 'gap';
  const limit = plan.intent === 'TOP_N' ? plan.slots.topN : plan.intent === 'BIGGEST_GAP' ? 3 : 5;
  const found = await tools.findOpportunities(
    { city, scope, terms: plan.slots.terms, q: plan.slots.q, minGap: plan.slots.minGap, sort, limit, excludePlaceId: plan.intent === 'AROUND_POINT' ? selectedPlaceId : undefined },
    deps,
  );
  const rows = found.rows;
  const where = scopeLabel(scope, lang);
  if (!rows.length) {
    return finish(noneFound(scope, lang), [], { type: 'NOOP' }, { total: 0, skipModel: true });
  }
  const top = rows[0];

  if (plan.intent === 'BIGGEST_GAP' || plan.intent === 'VAGUE_SAVE') {
    const answer = lang === 'en'
      ? `Biggest observed gap ${where}: ${rowLine(top, lang)}`
      : `أكبر فرق مرصود ${where}: ${rowLine(top, lang)}`;
    return finish(answer, rows, { type: 'FOCUS_PLACE', place_id: top.place_id }, { total: found.total });
  }
  if (plan.intent === 'CHEAPEST_IN_CATEGORY') {
    const answer = lang === 'en' ? `Cheapest observed ${where}: ${rowLine(top, lang)}` : `أرخص سعر مرصود ${where}: ${rowLine(top, lang)}`;
    return finish(answer, rows, { type: 'FOCUS_PLACE', place_id: top.place_id }, { total: found.total });
  }
  if (plan.intent === 'TOP_N') {
    const intro = lang === 'en' ? `Top ${rows.length} ${where}:` : `أفضل ${rows.length} ${where}:`;
    return finish(listAnswer(rows, scope, lang, intro), rows, { type: 'SHOW_RESULTS', place_ids: rows.map((r) => r.place_id) }, { total: found.total });
  }
  if (plan.intent === 'SET_MIN_GAP') {
    const intro = lang === 'en' ? `${found.total} opportunities above ${plan.slots.minGap} SAR ${where}:` : `${found.total} فرصة فوق ${plan.slots.minGap} ر.س ${where}:`;
    return finish(listAnswer(rows, scope, lang, intro), rows, { type: 'SET_FILTER', min_gap: plan.slots.minGap }, { total: found.total });
  }
  if (plan.intent === 'SET_CATEGORY') {
    const intro = lang === 'en' ? `${found.total} ${plan.slots.q} opportunities ${where}, biggest first:` : `${found.total} فرصة ${plan.slots.q} ${where}، الأكبر أولاً:`;
    return finish(listAnswer(rows.slice(0, 3), scope, lang, intro), rows, { type: 'SET_CATEGORY', category: plan.slots.category, q: plan.slots.q }, { total: found.total });
  }
  if (plan.intent === 'PLACE_SCOPE' || plan.intent === 'AROUND_POINT') {
    const intro = lang === 'en' ? `${found.total} opportunities ${where}, biggest first:` : `${found.total} فرصة ${where}، الأكبر أولاً:`;
    return finish(listAnswer(rows.slice(0, 3), scope, lang, intro), rows, { type: 'SHOW_RESULTS', place_ids: rows.map((r) => r.place_id) }, { total: found.total });
  }
  /* SEARCH */
  const intro = lang === 'en' ? `${found.total} matches for "${plan.slots.q}" ${where}:` : `${found.total} نتيجة لـ «${plan.slots.q}» ${where}:`;
  return finish(listAnswer(rows.slice(0, 3), scope, lang, intro), rows, { type: 'SET_SEARCH', q: plan.slots.q }, { total: found.total });
}

function __resetSessionsForTests() {
  sessions.clear();
}

module.exports = {
  ACTION_TYPES,
  GEMINI_MODELS,
  SYSTEM_PROMPT,
  handleCopilot,
  phraseWithGemini,
  validateAction,
  __resetSessionsForTests,
};
