'use strict';

const {
  classifyQuestion,
  refuseForecast,
  insufficientComparison,
  placeNotFound,
  applyReplyPolicy,
  formatObservedReply,
} = require('./chat-policy');
const { resolveChatSearch } = require('./chat-intent');
const {
  GET_VISIBLE_OPPORTUNITIES_DECL,
  SEARCH_SOURCE_OPPORTUNITIES_DECL,
  isAllowedTool,
  runAllowedTool,
} = require('./chat-tools');

const SYSTEM_PROMPT = `أنت طبقة تفسير فوق بيانات مقارنة فرق من المصدر (نفس قاعدة المقارنة التي تتغذى منها الخريطة).

قواعد صارمة:
- المصدر الوحيد هو JSON الناتج من الأداة (search_source_opportunities أو get_visible_opportunities). لا يوجد ويب، لا معرفة عامة، لا اختراع أسعار.
- لا تخترع مطعماً أو بطلاً أو تصنيفاً أو إحداثيات أو سعراً غير موجود في JSON.
- الأرقام التي تذكرها يجب أن تظهر في JSON كما هي (فروقات مرصودة فقط).
- «ليش أفضل / ليش هذي فرصة قوية» = اشرح الفجوة المرصودة (أرخص مزود مقابل أعلى سعر) فقط. لا تقييم جودة ولا توقعات.
- ارفض أسئلة التوقع أو سعر المستقبل.
- إن كانت القائمة فارغة: قل إن ما عندنا مقارنة كافية في هالمنطقة حتى الآن. لا تقل إنك ما قدرت تفسّر الخريطة.
- أجب بالعربية، بجمل قصيرة، كنبرة أداة خريطة لا دردشة عامة.`;

function geminiKey() {
  return String(
    process.env.GEMINI_API_KEY ||
      process.env.GOOGLE_GENERATIVE_AI_API_KEY ||
      '',
  ).trim();
}

function chatConfigured() {
  return Boolean(geminiKey());
}

function geminiModel() {
  return String(process.env.GEMINI_MODEL || 'gemini-2.5-flash').trim();
}

function unconfiguredPayload() {
  return {
    ok: false,
    status: 503,
    error: 'chat_unconfigured',
    message_ar:
      'المحادثة غير مفعّلة حالياً — مفتاح النموذج غير مضبوط على الخادم.',
  };
}

function slimToolJson(opportunities) {
  return { opportunities: opportunities || [] };
}

async function callGemini(opts, deps = {}) {
  const fetchFn = deps.fetch || fetch;
  const key = geminiKey();
  const model = geminiModel();
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
  const body = {
    system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
    contents: [
      {
        role: 'user',
        parts: [{ text: opts.userText }],
      },
      {
        role: 'model',
        parts: [
          {
            functionCall: {
              name: opts.toolName || 'search_source_opportunities',
              args: {},
            },
          },
        ],
      },
      {
        role: 'user',
        parts: [
          {
            functionResponse: {
              name: opts.toolName || 'search_source_opportunities',
              response: slimToolJson(opts.opportunities),
            },
          },
        ],
      },
    ],
    tools: [
      {
        functionDeclarations: [
          SEARCH_SOURCE_OPPORTUNITIES_DECL,
          GET_VISIBLE_OPPORTUNITIES_DECL,
        ],
      },
    ],
    toolConfig: {
      functionCallingConfig: {
        mode: 'NONE',
      },
    },
    generationConfig: {
      temperature: 0.2,
      maxOutputTokens: 512,
    },
  };
  const res = await fetchFn(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const payload = await res.json().catch(() => null);
  if (!res.ok) {
    const err = new Error('gemini_unavailable');
    err.status = 502;
    err.detail = payload && payload.error ? payload.error.message : null;
    throw err;
  }
  return payload;
}

function extractGeminiText(payload) {
  const parts =
    payload &&
    payload.candidates &&
    payload.candidates[0] &&
    payload.candidates[0].content &&
    payload.candidates[0].content.parts;
  if (!Array.isArray(parts)) return '';
  return parts
    .map((p) => (p && typeof p.text === 'string' ? p.text : ''))
    .join('')
    .trim();
}

function extractFunctionCalls(payload) {
  const parts =
    payload &&
    payload.candidates &&
    payload.candidates[0] &&
    payload.candidates[0].content &&
    payload.candidates[0].content.parts;
  if (!Array.isArray(parts)) return [];
  return parts
    .filter((p) => p && p.functionCall && p.functionCall.name)
    .map((p) => ({
      name: p.functionCall.name,
      args: p.functionCall.args || {},
    }));
}

function toolSummary(tool) {
  if (!tool) return null;
  return {
    name: tool.name,
    queried_bbox: tool.queried_bbox,
    requested_bbox: tool.requested_bbox,
    count: Array.isArray(tool.opportunities) ? tool.opportunities.length : tool.count || 0,
    place: tool.place || null,
    empty_reason: tool.empty_reason || null,
  };
}

/**
 * Policy first, then Farq comparison source (named place / city / user)
 * or the optional viewport tool, then Gemini with search grounding off.
 */
async function handleChat(input, deps = {}) {
  const message = String(input && input.message != null ? input.message : '').trim();
  const viewportBbox = input && input.bbox;
  const selectedPlace = String(
    (input && (input.selected_place || input.selectedPlace)) || '',
  ).trim();
  const userLat = Number(input && (input.user_lat ?? input.userLat));
  const userLng = Number(input && (input.user_lng ?? input.userLng));
  const language = String((input && input.language) || 'ar').trim() === 'en' ? 'en' : 'ar';

  const intent = classifyQuestion(message);
  if (intent === 'empty') {
    return {
      ok: true,
      status: 200,
      text: insufficientComparison(),
      refused: 'empty',
      tool: null,
    };
  }
  if (intent === 'forecast') {
    return {
      ok: true,
      status: 200,
      text: refuseForecast(),
      refused: 'forecast',
      tool: null,
    };
  }

  const plan = resolveChatSearch(message, {
    userLat: Number.isFinite(userLat) ? userLat : null,
    userLng: Number.isFinite(userLng) ? userLng : null,
  });

  const tool = await runAllowedTool(
    plan.tool,
    { place: plan.place, q: plan.qTerms && plan.qTerms[0] },
    {
      viewportBbox,
      userLat: Number.isFinite(userLat) ? userLat : null,
      userLng: Number.isFinite(userLng) ? userLng : null,
      language,
      place: plan.place,
      qTerms: plan.qTerms,
      sort: plan.sort,
      bboxSource: plan.bboxSource,
      queryVisibleOpportunities: deps.queryVisibleOpportunities,
      querySourceOpportunities: deps.querySourceOpportunities,
      geocodePlace: deps.geocodePlace,
    },
  );

  if (tool.rejected) {
    return {
      ok: true,
      status: 200,
      text: insufficientComparison(),
      refused: 'tool',
      tool,
    };
  }

  const areaLabel = tool.geocode_label || tool.place || plan.place || '';
  if (
    tool.empty_reason === 'place_not_found' ||
    tool.empty_reason === 'geocode_unavailable' ||
    tool.empty_reason === 'geocode_unconfigured' ||
    tool.empty_reason === 'empty_query'
  ) {
    return {
      ok: true,
      status: 200,
      text: placeNotFound(areaLabel || plan.place),
      refused: 'place_not_found',
      tool: toolSummary(tool),
    };
  }

  if (!tool.opportunities || tool.opportunities.length === 0) {
    return {
      ok: true,
      status: 200,
      text: insufficientComparison(areaLabel),
      refused: 'insufficient_comparison',
      tool: toolSummary({ ...tool, opportunities: [] }),
    };
  }

  if (deps.skipModel) {
    return {
      ok: true,
      status: 200,
      text: insufficientComparison(),
      refused: 'skip_model',
      tool: toolSummary(tool),
      opportunities: tool.opportunities,
    };
  }

  if (!chatConfigured() && !deps.generateGemini) {
    return unconfiguredPayload();
  }

  const focus = selectedPlace ? `\nالمكان المحدد على الخريطة: ${selectedPlace}` : '';
  const userText = `${message}${focus}`;

  const generate = deps.generateGemini || callGemini;
  let payload;
  try {
    payload = await generate(
      {
        userText,
        opportunities: tool.opportunities,
        viewportBbox,
        toolName: tool.name,
      },
      deps,
    );
  } catch (err) {
    if (err && err.detail) {
      console.warn('[chat] gemini_unavailable', err.detail);
    }
    const fallback = formatObservedReply(tool.opportunities);
    if (fallback && fallback !== insufficientComparison()) {
      return {
        ok: true,
        status: 200,
        text: fallback,
        refused: 'model_fallback',
        tool: toolSummary(tool),
      };
    }
    return {
      ok: false,
      status: err && err.status === 503 ? 503 : 502,
      error: 'gemini_unavailable',
      message_ar: 'تعذر تفسير الخريطة الآن. الخريطة نفسها ما زالت تعمل.',
      tool: toolSummary(tool),
    };
  }

  const extraCalls = extractFunctionCalls(payload);
  for (const call of extraCalls) {
    if (!isAllowedTool(call.name)) {
      return {
        ok: true,
        status: 200,
        text: insufficientComparison(),
        refused: 'extra_tool',
        tool: {
          name: tool.name,
          queried_bbox: tool.queried_bbox,
          requested_bbox: tool.requested_bbox,
          count: tool.opportunities.length,
        },
      };
    }
    await runAllowedTool(call.name, call.args, {
      viewportBbox,
      queryVisibleOpportunities: deps.queryVisibleOpportunities,
      querySourceOpportunities: deps.querySourceOpportunities,
      geocodePlace: deps.geocodePlace,
    });
  }

  const raw = extractGeminiText(payload);
  const text = applyReplyPolicy(raw, tool.opportunities);
  return {
    ok: true,
    status: 200,
    text,
    refused: text === insufficientComparison() && raw && raw !== text
      ? 'invented_numbers'
      : null,
    tool: toolSummary(tool),
  };
}

module.exports = {
  SYSTEM_PROMPT,
  chatConfigured,
  geminiModel,
  unconfiguredPayload,
  handleChat,
  callGemini,
  extractGeminiText,
  extractFunctionCalls,
  slimToolJson,
};
