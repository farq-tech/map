'use strict';

/**
 * How much of a place is one place?
 *
 * Farq draws one pin per canonical restaurant and attributes it to one حي. Both
 * of those are claims about identity, and upstream the identity is built by
 * matching each delivery app's listing to a shared canonical id. When that match
 * is made at the level of the BRAND rather than the BRANCH, one canonical ends
 * up holding listings from branches that are kilometres apart — and Farq then
 * draws a chain as a single restaurant standing in a single حي.
 *
 * Measured on production, 21 Aug 2026, over the restaurants Farq actually shows
 * in Riyadh:
 *
 *   ≤30 m apart   6,684 restaurants   277,912 items    one address
 *   ≤150 m        1,390                69,576          same block
 *   ≤1 km           130                 7,033          suspect
 *   >1 km           386                31,974          a chain, not a branch
 *
 * So 4.5% of the places on the map, carrying 8.4% of the comparable items, are
 * brand-level merges. The worst spans 73 km. This module names that condition so
 * the rest of the system can refuse to make claims that depend on it.
 *
 * It does not "fix" the merge. Farq is a read-only client of the comparison
 * layer and must not invent an identity the source did not assert. What it can
 * do — and what the map's existing rule already demands — is decline to place a
 * thing whose location is not a single location.
 */

/** Two pins this close are one address: a mall unit, a kitchen and its counter. */
const SPREAD_SAME_ADDRESS_M = 30;
/** Still one place, allowing for how loosely each app drops its pin. */
const SPREAD_SAME_BLOCK_M = 150;
/** Beyond this a single حي cannot contain it, whatever the source says. */
const SPREAD_SUSPECT_M = 1000;

/**
 * What kind of claim can this place support?
 *
 *   single-provider     only one app lists it — nothing to disagree, nothing proven
 *   single-address      every app agrees within a building
 *   same-block          apps disagree by a street width
 *   suspect-merge       apps disagree by more than a neighbourhood block
 *   multi-branch-merge  apps are describing different branches of a chain
 *   unknown             no app supplied a coordinate we could compare
 */
function placeConfidence({ spreadMeters, providerCount } = {}) {
	const providers = Number(providerCount);
	if (Number.isFinite(providers) && providers <= 1) return 'single-provider';
	if (spreadMeters === null || spreadMeters === undefined || spreadMeters === '') {
		return 'unknown';
	}
	const spread = Number(spreadMeters);
	if (!Number.isFinite(spread)) return 'unknown';
	if (spread <= SPREAD_SAME_ADDRESS_M) return 'single-address';
	if (spread <= SPREAD_SAME_BLOCK_M) return 'same-block';
	if (spread <= SPREAD_SUSPECT_M) return 'suspect-merge';
	return 'multi-branch-merge';
}

/**
 * May this place be counted inside a حي?
 *
 * The map already refuses to place an opportunity whose coordinates fall in no
 * polygon, on the rule that a wrong حي is worse than an uncounted one. A place
 * whose own branches are kilometres apart is the same failure wearing a
 * coordinate: it HAS a pin, and the pin describes one branch out of several.
 * Counting it attributes a chain's prices to whichever branch happened to supply
 * the coordinate.
 *
 * `unknown` is allowed through deliberately. Almost every place is `unknown`
 * until the coordinates exist to say otherwise, and treating absence of evidence
 * as evidence of a bad merge would empty the map.
 */
function attributableToDistrict(confidence) {
	return confidence !== 'multi-branch-merge';
}

/** A place we would not stake a district-level verdict on. */
function isMerged(confidence) {
	return confidence === 'multi-branch-merge' || confidence === 'suspect-merge';
}

module.exports = {
	placeConfidence,
	attributableToDistrict,
	isMerged,
	SPREAD_SAME_ADDRESS_M,
	SPREAD_SAME_BLOCK_M,
	SPREAD_SUSPECT_M,
};
