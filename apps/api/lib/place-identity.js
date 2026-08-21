'use strict';

/**
 * Is this the same branch?
 *
 * Farq reads a comparison layer where restaurants have already been merged
 * across delivery apps upstream. We cannot re-merge them, and we should not
 * pretend to. What we can do — and must, because every number on the map hangs
 * off it — is decide how much to trust a claimed identity, and notice when the
 * data says two rows are different places while everything observable says they
 * are one.
 *
 * So this module answers three questions, in order of how much they matter:
 *   1. How similar are two place records, on evidence we can actually see?
 *   2. How confident should a claim of sameness be, given how thin that evidence is?
 *   3. Which pairs are worth a human's attention — WEAKEST FIRST?
 *
 * The third is the load-bearing one. Evaluating a matcher on a random sample
 * measures the easy matches the threshold never affected; the honest measurement
 * is of the weakest pairs the threshold still accepts. That discipline is built
 * into the shape of `suspectedDuplicates` rather than left to whoever calls it.
 */

const {
	normalizeArabic,
	matchKey,
	nameTokens,
	splitBranchQualifier,
} = require('./arabic-text');

/** Levenshtein distance, two rows of state rather than a full matrix. */
function levenshtein(a, b) {
	if (a === b) return 0;
	if (!a.length) return b.length;
	if (!b.length) return a.length;
	let prev = new Array(b.length + 1);
	let curr = new Array(b.length + 1);
	for (let j = 0; j <= b.length; j += 1) prev[j] = j;
	for (let i = 1; i <= a.length; i += 1) {
		curr[0] = i;
		const ca = a[i - 1];
		for (let j = 1; j <= b.length; j += 1) {
			const cost = ca === b[j - 1] ? 0 : 1;
			curr[j] = Math.min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
		}
		const swap = prev; prev = curr; curr = swap;
	}
	return prev[b.length];
}

/** Plain edit-distance similarity in [0,1]. */
function ratio(a, b) {
	if (!a && !b) return 1;
	if (!a || !b) return 0;
	const longest = Math.max(a.length, b.length);
	return 1 - levenshtein(a, b) / longest;
}

/**
 * Best alignment of the shorter string against any window of the longer one.
 * This is what catches «كوتد» inside «كوتد الرياض العليا» — a branch suffix
 * appended to a brand name, which is the single most common shape in this data.
 */
function partialRatio(a, b) {
	if (!a || !b) return a === b ? 1 : 0;
	const [short, long] = a.length <= b.length ? [a, b] : [b, a];
	if (short.length === long.length) return ratio(short, long);
	let best = 0;
	for (let i = 0; i + short.length <= long.length; i += 1) {
		best = Math.max(best, ratio(short, long.slice(i, i + short.length)));
		if (best === 1) break;
	}
	return best;
}

/** Order-insensitive comparison — «مطعم البيك» vs «البيك مطعم». */
function tokenSortRatio(a, b) {
	const sa = a.split(' ').filter(Boolean).sort().join(' ');
	const sb = b.split(' ').filter(Boolean).sort().join(' ');
	return ratio(sa, sb);
}

/**
 * The three views of a name, weighted. Straight edit distance is the strictest
 * and gets the most weight; containment catches branch suffixes; order-free
 * comparison catches word reordering, which is rife in Arabic business names
 * where the type word can lead or trail.
 */
const NAME_WEIGHTS = { ratio: 0.4, partial: 0.2, tokenSort: 0.4 };

function nameSimilarity(a, b) {
	const na = matchKey(a);
	const nb = matchKey(b);
	if (!na || !nb) return null; /* Missing, not dissimilar. Never score 0 for absent. */
	if (na === nb) return 1;
	return (
		NAME_WEIGHTS.ratio * ratio(na, nb) +
		NAME_WEIGHTS.partial * partialRatio(na, nb) +
		NAME_WEIGHTS.tokenSort * tokenSortRatio(na, nb)
	);
}

/**
 * A coordinate, or NaN. `Number(null)` is 0, which is a real place off the coast
 * of Ghana, so every unobserved value must be turned into NaN explicitly before
 * it is allowed anywhere near a distance calculation.
 */
function coord(value) {
	if (value === null || value === undefined || value === '') return NaN;
	const n = Number(value);
	return Number.isFinite(n) ? n : NaN;
}

/** Metres between two observed pins. Null if either side is unobserved. */
function haversineMeters(lat1, lng1, lat2, lng2) {
	const [a1, o1, a2, o2] = [coord(lat1), coord(lng1), coord(lat2), coord(lng2)];
	if (![a1, o1, a2, o2].every(Number.isFinite)) return null;
	const toRad = (d) => (d * Math.PI) / 180;
	const dLat = toRad(a2 - a1);
	const dLng = toRad(o2 - o1);
	const h =
		Math.sin(dLat / 2) ** 2 +
		Math.cos(toRad(a1)) * Math.cos(toRad(a2)) * Math.sin(dLng / 2) ** 2;
	return 2 * 6371000 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * Two places closer than this are, for our purposes, at the same address: a
 * mall unit, a food court stall, a drive-through beside its dining room. It is
 * also roughly the accuracy floor of the coordinates we are given, so a smaller
 * number would be measuring noise.
 */
const SAME_ADDRESS_METERS = 30;

/** Proximity as a score: 1 at zero metres, decaying linearly to 0 at the radius. */
function proximityScore(meters, radius = SAME_ADDRESS_METERS) {
	if (meters === null) return null;
	if (meters >= radius) return 0;
	return 1 - meters / radius;
}

/**
 * Signal weights — for the BRAND question only.
 *
 * Location is deliberately absent here. In this data every provider row for a
 * canonical restaurant carries the SAME coordinate: measured across 32,128
 * provider pairs, the worst separation was 0 metres. Coordinates are propagated,
 * not independently observed, so weighting them would be weighting a copy of the
 * thing under test. Location does its real work below, as a gate.
 */
const SIGNAL_WEIGHTS = { nameAr: 0.5, nameEn: 0.35, brand: 0.15 };

/**
 * How alike are these two names — is this the same BRAND?
 *
 * Says nothing about whether it is the same branch. Two branches of one chain
 * score 1.0 here and are different places.
 */
function brandScore(a, b) {
	const parts = {};
	let weighted = 0;
	let weight = 0;
	const add = (key, value, w) => {
		if (value === null || value === undefined) return;
		parts[key] = value;
		weighted += value * w;
		weight += w;
	};

	/* Compare chain to chain. The branch qualifier is answered by coordinates,
	 * not by string similarity, and leaving it in makes every pair of brands at
	 * one address look related. */
	add('nameAr', nameSimilarity(
		splitBranchQualifier(a.nameAr).brand,
		splitBranchQualifier(b.nameAr).brand,
	), SIGNAL_WEIGHTS.nameAr);
	add('nameEn', nameSimilarity(
		splitBranchQualifier(a.nameEn).brand,
		splitBranchQualifier(b.nameEn).brand,
	), SIGNAL_WEIGHTS.nameEn);
	if (a.brandKey && b.brandKey) {
		add('brand', normalizeArabic(a.brandKey) === normalizeArabic(b.brandKey) ? 1 : 0,
			SIGNAL_WEIGHTS.brand);
	}

	const total = SIGNAL_WEIGHTS.nameAr + SIGNAL_WEIGHTS.nameEn + SIGNAL_WEIGHTS.brand;
	return {
		score: weight > 0 ? weighted / weight : null,
		/* How much of the possible evidence we actually had. 0.9 on one signal is
		 * not the same claim as 0.9 on three, and a caller must be able to tell. */
		evidence: weight / total,
		parts,
	};
}

/**
 * Is this the same BRANCH?
 *
 * Distance is a gate, not a weight. Averaging a hard geometric fact into a soft
 * score is how two branches of a chain 1.4 km apart end up scoring 0.75 and
 * looking like a near-match: the name carries the score and the distance only
 * dents it. A branch is a place you can order from. Two places 1.4 km apart are
 * two places no matter how identical their signs are.
 *
 * Unknown distance is not the same as far. It downgrades confidence rather than
 * deciding the answer, because we would rather say "cannot tell" than guess.
 */
function identityScore(a, b, { radius = SAME_ADDRESS_METERS } = {}) {
	const brand = brandScore(a, b);
	const meters = haversineMeters(a.lat, a.lng, b.lat, b.lng);
	return {
		score: brand.score,
		evidence: brand.evidence,
		parts: brand.parts,
		meters,
		colocated: meters === null ? null : meters <= radius,
	};
}

/**
 * Thresholds.
 *
 * `REVIEW` is where a pair becomes worth a human's time. `SAME` is where we
 * would act on sameness without one. The gap between them is deliberate and
 * wide: a false merge shows the wrong price for the wrong dish and is
 * unrecoverable from the user's side, while a false split shows a duplicate,
 * which is merely untidy. When in doubt, split.
 */
const SCORE_REVIEW = 0.72;
const SCORE_SAME = 0.9;
/** Below this share of possible evidence, no score is strong enough to act on. */
const MIN_EVIDENCE = 0.5;

function confidenceOf({ score, evidence, colocated }) {
	if (score === null) return 'unknown';
	/* Far apart is a decision, not a doubt: whatever the signs say, these are two
	 * different places you would place two different orders from. */
	if (colocated === false) return 'different-branch';
	if (evidence < MIN_EVIDENCE) return 'insufficient-evidence';
	if (colocated === null) {
		/* Same name, unknown location. The most we can honestly claim is the brand. */
		return score >= SCORE_SAME ? 'same-brand-unknown-branch' : 'different';
	}
	if (score >= SCORE_SAME) return 'same';
	if (score >= SCORE_REVIEW) return 'review';
	return 'different';
}

/**
 * Find pairs that the data calls distinct but the evidence calls the same.
 *
 * Returns them **weakest first**. That ordering is the point: the honest way to
 * measure a threshold is to look at the worst pairs it still accepts, not at a
 * random sample dominated by easy matches. Take the first N of this array and
 * you are looking at exactly the decisions the threshold is responsible for.
 *
 * Blocking is a coordinate grid, so this is linear in places and quadratic only
 * within a cell.
 */
function suspectedDuplicates(places, {
	radius = SAME_ADDRESS_METERS,
	minScore = SCORE_REVIEW,
	limit = Infinity,
} = {}) {
	/**
	 * Blocking grid.
	 *
	 * A degree of latitude is ~111.32 km everywhere; a degree of LONGITUDE is that
	 * times cos(latitude), which at Riyadh is 0.908 — so treating the two axes
	 * alike makes the east-west cell 9% narrower than intended and quietly drops
	 * pairs that sit either side of a cell edge. Degrees are not metres and the
	 * two axes are not the same unit.
	 *
	 * The latitude scale is taken once, from the middle of the data, because the
	 * cities we serve span far too little north-south for it to vary usefully —
	 * and a per-row cos() would make cell membership depend on the row rather
	 * than on the grid, which is worse than a small constant error.
	 */
	const latDegPerMeter = 1 / 111320;
	const lats = [];
	for (const place of places) {
		const v = coord(place.lat);
		if (!Number.isNaN(v)) lats.push(v);
	}
	if (!lats.length) return [];
	const midLat = lats.sort((x, y) => x - y)[Math.floor(lats.length / 2)];
	const cosLat = Math.max(0.05, Math.cos((midLat * Math.PI) / 180));
	const cellLat = radius * latDegPerMeter;
	const cellLng = cellLat / cosLat;

	const grid = new Map();
	const cellKey = (lat, lng) =>
		`${Math.floor(lat / cellLat)}:${Math.floor(lng / cellLng)}`;

	for (const place of places) {
		const lat = coord(place.lat);
		const lng = coord(place.lng);
		if (Number.isNaN(lat) || Number.isNaN(lng)) continue;
		const key = cellKey(lat, lng);
		if (!grid.has(key)) grid.set(key, []);
		grid.get(key).push(place);
	}

	const out = [];
	const seen = new Set();
	for (const place of places) {
		const lat = coord(place.lat);
		const lng = coord(place.lng);
		/* A place with no observed pin is not at (0, 0). It is nowhere, and it
		 * cannot be proposed as a duplicate of anything. */
		if (Number.isNaN(lat) || Number.isNaN(lng)) continue;
		const ci = Math.floor(lat / cellLat);
		const cj = Math.floor(lng / cellLng);
		for (let di = -1; di <= 1; di += 1) {
			for (let dj = -1; dj <= 1; dj += 1) {
				for (const other of grid.get(`${ci + di}:${cj + dj}`) || []) {
					if (other.id === place.id) continue;
					const pairKey = place.id < other.id
						? `${place.id}|${other.id}`
						: `${other.id}|${place.id}`;
					if (seen.has(pairKey)) continue;
					seen.add(pairKey);
					const scored = identityScore(place, other, { radius });
					if (scored.score === null || scored.score < minScore) continue;
					if (scored.meters !== null && scored.meters > radius) continue;
					out.push({ a: place, b: other, ...scored, confidence: confidenceOf(scored) });
				}
			}
		}
	}

	out.sort((x, y) => x.score - y.score || String(x.a.id).localeCompare(String(y.a.id)));
	return Number.isFinite(limit) ? out.slice(0, limit) : out;
}

module.exports = {
	coord,
	levenshtein,
	ratio,
	partialRatio,
	tokenSortRatio,
	nameSimilarity,
	haversineMeters,
	proximityScore,
	brandScore,
	identityScore,
	confidenceOf,
	suspectedDuplicates,
	nameTokens,
	SAME_ADDRESS_METERS,
	SCORE_REVIEW,
	SCORE_SAME,
	MIN_EVIDENCE,
	SIGNAL_WEIGHTS,
	NAME_WEIGHTS,
};
