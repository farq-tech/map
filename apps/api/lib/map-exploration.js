'use strict';

/**
 * Product rules for Farq Map exploration.
 * Pure functions only: no coordinates or market facts are invented here.
 */

const ZOOM_MODE = Object.freeze({
  DISCOVER: 'discover',
  OPPORTUNITY: 'opportunity',
  RESTAURANT: 'restaurant',
  DECISION: 'decision',
});

function finite(value, fallback = null) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function zoomMode(zoom) {
  const z = finite(zoom, 0);
  if (z < 11) return ZOOM_MODE.DISCOVER;
  if (z < 13.5) return ZOOM_MODE.OPPORTUNITY;
  if (z < 15) return ZOOM_MODE.RESTAURANT;
  return ZOOM_MODE.DECISION;
}

function scoreOpportunity({ difference = 0, providers = 0, confidence = null, matchQuality = null, freshnessHours = null, distanceMeters = null } = {}) {
  const gap = Math.max(0, finite(difference, 0));
  const coverage = Math.min(1, Math.max(0, finite(providers, 0)) / 4);
  const evidence = confidence == null ? 0.75 : Math.max(0.35, Math.min(1, finite(confidence, 0.75)));
  const match = matchQuality == null ? 0.8 : Math.max(0.4, Math.min(1, finite(matchQuality, 0.8)));
  const freshness = freshnessHours == null ? 0.85 : Math.max(0.45, Math.min(1, 1 - Math.max(0, freshnessHours) / 48));
  const distance = distanceMeters == null ? 0.9 : Math.max(0.45, 1 - Math.min(1, Math.max(0, distanceMeters) / 5000) * 0.35);
  return Math.round(gap * (0.7 + coverage * 0.3) * evidence * match * freshness * distance * 100) / 100;
}

function sortOpportunities(items) {
  return [...items].sort((a, b) => {
    const score = finite(b.opportunity_score, 0) - finite(a.opportunity_score, 0);
    if (score) return score;
    const gap = finite(b.price?.difference, 0) - finite(a.price?.difference, 0);
    if (gap) return gap;
    return String(a.id).localeCompare(String(b.id));
  });
}

function buildExplorationSummary(opportunities, zoom) {
  const sorted = sortOpportunities(opportunities || []);
  const top = sorted[0] || null;
  return {
    mode: zoomMode(zoom),
    count: sorted.length,
    top: top ? {
      id: top.id,
      difference: finite(top.price?.difference),
      percentage: finite(top.price?.percentage),
      distance_meters: finite(top.distance_meters),
    } : null,
    has_opportunities: sorted.length > 0,
  };
}

module.exports = { ZOOM_MODE, zoomMode, scoreOpportunity, sortOpportunities, buildExplorationSummary };
