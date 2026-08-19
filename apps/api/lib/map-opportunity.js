'use strict';

/**
 * Farq Map Opportunity Presentation Layer.
 *
 * This is intentionally pure: it does not invent coordinates, prices,
 * providers, freshness, or confidence. It only turns an observed map place
 * into the semantic object consumed by the map UI.
 */

function finite(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function percentage(cheapest, expensive, difference) {
  const low = finite(cheapest);
  const high = finite(expensive);
  const gap = finite(difference);
  if (low == null || high == null || high <= 0 || gap == null) return null;
  return Math.round((gap / high) * 1000) / 10;
}

function scoreOpportunity(place) {
  const gap = Math.max(0, finite(place?.difference?.difference_amount) || 0);
  const providers = Math.max(0, finite(place?.provider_count) || 0);

  // Ranking is deliberately conservative until confidence/match/freshness
  // are supplied by the comparison read layer. Missing evidence = neutral,
  // never fabricated confidence.
  const coverage = Math.min(1, providers / 3);
  return Math.round((gap * (0.75 + coverage * 0.25)) * 100) / 100;
}

function toOpportunity(feature) {
  if (!feature || feature.properties?.feature_type !== 'place') return null;

  const p = feature.properties || {};
  const d = p.difference || null;
  const coordinates = feature.geometry?.coordinates;
  if (!Array.isArray(coordinates) || coordinates.length < 2) return null;

  const cheapest = finite(d?.cheapest_price);
  const expensive = finite(d?.expensive_price);
  const difference = finite(d?.difference_amount);

  return {
    id: String(p.place_id || ''),
    type: 'opportunity',
    place: {
      id: String(p.place_id || ''),
      restaurant_id: p.restaurant_id ? String(p.restaurant_id) : null,
      name: p.name || null,
      lat: Number(coordinates[1]),
      lng: Number(coordinates[0]),
      image_url: p.image_url || null,
    },
    category: p.category || null,
    product: d?.product_name ? { name: d.product_name } : null,
    price: {
      cheapest,
      expensive,
      difference,
      percentage: percentage(cheapest, expensive, difference),
      currency: 'SAR',
    },
    providers: {
      count: finite(p.provider_count),
      cheapest: d?.cheapest_provider_id || null,
      expensive: d?.expensive_provider_id || null,
    },
    evidence: {
      observed: Boolean(d),
      freshness: d?.observed_at || null,
      confidence: d?.confidence ?? null,
      match_quality: d?.match_quality ?? null,
    },
    opportunity_score: scoreOpportunity({
      provider_count: p.provider_count,
      difference: d,
    }),
  };
}

function toCluster(feature) {
  if (!feature || feature.properties?.feature_type !== 'cluster') return null;
  const coordinates = feature.geometry?.coordinates;
  if (!Array.isArray(coordinates) || coordinates.length < 2) return null;
  return {
    id: `cluster:${Number(coordinates[0]).toFixed(5)}:${Number(coordinates[1]).toFixed(5)}`,
    type: 'opportunity_cluster',
    lat: Number(coordinates[1]),
    lng: Number(coordinates[0]),
    place_count: finite(feature.properties?.count) || 0,
    opportunity_count: finite(feature.properties?.difference_count) || 0,
  };
}

function buildPresentation(body) {
  const features = Array.isArray(body?.features) ? body.features : [];
  const opportunities = [];
  const clusters = [];

  for (const feature of features) {
    const opportunity = toOpportunity(feature);
    if (opportunity) opportunities.push(opportunity);
    const cluster = toCluster(feature);
    if (cluster) clusters.push(cluster);
  }

  opportunities.sort((a, b) => {
    if (b.opportunity_score !== a.opportunity_score) {
      return b.opportunity_score - a.opportunity_score;
    }
    return String(a.id).localeCompare(String(b.id));
  });

  return {
    type: 'map_opportunities',
    version: 1,
    viewport: {
      bbox: body?.bbox || null,
      zoom: finite(body?.zoom),
    },
    opportunities,
    clusters,
    coverage: body?.coverage || null,
    source: 'comparison.discovery_cards',
  };
}

module.exports = {
  buildPresentation,
  percentage,
  scoreOpportunity,
  toOpportunity,
};
