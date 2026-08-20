'use strict';

/**
 * One aggregation for every "area" the map paints — H3 cells today, districts
 * (أحياء) as well — so a count, a biggest gap and a cheapest-app verdict mean
 * exactly the same thing whichever geography carries them.
 *
 * A verdict is only offered from MIN_AREA_COMPARISONS compared items up; below
 * that the wins are still returned, but `cheapest_app` stays null so a handful
 * of rows never names a winner.
 */

/** Approved minimum (2026-08-20): name a cheapest app only from 8 comparisons up. */
const MIN_AREA_COMPARISONS = 8;

function emptyStats() {
  return { places: 0, opportunities: 0, max_gap: 0, top_place_id: null, comparisons: 0, wins: {} };
}

/**
 * Group features by `keyOf(feature)` (a string, or null to skip the feature)
 * and fold them into per-key stats.
 * @returns {Map<string, ReturnType<typeof emptyStats>>}
 */
function aggregateByKey(features, keyOf) {
  const groups = new Map();
  for (const f of features) {
    const key = keyOf(f);
    if (key == null || key === '') continue;
    const p = f.properties || {};
    let c = groups.get(key);
    if (!c) {
      c = emptyStats();
      groups.set(key, c);
    }
    c.places += 1;
    if (p.has_difference) {
      c.opportunities += 1;
      if (p.gap > c.max_gap) {
        c.max_gap = p.gap;
        c.top_place_id = p.place_id;
      }
    }
    if (p.wins) {
      for (const [provider, n] of Object.entries(p.wins)) {
        const k = String(provider);
        c.wins[k] = (c.wins[k] || 0) + Number(n || 0);
        c.comparisons += Number(n || 0);
      }
    }
  }
  return groups;
}

/**
 * How far ahead the leading app is, in points of share. Below this the area
 * has a leader but not a verdict: measured on Riyadh (2026-08-20) the median
 * winning share is 44%, 22 of 133 districts are decided by under 5 points and
 * one — الجنادرية, jahez 27 to hungerstation 27 — is an exact tie. Painting
 * those the same as a 60/20 win would turn a plurality into a claim.
 */
const MIN_VERDICT_MARGIN_PCT = 5;

/** The properties every area feature carries, derived from its stats. */
function statsToProperties(c, minComparisons = MIN_AREA_COMPARISONS) {
  const ranked = Object.entries(c.wins)
    .filter(([, n]) => Number(n) > 0)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const [leader, leaderWins] = ranked[0] || [null, 0];
  const runnerUpWins = ranked[1] ? ranked[1][1] : 0;
  const share = c.comparisons > 0 ? leaderWins / c.comparisons : 0;
  const marginPct = c.comparisons > 0 ? ((leaderWins - runnerUpWins) / c.comparisons) * 100 : 0;
  const enough = c.comparisons >= minComparisons;
  /* A verdict needs both a big enough sample and a clear enough lead. */
  const decided = enough && Boolean(leader) && marginPct >= MIN_VERDICT_MARGIN_PCT;
  return {
    places: c.places,
    opportunities: c.opportunities,
    max_gap: c.opportunities ? c.max_gap : null,
    top_place_id: c.top_place_id,
    comparisons: c.comparisons,
    wins: c.wins,
    enough_for_app_verdict: decided,
    /* True when the sample is large enough but the race is too close to call —
     * a different thing from "we have no data", and shown differently. */
    app_verdict_too_close: enough && Boolean(leader) && !decided,
    cheapest_app: decided ? leader : null,
    cheapest_app_wins: decided ? leaderWins : null,
    cheapest_app_share: decided ? Math.round(share * 100) : null,
    cheapest_app_margin: decided ? Math.round(marginPct) : null,
    runner_up_app: decided && ranked[1] ? ranked[1][0] : null,
  };
}

module.exports = {
  MIN_AREA_COMPARISONS,
  MIN_VERDICT_MARGIN_PCT,
  aggregateByKey,
  emptyStats,
  statsToProperties,
};
