'use strict';

/**
 * Shared map filter semantics.
 * Biggest-savings floors come from the existing comparison read layer
 * (>=15 SAR cheapest price, >=10 SAR gap) — not invented here.
 */

const BIGGEST_SAVINGS_MIN_GAP = 10;
const BIGGEST_SAVINGS_MIN_PRICE = 15;

const CATEGORY_TERMS = Object.freeze({
  burgers: ['burger', 'برجر'],
  pizza: ['pizza', 'بيتزا'],
  coffee: ['coffee', 'قهوة', 'cafe', 'كافيه', 'كوفي'],
  shawarma: ['shawarma', 'شاورما'],
  grocery: ['grocery', 'بقالة', 'سوبرماركت', 'supermarket', 'تموين'],
});

const SECTORS = Object.freeze({
  restaurant: { sector_id: 'restaurant', sector_name_ar: 'مطاعم', sector_name_en: 'Restaurants' },
  grocery: { sector_id: 'grocery', sector_name_ar: 'بقالة', sector_name_en: 'Grocery' },
});

function norm(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function categoryTerms(category) {
  const c = norm(category);
  if (!c || c === 'all' || c === 'food' || c === 'restaurant') return null;
  return CATEGORY_TERMS[c] || null;
}

function resolveSector(sector, category) {
  const s = norm(sector);
  if (s === 'grocery' || s === 'shopping') return 'grocery';
  if (s === 'restaurant' || s === 'food') return 'restaurant';
  const c = norm(category);
  if (c === 'grocery' || c === 'shopping') return 'grocery';
  if (c) return 'restaurant';
  return 'all';
}

function haystack(place) {
  return norm(
    [place.name, place.name_ar, place.name_en, place.city, place.product_name].join(' '),
  );
}

function matchesCategory(place, category) {
  const terms = categoryTerms(category);
  if (!terms) return true;
  const hay = haystack(place);
  return terms.some((term) => hay.includes(term));
}

function matchesSector(place, sector, category) {
  const resolved = resolveSector(sector, category);
  if (resolved === 'all') return true;
  if (resolved === 'grocery') return matchesCategory(place, 'grocery');
  if (resolved === 'restaurant') return !matchesCategory(place, 'grocery');
  return true;
}

function isBiggestSavings(place) {
  const gap = Number(place.difference_amount);
  const cheap = Number(place.cheapest_price);
  if (!Number.isFinite(gap) || gap < BIGGEST_SAVINGS_MIN_GAP) return false;
  if (Number.isFinite(cheap) && cheap > 0 && cheap < BIGGEST_SAVINGS_MIN_PRICE) {
    return false;
  }
  return Boolean(place.cheapest_provider);
}

function matchesFilter(place, filter) {
  const f = norm(filter);
  if (!f || f === 'all') return true;
  if (f === 'biggest' || f === 'biggest_savings' || f === 'savings') {
    return isBiggestSavings(place);
  }
  if (f === 'multi' || f === 'multi_provider' || f === 'providers') {
    /* discovery_cards already require 2 apps to exist; 3+ is the useful cut */
    return Number(place.provider_count) >= 3;
  }
  if (f === 'compared' || f === 'has_difference') {
    return Boolean(place.cheapest_provider);
  }
  return true;
}

module.exports = {
  BIGGEST_SAVINGS_MIN_GAP,
  BIGGEST_SAVINGS_MIN_PRICE,
  CATEGORY_TERMS,
  SECTORS,
  norm,
  categoryTerms,
  resolveSector,
  matchesCategory,
  matchesSector,
  matchesFilter,
  isBiggestSavings,
};
