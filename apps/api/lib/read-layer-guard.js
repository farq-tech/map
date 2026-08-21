'use strict';

/**
 * A guard on the moment Farq adopts a new read layer.
 *
 * The comparison layer is rebuilt upstream, outside this repository, and we do
 * not control it. What we do control is whether a freshly-fetched snapshot is
 * allowed to replace the one we are already serving. That is the point where a
 * bad rebuild reaches a user, and therefore the only place we can stop it.
 *
 * The guard refuses the new snapshot and keeps serving the last good one. It
 * does not warn and continue: a warning about a map that is now missing half its
 * restaurants is not a mitigation.
 *
 * ── An honest limit on the thresholds below ──────────────────────────────────
 * The layer rebuilds roughly every five days, and only one snapshot was
 * available when these were set (21 Aug 2026). That means rebuild-to-rebuild
 * variance has NOT been observed and cannot be, yet. So every threshold here is
 * deliberately set at the catastrophe level — the kind of movement that no
 * normal crawl produces — rather than at a drift level tuned to a distribution
 * nobody has measured. Once two consecutive rebuilds have been recorded through
 * `summarize`, tighten them to the observed spread and say so here.
 *
 * Baseline measured on the Riyadh snapshot generated 2026-08-16:
 *   5,075 features, all carrying a gap
 *   8 providers appear as the cheapest
 *   136 of 187 أحياء represented
 *   required fields at 0.0% null; expensive_provider_id at 22.7% by design
 *   tiers hero 248 / strong 1,021 / regular 2,091 / faint 1,715
 */

/**
 * Fields no card can be rendered honestly without — checked only on the features
 * that CLAIM a price difference.
 *
 * The distinction matters and this was mis-specified on the first attempt: the
 * check originally ran over every feature, and a place with no observed price
 * difference legitimately has no gap, no prices and no item. 3,631 of Riyadh's
 * 8,706 places are in that state by design, so the guard read a 42% null rate
 * and refused a perfectly good snapshot. That is data, not a missing column.
 * The synthetic check caught it on its first structured run.
 */
const REQUIRED_ON_GAPPED = [
	'gap',
	'cheapest_price',
	'expensive_price',
	'cheapest_provider_id',
	'item_id',
];

/** Fields every feature must carry, gap or no gap — this is the identity of the row. */
const REQUIRED_ON_ALL = ['name', 'place_id'];

/** Kept for callers that want the whole set. */
const REQUIRED_FIELDS = [...REQUIRED_ON_ALL, ...REQUIRED_ON_GAPPED];

/** A column that vanishes shows up as a null rate far above this. */
const MAX_REQUIRED_NULL_RATE = 0.02;

/**
 * Feature count. A crawl adds and removes restaurants continuously; it does not
 * remove a third of them. Anything past this is a truncated source, not a
 * quieter week.
 */
const MAX_COUNT_DROP = 0.3;

/** Eight providers appear today. Losing more than three at once is an outage. */
const MIN_PROVIDERS = 5;

/**
 * 136 of 187 أحياء carry opportunities. If coverage halves, either the
 * coordinates or the point-in-polygon pass broke — both of which render a map
 * that looks plausible and is wrong.
 */
const MIN_DISTRICT_COVERAGE_RATIO = 0.5;

function isMissing(value) {
	return value === null || value === undefined || value === '' ||
		(Array.isArray(value) && value.length === 0);
}

/**
 * A compact, comparable fingerprint of a snapshot. Small enough to keep in
 * memory between refreshes and to log verbatim when a rebuild is refused.
 */
function summarize(features, { city, generatedAt } = {}) {
	const list = Array.isArray(features) ? features : [];
	const props = list.map((f) => (f && f.properties) || {});
	const gapped = props.filter((p) => p.has_difference);

	const nullRates = {};
	for (const field of REQUIRED_ON_ALL) {
		const missing = props.filter((p) => isMissing(p[field])).length;
		nullRates[field] = list.length ? missing / list.length : 1;
	}
	for (const field of REQUIRED_ON_GAPPED) {
		const missing = gapped.filter((p) => isMissing(p[field])).length;
		/* No gapped rows at all is its own violation, caught by gappedShare below —
		 * not by pretending every field is missing. */
		nullRates[field] = gapped.length ? missing / gapped.length : 0;
	}

	const providers = new Set();
	const districts = new Set();
	for (const p of props) {
		if (p.cheapest_provider_id) providers.add(p.cheapest_provider_id);
		if (p.district_id) districts.add(p.district_id);
	}
	return {
		city: city || null,
		generatedAt: generatedAt || null,
		count: list.length,
		gappedCount: gapped.length,
		/* What fraction of places carry a price difference. Measured at 0.583 on
		 * the 16 Aug snapshot; a collapse here means the comparison stopped
		 * producing comparisons even though the rows are still there. */
		gappedShare: list.length ? gapped.length / list.length : 0,
		providers: [...providers].sort(),
		districtsRepresented: districts.size,
		nullRates,
	};
}

/**
 * Should this candidate snapshot be allowed to replace the one we are serving?
 *
 * With no previous snapshot the candidate is accepted — there is nothing to
 * compare against, and refusing would mean never starting. It is still checked
 * against the absolute rules, so a first snapshot with no providers is refused
 * on its own merits.
 */
function evaluateSnapshot(candidate, previous, {
	maxCountDrop = MAX_COUNT_DROP,
	minProviders = MIN_PROVIDERS,
	minDistrictCoverageRatio = MIN_DISTRICT_COVERAGE_RATIO,
	maxRequiredNullRate = MAX_REQUIRED_NULL_RATE,
	totalDistricts = null,
} = {}) {
	const violations = [];

	if (!candidate || candidate.count === 0) {
		violations.push({
			rule: 'empty-snapshot',
			detail: 'the rebuild produced no rows at all',
		});
	}

	for (const [field, rate] of Object.entries((candidate && candidate.nullRates) || {})) {
		if (rate > maxRequiredNullRate) {
			violations.push({
				rule: 'required-field-missing',
				detail: `${field} is null on ${(rate * 100).toFixed(1)}% of rows (ceiling ${(maxRequiredNullRate * 100).toFixed(0)}%)`,
			});
		}
	}

	if (candidate && candidate.count > 0 && candidate.gappedCount === 0) {
		violations.push({
			rule: 'no-comparisons',
			detail: `${candidate.count} places and not one price difference among them`,
		});
	}

	if (candidate && candidate.providers.length < minProviders) {
		violations.push({
			rule: 'providers-disappeared',
			detail: `only ${candidate.providers.length} providers appear as cheapest (floor ${minProviders}): ${candidate.providers.join(', ') || 'none'}`,
		});
	}

	if (candidate && Number.isFinite(totalDistricts) && totalDistricts > 0) {
		const ratio = candidate.districtsRepresented / totalDistricts;
		if (ratio < minDistrictCoverageRatio) {
			violations.push({
				rule: 'district-coverage-collapsed',
				detail: `${candidate.districtsRepresented} of ${totalDistricts} أحياء carry opportunities (floor ${(minDistrictCoverageRatio * 100).toFixed(0)}%)`,
			});
		}
	}

	if (previous && previous.count > 0 && candidate) {
		const drop = (previous.count - candidate.count) / previous.count;
		if (drop > maxCountDrop) {
			violations.push({
				rule: 'count-collapsed',
				detail: `${candidate.count} rows against ${previous.count} previously, a ${(drop * 100).toFixed(0)}% drop (ceiling ${(maxCountDrop * 100).toFixed(0)}%)`,
			});
		}
		/* A provider that was there and is now entirely gone is worth naming even
		 * when the floor above is still satisfied. */
		const lost = previous.providers.filter((p) => !candidate.providers.includes(p));
		if (lost.length >= 3) {
			violations.push({
				rule: 'providers-lost',
				detail: `providers present last time and absent now: ${lost.join(', ')}`,
			});
		}
	}

	return {
		accept: violations.length === 0,
		violations,
		candidate,
		previous: previous || null,
	};
}

module.exports = {
	summarize,
	REQUIRED_ON_ALL,
	REQUIRED_ON_GAPPED,
	evaluateSnapshot,
	REQUIRED_FIELDS,
	MAX_REQUIRED_NULL_RATE,
	MAX_COUNT_DROP,
	MIN_PROVIDERS,
	MIN_DISTRICT_COVERAGE_RATIO,
};
