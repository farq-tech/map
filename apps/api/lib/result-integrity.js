'use strict';

/**
 * An empty answer is not automatically a correct answer.
 *
 * The failure this exists to prevent has a documented shape: a schema change
 * silently dropped a field an index depended on, category queries began
 * returning empty result sets — 200 OK, well-formed, zero rows — and because
 * nothing distinguishes "there is nothing" from "we lost the ability to find
 * anything", the outage ran for eleven days and twenty-two hours before a user
 * reported it. Time to fix, once someone looked: seven minutes.
 *
 * The lesson is not "monitor harder". It is that a system which cannot tell
 * those two states apart has no signal to monitor. So this module makes the
 * distinction explicit and forces the caller to act on it:
 *
 *   ok             rows came back
 *   filtered-zero  the source had rows; a filter the user chose removed them
 *   stale          rows came back, but from a read layer too old to trust
 *   source-empty   a city we serve produced no rows at all  ← a failure
 *
 * `source-empty` must never be served as success. A blank map returned with a
 * 200 tells the user there are no opportunities in Riyadh, which is a false
 * statement about the world, not a neutral absence of data.
 */

/**
 * How old the read layer may be before we say so out loud.
 *
 * Measured 21 Aug 2026: the layer rebuilds in full roughly every five days, the
 * delta path has never run, and `last_delta_at` is null. Seven days is set
 * above the observed cadence on purpose — it flags a rebuild that has actually
 * stopped, without crying wolf at a cadence that is merely slower than we want.
 * Tighten it when the pipeline spec's daily refresh lands.
 */
const STALE_AFTER_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Classify a result before it is allowed to become a response.
 *
 * `sourceCount` is how many rows the read layer produced for this city, before
 * any user filter. `count` is what survived. Passing the same number for both
 * is correct for an unfiltered request.
 */
function classifyResult({
	city,
	count,
	sourceCount,
	generatedAt,
	now = Date.now(),
	staleAfterMs = STALE_AFTER_MS,
} = {}) {
	const rows = Number(count) || 0;
	const source = sourceCount === undefined || sourceCount === null
		? rows
		: Number(sourceCount) || 0;

	const generated = generatedAt ? Date.parse(generatedAt) : NaN;
	const ageMs = Number.isFinite(generated) ? now - generated : null;
	const stale = ageMs !== null && ageMs > staleAfterMs;

	if (source === 0) {
		return {
			status: 'source-empty',
			severity: 'failed',
			city,
			count: rows,
			sourceCount: source,
			ageMs,
			/* Said in the words an on-call person needs, not in the words the code uses. */
			detail: `read layer produced no rows for ${city} — this is a pipeline failure, not an empty city`,
		};
	}
	if (rows === 0) {
		return {
			status: 'filtered-zero',
			severity: 'ok',
			city,
			count: rows,
			sourceCount: source,
			ageMs,
			detail: `${source} rows in the source, none survived the request's filters`,
		};
	}
	if (stale) {
		return {
			status: 'stale',
			severity: 'degraded',
			city,
			count: rows,
			sourceCount: source,
			ageMs,
			detail: `read layer is ${Math.round(ageMs / 86400000)} days old`,
		};
	}
	return { status: 'ok', severity: 'ok', city, count: rows, sourceCount: source, ageMs };
}

/**
 * A counter per status, so a synthetic check or a scrape can see the condition
 * without reading logs. Process-local and deliberately tiny: the point is that
 * something outside the process can observe the distinction, not that we build
 * a metrics system.
 */
const counters = new Map();
let lastFailure = null;

function record(result) {
	counters.set(result.status, (counters.get(result.status) || 0) + 1);
	if (result.severity === 'failed') {
		lastFailure = { ...result, at: new Date().toISOString() };
		/* Error, not warning. A warning nobody reads is the same as silence, and
		 * silence is what let the eleven-day outage run. */
		console.error('[integrity] %s city=%s count=%d source=%d — %s',
			result.status, result.city, result.count, result.sourceCount, result.detail);
	} else if (result.severity === 'degraded') {
		console.warn('[integrity] %s city=%s — %s', result.status, result.city, result.detail);
	}
	return result;
}

/** Everything an external check needs to decide whether this process is lying. */
function snapshot() {
	return {
		counts: Object.fromEntries(counters),
		last_failure: lastFailure,
		stale_after_days: STALE_AFTER_MS / 86400000,
	};
}

/** Test seam. Never called by the server. */
function reset() {
	counters.clear();
	lastFailure = null;
}

module.exports = {
	classifyResult,
	record,
	snapshot,
	reset,
	STALE_AFTER_MS,
};
