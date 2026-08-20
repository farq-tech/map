'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { handleChat, callGemini } = require('./chat-handler');
const { runAllowedTool, isAllowedTool } = require('./chat-tools');
const {
  INSUFFICIENT_COMPARISON_AR,
  FORECAST_REFUSAL_AR,
} = require('./chat-policy');

const VIEWPORT = '46.72,24.70,46.82,24.80';
const RIYADH = '46.45,24.45,47.05,25.05';
const MAGHRZAT_BBOX = {
  west: 46.74,
  south: 24.76,
  east: 46.78,
  north: 24.8,
};

const SLIM_ROWS = [
  {
    place: 'شاورما هوم',
    cheapest_provider: 'hungerstation',
    cheapest_price: 18,
    highest_price: 29,
    difference_amount: 11,
    lat: 24.713,
    lng: 46.675,
  },
];

const BURGER_ROWS = [
  {
    place: 'برجر ستيشن',
    cheapest_provider: 'hungerstation',
    cheapest_price: 19,
    highest_price: 28,
    difference_amount: 9,
    item: 'برجر كلاسيك',
    lat: 24.77,
    lng: 46.76,
  },
];

function mockVisible(calls) {
  return async ({ bbox }) => {
    calls.push(bbox);
    if (!bbox) {
      return {
        opportunities: [],
        queried_bbox: null,
        requested_bbox: null,
        empty_reason: 'invalid_bbox',
      };
    }
    return {
      opportunities: SLIM_ROWS,
      queried_bbox: {
        west: 46.72,
        south: 24.7,
        east: 46.82,
        north: 24.8,
      },
      requested_bbox: {
        west: 46.72,
        south: 24.7,
        east: 46.82,
        north: 24.8,
      },
      empty_reason: null,
    };
  };
}

function mockSource(calls, rows = SLIM_ROWS) {
  return async (opts) => {
    calls.push(opts);
    return {
      opportunities: rows,
      queried_bbox: MAGHRZAT_BBOX,
      requested_bbox: MAGHRZAT_BBOX,
      empty_reason: rows.length ? null : 'insufficient_comparison',
      q_terms: opts.qTerms || null,
      sort: opts.sort || 'gap',
    };
  };
}

describe('chat handler — source search + policy', () => {
  it('named place queries the source bbox, not the camera viewport', async () => {
    const sourceCalls = [];
    const visibleCalls = [];
    const result = await handleChat(
      { message: 'أرخص برجر في المغرزات', bbox: VIEWPORT },
      {
        queryVisibleOpportunities: mockVisible(visibleCalls),
        querySourceOpportunities: mockSource(sourceCalls, BURGER_ROWS),
        geocodePlace: async (place) => {
          assert.equal(place, 'المغرزات');
          return { ok: true, bbox: MAGHRZAT_BBOX, label: 'المغرزات' };
        },
        skipModel: true,
      },
    );
    assert.equal(visibleCalls.length, 0);
    assert.equal(sourceCalls.length, 1);
    assert.match(sourceCalls[0].bbox, /46\.74/);
    assert.ok(sourceCalls[0].qTerms.includes('برجر'));
    assert.equal(sourceCalls[0].sort, 'cheapest');
    assert.equal(result.tool.name, 'search_source_opportunities');
    assert.equal(result.tool.place, 'المغرزات');
    assert.notEqual(result.tool.queried_bbox.west, 46.72);
  });

  it('viewport-only questions still use the camera bbox', async () => {
    const calls = [];
    const result = await handleChat(
      { message: 'وين أكبر فرق بهالنطاق؟', bbox: VIEWPORT },
      {
        queryVisibleOpportunities: mockVisible(calls),
        querySourceOpportunities: async () => {
          throw new Error('must_not_hit_source');
        },
        skipModel: true,
      },
    );
    assert.deepEqual(calls, [VIEWPORT]);
    assert.notEqual(calls[0], RIYADH);
    assert.equal(result.tool.name, 'get_visible_opportunities');
  });

  it('empty source after a real query is honesty, not map-interpret failure', async () => {
    const result = await handleChat(
      { message: 'أرخص برجر في المغرزات', bbox: VIEWPORT },
      {
        querySourceOpportunities: mockSource([], []),
        geocodePlace: async () => ({
          ok: true,
          bbox: MAGHRZAT_BBOX,
          label: 'المغرزات',
        }),
        generateGemini: async () => {
          throw new Error('should_not_call_model');
        },
      },
    );
    assert.match(result.text, /المغرزات/);
    assert.equal(result.refused, 'insufficient_comparison');
    assert.equal(result.status, 200);
    assert.notEqual(result.error, 'gemini_unavailable');
  });

  it('unknown neighborhood does not invent coordinates', async () => {
    const result = await handleChat(
      { message: 'أرخص برجر في حي وهمي', bbox: VIEWPORT },
      {
        querySourceOpportunities: async () => {
          throw new Error('must_not_query_source');
        },
        geocodePlace: async () => ({
          ok: false,
          reason: 'place_not_found',
          bbox: null,
        }),
        generateGemini: async () => {
          throw new Error('should_not_call_model');
        },
      },
    );
    assert.equal(result.refused, 'place_not_found');
    assert.match(result.text, /وهمي|المصدر/);
    assert.equal(result.status, 200);
  });

  it('forecast intent is refused by the policy layer — tool is not required', async () => {
    let queried = false;
    const result = await handleChat(
      { message: 'كم بيصير السعر بعد شهر؟', bbox: VIEWPORT },
      {
        queryVisibleOpportunities: async () => {
          queried = true;
          throw new Error('should_not_query');
        },
        generateGemini: async () => {
          throw new Error('should_not_call_model');
        },
      },
    );
    assert.equal(result.text, FORECAST_REFUSAL_AR);
    assert.equal(result.refused, 'forecast');
    assert.equal(queried, false);
  });

  it('rejects web-search tools', async () => {
    assert.equal(isAllowedTool('google_search'), false);
    assert.equal(isAllowedTool('web_search'), false);
    assert.equal(isAllowedTool('get_visible_opportunities'), true);
    assert.equal(isAllowedTool('search_source_opportunities'), true);
    const result = await runAllowedTool('google_search', { q: 'Al Baik' }, {
      viewportBbox: VIEWPORT,
      queryVisibleOpportunities: async () => {
        throw new Error('must_not_run');
      },
    });
    assert.equal(result.rejected, true);
    assert.equal(result.error, 'tool_not_allowed');
  });

  it('ignores a model-requested bbox and still queries the viewport tool box', async () => {
    const calls = [];
    await runAllowedTool(
      'get_visible_opportunities',
      { bbox: RIYADH },
      {
        viewportBbox: VIEWPORT,
        queryVisibleOpportunities: mockVisible(calls),
      },
    );
    assert.deepEqual(calls, [VIEWPORT]);
  });

  it('if the model asks for another tool, the handler will not execute it', async () => {
    const sourceCalls = [];
    const result = await handleChat(
      { message: 'وين أكبر فرق؟', bbox: VIEWPORT },
      {
        querySourceOpportunities: mockSource(sourceCalls),
        generateGemini: async () => ({
          candidates: [
            {
              content: {
                parts: [
                  {
                    functionCall: {
                      name: 'google_search',
                      args: { q: 'riyadh prices' },
                    },
                  },
                ],
              },
            },
          ],
        }),
      },
    );
    assert.equal(result.refused, 'extra_tool');
    assert.equal(result.text, INSUFFICIENT_COMPARISON_AR);
    assert.equal(sourceCalls.length, 1);
  });

  it('output check drops a reply whose numbers are not in the tool JSON', async () => {
    const result = await handleChat(
      { message: 'وين أكبر فرق بهالنطاق؟', bbox: VIEWPORT },
      {
        queryVisibleOpportunities: mockVisible([]),
        generateGemini: async () => ({
          candidates: [
            {
              content: {
                parts: [{ text: 'أكبر فرق عند البيك بـ 87 ريال' }],
              },
            },
          ],
        }),
      },
    );
    assert.equal(result.text, INSUFFICIENT_COMPARISON_AR);
    assert.equal(result.refused, 'invented_numbers');
  });

  it('Gemini request has source + viewport tools and no web grounding', async () => {
    const prev = process.env.GEMINI_API_KEY;
    process.env.GEMINI_API_KEY = 'test-not-a-real-key';
    let posted = null;
    try {
      await callGemini(
        {
          userText: 'أرخص برجر في المغرزات',
          opportunities: BURGER_ROWS,
          toolName: 'search_source_opportunities',
        },
        {
          fetch: async (url, init) => {
            posted = { url: String(url).split('?')[0], body: JSON.parse(init.body) };
            return {
              ok: true,
              json: async () => ({
                candidates: [{ content: { parts: [{ text: 'أرخص برجر ١٩ ر.س' }] } }],
              }),
            };
          },
        },
      );
    } finally {
      if (prev == null) delete process.env.GEMINI_API_KEY;
      else process.env.GEMINI_API_KEY = prev;
    }
    assert.ok(posted);
    assert.match(posted.url, /generativelanguage\.googleapis\.com/);
    const dumped = JSON.stringify(posted.body);
    assert.equal(dumped.includes('googleSearch'), false);
    assert.equal(dumped.includes('google_search'), false);
    assert.equal(dumped.includes('web_search'), false);
    const names = posted.body.tools[0].functionDeclarations.map((d) => d.name);
    assert.ok(names.includes('search_source_opportunities'));
    assert.ok(names.includes('get_visible_opportunities'));
    assert.equal(posted.body.toolConfig.functionCallingConfig.mode, 'NONE');
    assert.equal(
      posted.body.contents[1].parts[0].functionCall.name,
      'search_source_opportunities',
    );
  });

  it('keeps a reply whose numbers appear in the slim tool JSON', async () => {
    const result = await handleChat(
      { message: 'وين أكبر فرق بهالنطاق؟', bbox: VIEWPORT },
      {
        queryVisibleOpportunities: mockVisible([]),
        generateGemini: async () => ({
          candidates: [
            {
              content: {
                parts: [{ text: 'أكبر فرق مرصود ١١ ر.س عند شاورما هوم (١٨ مقابل ٢٩).' }],
              },
            },
          ],
        }),
      },
    );
    assert.match(result.text, /١١|11/);
    assert.equal(result.refused, null);
  });

  it('model failure with observed rows returns source facts, not تعذر تفسير الخريطة', async () => {
    const result = await handleChat(
      { message: 'وين أكبر فرق؟' },
      {
        querySourceOpportunities: mockSource([]),
        generateGemini: async () => {
          const err = new Error('gemini_unavailable');
          err.status = 502;
          throw err;
        },
      },
    );
    assert.equal(result.ok, true);
    assert.equal(result.status, 200);
    assert.equal(result.refused, 'model_fallback');
    assert.match(result.text, /شاورما هوم/);
    assert.match(result.text, /11|١١/);
  });
});
