'use strict';

/**
 * Comparison menu catalog — facts from comparison.restaurant_menu_catalog.
 * Does not invent dishes or categories.
 */

const { comparisonQuery, comparisonDbUrl } = require('./comparison-pool');

function flagOn(name) {
  const v = process.env[name];
  return v === '1' || v === 'true';
}

function readEnabled() {
  return flagOn('SUPABASE_COMPARISON_READ_ENABLED');
}

function catalogEnabled() {
  return readEnabled() && flagOn('MENU_CATALOG_ENABLED');
}

const RESTAURANT_SQL = `
SELECT pr.canonical_restaurant_id::text AS id,
       pr.canonical_name_ar,
       pr.canonical_name_en,
       pr.city,
       pr.provider_count,
       pr.product_ready,
       (
         SELECT COALESCE(bpi.primary_image_url, dc.branch_image_url)
           FROM comparison.discovery_cards dc
           LEFT JOIN comparison.brand_primary_images bpi
             ON bpi.brand_key = dc.brand_key
          WHERE dc.canonical_restaurant_id = pr.canonical_restaurant_id
          LIMIT 1
       ) AS image_url
  FROM comparison.product_ready_restaurants pr
 WHERE pr.canonical_restaurant_id = $1
 LIMIT 1
`;

const CATALOG_SQL = `
SELECT c.entry_type,
       c.entry_id::text AS entry_id,
       c.name_ar,
       c.name_en,
       NULLIF(btrim(c.image), '') AS image,
       c.size_value,
       c.size_unit,
       c.farq_category_id::text AS category_id,
       c.category_slug,
       c.category_name_ar,
       c.category_name_en,
       c.category_display_priority,
       c.offer_provider_count,
       c.cheapest_price,
       c.single_price,
       c.single_original_price,
       c.single_provider_code,
       c.currency,
       o.offers
  FROM comparison.restaurant_menu_catalog c
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
             'provider', d.provider_code,
             'price', d.current_price,
             'original_price', d.original_price
           ) ORDER BY d.current_price, d.provider_code) AS offers
      FROM (
        SELECT DISTINCT ON (mo.provider_code)
               mo.provider_code, mo.current_price, mo.original_price
          FROM comparison.menu_item_offers mo
         WHERE mo.canonical_restaurant_id = c.canonical_restaurant_id
           AND mo.canonical_item_id = c.entry_id
         ORDER BY mo.provider_code, mo.current_price ASC
      ) d
  ) o ON c.entry_type = 'identity'
 WHERE c.canonical_restaurant_id = $1
 ORDER BY c.category_display_priority ASC NULLS LAST,
          c.name_ar ASC NULLS LAST,
          c.name_en ASC NULLS LAST,
          c.entry_id
`;

function classify(row) {
  const offers = Array.isArray(row.offers) ? row.offers : [];
  if (row.entry_type === 'identity' && offers.length >= 2) return 'comparable';
  if (row.entry_type === 'identity' && offers.length === 1) return 'partial';
  return 'single_provider';
}

function toItem(row) {
  const offers = Array.isArray(row.offers) ? row.offers : [];
  const prices = offers
    .map((o) => Number(o.price))
    .filter((n) => Number.isFinite(n));
  const cheapest =
    prices.length > 0
      ? Math.min(...prices)
      : row.cheapest_price != null
        ? Number(row.cheapest_price)
        : row.single_price != null
          ? Number(row.single_price)
          : null;
  const dearest = prices.length > 0 ? Math.max(...prices) : cheapest;
  const cheapestOffer = offers
    .slice()
    .sort((a, b) => Number(a.price) - Number(b.price))[0];
  return {
    id: row.entry_id,
    entry_type: row.entry_type,
    classification: classify(row),
    name: row.name_en || row.name_ar,
    name_ar: row.name_ar,
    name_en: row.name_en,
    image: row.image,
    cheapest_price: cheapest,
    dearest_price: dearest,
    difference_amount:
      cheapest != null && dearest != null ? dearest - cheapest : null,
    cheapest_provider: cheapestOffer
      ? cheapestOffer.provider
      : row.single_provider_code,
    offers,
  };
}

function buildCategories(rows) {
  const sections = new Map();
  for (const row of rows) {
    const isFallback = row.category_id == null;
    const key = isFallback ? 'other' : String(row.category_id);
    if (!sections.has(key)) {
      sections.set(key, {
        id: key,
        slug: isFallback ? 'other' : row.category_slug || key,
        name_ar: isFallback ? 'أخرى' : row.category_name_ar || 'أخرى',
        name_en: isFallback ? 'Other' : row.category_name_en || 'Other',
        _priority:
          isFallback || row.category_display_priority == null
            ? Number.MAX_SAFE_INTEGER
            : Number(row.category_display_priority),
        items: [],
      });
    }
    sections.get(key).items.push(toItem(row));
  }
  return [...sections.values()]
    .sort((a, b) => a._priority - b._priority)
    .map((s, i) => ({
      id: s.id,
      slug: s.slug,
      name_ar: s.name_ar,
      name_en: s.name_en,
      display_order: i + 1,
      item_count: s.items.length,
      items: s.items,
    }));
}

function flattenItems(categories) {
  return categories.flatMap((c) => c.items);
}

async function getCatalog(restaurantId) {
  if (!catalogEnabled()) {
    return { ok: false, status: 503, error: 'catalog_disabled' };
  }
  if (!comparisonDbUrl()) {
    return { ok: false, status: 503, error: 'comparison_db_unset' };
  }
  const id = String(restaurantId || '').trim();
  if (!/^\d+$/.test(id)) {
    return { ok: false, status: 400, error: 'invalid_id' };
  }
  const [restaurants, rows] = await Promise.all([
    comparisonQuery(RESTAURANT_SQL, [id]),
    comparisonQuery(CATALOG_SQL, [id]),
  ]);
  const restaurant = restaurants[0];
  if (!restaurant) {
    return { ok: false, status: 404, error: 'not_found' };
  }
  const categories = buildCategories(rows);
  const items = flattenItems(categories);
  return {
    ok: true,
    status: 200,
    restaurant: {
      id: restaurant.id,
      name_ar: restaurant.canonical_name_ar,
      name_en: restaurant.canonical_name_en,
      city: restaurant.city,
      image_url: restaurant.image_url || null,
      provider_count: restaurant.provider_count,
    },
    categories,
    summary: {
      category_count: categories.length,
      total_items: items.length,
    },
    items,
  };
}

function catalogJson(body) {
  return {
    ok: true,
    restaurant: body.restaurant,
    categories: body.categories,
    summary: body.summary,
  };
}

module.exports = {
  catalogEnabled,
  getCatalog,
  catalogJson,
  flattenItems,
};
