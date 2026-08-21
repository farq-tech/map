'use strict';

/**
 * Where do we actually send someone?
 *
 * Drawing a pin in the wrong place costs a glance. Sending a person there costs
 * their evening. So the destination for navigation is decided more carefully
 * than the coordinate we render, and it is not always the same coordinate.
 *
 * The reason is measured. A canonical restaurant holds one pin, but each
 * delivery app lists its own branch with its own coordinate, and upstream those
 * listings are sometimes matched at the level of the BRAND rather than the
 * BRANCH. Against production on 21 Aug 2026, over the 5,405 Riyadh
 * opportunities whose cheapest provider publishes a coordinate:
 *
 *   4,573  the cheapest branch is at the pin        (≤30 m)
 *     218  the same block                           (≤150 m)
 *      23  up to a kilometre away
 *     591  MORE THAN A KILOMETRE AWAY — worst 28.7 km
 *
 * Eleven percent of the destinations we would have handed out were wrong by
 * more than a kilometre, and one by twenty-eight. The offer being compared came
 * from a specific branch of a specific app; that branch is the destination.
 *
 * When we cannot identify it, we say so rather than guessing. A confident wrong
 * answer is the only outcome worse than admitting we do not know.
 */

const { placeConfidence } = require('./place-truth');

/** Beyond this the pin and the branch are not describing the same place. */
const DISAGREEMENT_METERS = 150;

function coord(value) {
	if (value === null || value === undefined || value === '') return NaN;
	const n = Number(value);
	return Number.isFinite(n) ? n : NaN;
}

function metersBetween(lat1, lng1, lat2, lng2) {
	const [a1, o1, a2, o2] = [coord(lat1), coord(lng1), coord(lat2), coord(lng2)];
	if ([a1, o1, a2, o2].some(Number.isNaN)) return null;
	const toRad = (d) => (d * Math.PI) / 180;
	const dLat = toRad(a2 - a1);
	const dLng = toRad(o2 - o1);
	const h = Math.sin(dLat / 2) ** 2
		+ Math.cos(toRad(a1)) * Math.cos(toRad(a2)) * Math.sin(dLng / 2) ** 2;
	return 2 * 6371000 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * Resolve a destination.
 *
 * `providerLat`/`providerLng` are the cheapest provider's own coordinate for
 * this restaurant — the branch whose price we are quoting. `placeLat`/`placeLng`
 * are the canonical pin we draw.
 *
 * Returns `{ lat, lng, source, confidence, disagreementMeters, reason }`, or a
 * null destination when we cannot honestly name one.
 *
 *   source `branch`  the cheapest app's own coordinate — what we want
 *   source `place`   the canonical pin, used only when it is safe to
 *   source `null`    we do not know which branch, and will not pretend
 */
function resolveDestination({
	placeLat, placeLng,
	providerLat, providerLng,
	provider = null,
	branchSpreadMeters = null,
	providerCount = null,
} = {}) {
	const confidence = placeConfidence({
		spreadMeters: branchSpreadMeters,
		providerCount,
	});

	const branch = [coord(providerLat), coord(providerLng)];
	const place = [coord(placeLat), coord(placeLng)];
	const haveBranch = !branch.some(Number.isNaN);
	const havePlace = !place.some(Number.isNaN);

	if (haveBranch) {
		/* The branch the offer came from. Always preferred: it is the address the
		 * price belongs to, and it is the only one that is right when a chain has
		 * been merged into a single canonical restaurant. */
		const disagreement = havePlace
			? Math.round(metersBetween(place[0], place[1], branch[0], branch[1]))
			: null;
		return {
			lat: branch[0],
			lng: branch[1],
			source: 'branch',
			provider,
			confidence: 'exact-branch',
			disagreementMeters: disagreement,
			reason: 'the branch the cheapest offer came from',
		};
	}

	if (!havePlace) {
		return {
			lat: null, lng: null, source: null, provider,
			confidence: 'unknown',
			disagreementMeters: null,
			reason: 'no coordinate anywhere for this place',
		};
	}

	/**
	 * No branch coordinate. The canonical pin is all we have, and whether that is
	 * good enough depends entirely on whether this place is one place. For a
	 * merged chain the pin describes one branch out of several and we have no way
	 * to know it is the right one, so navigation is withheld rather than offered
	 * with a shrug.
	 */
	if (confidence === 'multi-branch-merge' || confidence === 'suspect-merge') {
		return {
			lat: null, lng: null, source: null, provider,
			confidence: 'ambiguous-branch',
			disagreementMeters: null,
			reason: 'this listing covers several branches and we cannot tell which one holds this price',
		};
	}

	return {
		lat: place[0],
		lng: place[1],
		source: 'place',
		provider,
		confidence: confidence === 'single-address' ? 'place-pin' : 'place-pin-approximate',
		disagreementMeters: null,
		reason: 'the restaurant pin; this app did not publish its own coordinate',
	};
}

/** Can we offer navigation at all? */
function canNavigate(destination) {
	return Boolean(destination && destination.lat !== null && destination.lng !== null);
}

module.exports = {
	resolveDestination,
	canNavigate,
	metersBetween,
	DISAGREEMENT_METERS,
};
