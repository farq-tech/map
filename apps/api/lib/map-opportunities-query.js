'use strict';

const { comparisonQuery } = require('./comparison-pool');
const { scoreOpportunity, zoomMode } = require('./map-exploration');

const KSA = { lngMin: 34, lngMax: 56, latMin: 16, latMax: 33 };
const RIYADH = { west: 46.45, south: 24.45, east: 47.05, north: 25.05 };

function bbox(raw) {
  if (!raw) return RIYADH;
  const p = String(raw).split(',').map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isFinite(n))) return RIYADH;
  const [a, b, c, d] = p;
  return {
    west: Math.max(KSA.lngMin, Math.min(a, c)),
    south: Math.max(KSA.latMin, Math.min(b, d)),
    east: Math.min(KSA.lngMax, Math.max(a, c)),
    north: Math.min(KSA.latMax, Math.max(b, d)),
  };
}

function finite(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function pct(low, high) {
  if (low == null || high == null || high <= 0) return null;
  return Math.round(((high - low) / high) * 1000) / 10;
}

function categoryPredicate(category) {
  const c = String(category || '').trim().toLowerCase();
  const terms = {
    burgers: ['burger', 'برجر'],
    pizza: ['pizza', 'بيتزا'],
    coffee: ['coffee', 'قهوة', 'cafe', 'كافيه'],
    shawarma: ['shawarma', 'شاورما'],
    grocery: ['grocery', 'بقالة', 'سوبرماركت'],
  };
  return terms[c] || null;
}

/**
 * First-class opportunity query. It intentionally keeps the SQL contract
 * conservative: it only uses columns already proven by comparison-map.js.
 * Category filtering is applied to observed restaurant/product text until a
 * canonical category column is available in the comparison read model.
 */
async function queryOpportunities(opts = {}) {
  const b = bbox(opts.bbox);
  const zoom = finite(opts.zoom) ?? 11;
  const limit = Math.min(Math.max(finite(opts.limit) ?? 80, 1), 250);
  const q = String(opts.q || '').trim().toLowerCase();
  const terms = categoryPredicate(opts.category);
  const sql = `
    SELECT dc.canonical_restaurant_id::text AS restaurant_id,
           dc.canonical_name_ar,
           dc.canonical_name_en,
           dc.latitude,
           dc.longitude,
           dc.city,
           dc.provider_count,
           dc.branch_image_url,
           s.cheapest_provider,
           s.dearest_provider,
           s.cheapest_price,
           s.dearest_price,
           s.difference_amount,
           s.product_name
      FROM comparison.discovery_cards dc
      LEFT JOIN LATERAL (
        SELECT ips.cheapest_provider,
               ips.dearest_provider,
               ips.cheapest_price,
               ips.dearest_price,
               (ips.dearest_price - ips.cheapest_price) AS difference_amount,
               COALESCE(ips.name_ar, ips.name_en) AS product_name
          FROM comparison.item_price_spread ips
         WHERE ips.canonical_restaurant_id = dc.canonical_restaurant_id
           AND ips.cheapest_provider IS NOT NULL
           AND btrim(ips.cheapest_provider) <> ''
         ORDER BY (ips.dearest_price - ips.cheapest_price) DESC NULLS LAST
         LIMIT 1
      ) s ON true
     WHERE dc.latitude BETWEEN $1 AND $2
       AND dc.longitude BETWEEN $3 AND $4
       AND dc.latitude BETWEEN $5 AND $6
       AND dc.longitude BETWEEN $7 AND $8
     LIMIT 2500
  `;
  const rows = await comparisonQuery(sql, [b.south, b.north, b.west, b.east, KSA.latMin, KSA.latMax, KSA.lngMin, KSA.lngMax]);
  const opportunities = [];

  for (const row of rows) {
    const name = String(row.canonical_name_ar || row.canonical_name_en || '').trim();
    const product = String(row.product_name || '').trim();
    const hay = `${name} ${product} ${row.city || ''}`.toLowerCase();
    if (q && !hay.includes(q)) continue;
    if (terms && !terms.some((term) => hay.includes(term))) continue;

    const cheapest = finite(row.cheapest_price);
    const expensive = finite(row.dearest_price);
    const difference = finite(row.difference_amount);
    if (!row.cheapest_provider || difference == null || difference <= 0) continue;

    const item = {
      id: String(row.restaurant_id),
      type: 'opportunity',
      place: {
        id: String(row.restaurant_id),
        restaurant_id: String(row.restaurant_id),
        name,
        city: row.city ? String(row.city) : null,
        lat: finite(row.latitude),
        lng: finite(row.longitude),
        image_url: row.branch_image_url || null,
      },
      product: product ? { name: product } : null,
      price: {
        cheapest,
        expensive,
        difference,
        percentage: pct(cheapest, expensive),
        currency: 'SAR',
      },
      providers: {
        count: finite(row.provider_count),
        cheapest: String(row.cheapest_provider),
        expensive: row.dearest_provider ? String(row.dearest_provider) : null,
      },
      evidence: {
        observed: true,
        freshness: null,
        confidence: null,
        match_quality: null,
      },
      opportunity_score: scoreOpportunity({ difference, providers: row.provider_count }),
    };
    opportunities.push(item);
  }

  opportunities.sort((a, z) => z.opportunity_score - a.opportunity_score || z.price.difference - a.price.difference || a.id.localeCompare(z.id));
  const top = opportunities.slice(0, limit);

  return {
    type: 'map_opportunities',
    version: 2,
    viewport: { bbox: b, zoom },
    mode: zoomMode(zoom),
    count: top.length,
    matched: opportunities.length,
    opportunities: top,
    clusters: [],
    coverage: { source: 'comparison.discovery_cards + item_price_spread', matched: opportunities.length, shown: top.length },
  };
}

module.exports = { queryOpportunities };
