'use strict';

const {
  RIYADH_VIEW,
  bboxAroundPoint,
  bboxToCsv,
  parseViewportBbox,
  querySourceOpportunities,
  queryVisibleOpportunities,
} = require('./comparison-map');
const { geocodePlace } = require('./geocode-place');

const ALLOWED_TOOL_NAMES = Object.freeze([
  'get_visible_opportunities',
  'search_source_opportunities',
]);

const GET_VISIBLE_OPPORTUNITIES_DECL = Object.freeze({
  name: 'get_visible_opportunities',
  description:
    'Observed price gaps in the current map viewport only. Use when the user asks about what is on screen. The server uses the request viewport bbox.',
  parameters: {
    type: 'OBJECT',
    properties: {
      bbox: {
        type: 'STRING',
        description:
          'Ignored. The server substitutes the client viewport bbox.',
      },
    },
  },
});

const SEARCH_SOURCE_OPPORTUNITIES_DECL = Object.freeze({
  name: 'search_source_opportunities',
  description:
    'Observed price gaps from the Farq comparison source (same DB as the map). Use for a named neighborhood, a food query such as برجر, near the user, or all of Riyadh coverage. Never invent coordinates or prices.',
  parameters: {
    type: 'OBJECT',
    properties: {
      place: {
        type: 'STRING',
        description: 'Neighborhood or area name to geocode, e.g. المغرزات.',
      },
      q: {
        type: 'STRING',
        description: 'Dish or category query such as برجر or burger.',
      },
    },
  },
});

function isAllowedTool(name) {
  return ALLOWED_TOOL_NAMES.includes(name);
}

function emptyTool(name, extra = {}) {
  return {
    rejected: false,
    name,
    queried_bbox: null,
    requested_bbox: null,
    opportunities: [],
    empty_reason: extra.empty_reason || 'insufficient_comparison',
    place: extra.place || null,
    geocode_label: extra.geocode_label || null,
  };
}

async function runVisibleTool(ctx) {
  const query = ctx.queryVisibleOpportunities || queryVisibleOpportunities;
  const result = await query({ bbox: ctx.viewportBbox });
  return {
    rejected: false,
    name: 'get_visible_opportunities',
    queried_bbox: result.queried_bbox,
    requested_bbox: result.requested_bbox,
    opportunities: result.opportunities,
    empty_reason: result.empty_reason,
    place: null,
    geocode_label: null,
  };
}

async function resolveSourceBbox(ctx) {
  const place = String(ctx.place || '').trim();
  if (ctx.bboxSource === 'place' && place) {
    const geocode = ctx.geocodePlace || geocodePlace;
    const geo = await geocode(place, { language: ctx.language });
    if (!geo || !geo.ok || !geo.bbox) {
      return {
        bbox: null,
        empty_reason: (geo && geo.reason) || 'place_not_found',
        geocode_label: null,
      };
    }
    return {
      bbox: geo.bbox,
      empty_reason: null,
      geocode_label: geo.label || place,
    };
  }
  if (
    ctx.bboxSource === 'user' &&
    Number.isFinite(ctx.userLat) &&
    Number.isFinite(ctx.userLng)
  ) {
    return {
      bbox: bboxAroundPoint(ctx.userLng, ctx.userLat),
      empty_reason: null,
      geocode_label: null,
    };
  }
  if (ctx.bboxSource === 'viewport') {
    const box = parseViewportBbox(ctx.viewportBbox);
    if (!box) {
      return { bbox: null, empty_reason: 'invalid_bbox', geocode_label: null };
    }
    return { bbox: box, empty_reason: null, geocode_label: null };
  }
  return {
    bbox: RIYADH_VIEW.bbox,
    empty_reason: null,
    geocode_label: null,
  };
}

async function runSourceTool(ctx) {
  const resolved = await resolveSourceBbox(ctx);
  if (!resolved.bbox) {
    return emptyTool('search_source_opportunities', {
      empty_reason: resolved.empty_reason,
      place: ctx.place || null,
    });
  }
  const query = ctx.querySourceOpportunities || querySourceOpportunities;
  const result = await query({
    bbox: bboxToCsv(resolved.bbox),
    qTerms: ctx.qTerms,
    sort: ctx.sort,
  });
  return {
    rejected: false,
    name: 'search_source_opportunities',
    queried_bbox: result.queried_bbox,
    requested_bbox: result.requested_bbox,
    opportunities: result.opportunities,
    empty_reason: result.empty_reason,
    place: ctx.place || null,
    geocode_label: resolved.geocode_label,
    q_terms: result.q_terms || ctx.qTerms || null,
    sort: result.sort || ctx.sort || 'gap',
  };
}

/**
 * Tool registry. Unknown names are rejected and never executed.
 * Viewport tool ignores model bbox. Source tool geocodes a named place
 * or uses user/city coverage from the Farq comparison source.
 */
async function runAllowedTool(name, _args, ctx = {}) {
  if (!isAllowedTool(name)) {
    return {
      rejected: true,
      error: 'tool_not_allowed',
      name: String(name || ''),
    };
  }
  if (name === 'get_visible_opportunities') {
    return runVisibleTool(ctx);
  }
  return runSourceTool(ctx);
}

module.exports = {
  ALLOWED_TOOL_NAMES,
  GET_VISIBLE_OPPORTUNITIES_DECL,
  SEARCH_SOURCE_OPPORTUNITIES_DECL,
  isAllowedTool,
  runAllowedTool,
};
