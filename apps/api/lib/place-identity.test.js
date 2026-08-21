'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
	nameSimilarity,
	haversineMeters,
	identityScore,
	confidenceOf,
	suspectedDuplicates,
	SAME_ADDRESS_METERS,
	SCORE_REVIEW,
} = require('./place-identity');

const at = (id, nameAr, lat = 24.7, lng = 46.6, extra = {}) =>
	({ id, nameAr, lat, lng, ...extra });

test('name similarity', async (t) => {
	await t.test('spelling variants of one name are the same name', () => {
		assert.equal(nameSimilarity('الروضة كافيه', 'الروضه كافية'), 1);
	});

	await t.test('two different names are not rescued by a shared venue word', () => {
		/* Edit distance has no idea that «مطعم» appears in thousands of rows, so
		 * without folding it these score ~0.8 and look like a near-match. */
		assert.ok(nameSimilarity('مطعم الشرق', 'مطعم الغرب') < 0.4);
	});

	await t.test('word order does not decide identity', () => {
		assert.ok(nameSimilarity('البيك مطعم', 'مطعم البيك') > 0.95);
	});

	await t.test('a missing name is missing, never dissimilar', () => {
		assert.equal(nameSimilarity('ستاربكس', null), null);
		assert.equal(nameSimilarity('', 'ستاربكس'), null);
	});
});

test('distance', async (t) => {
	await t.test('unobserved coordinates give null, never zero', () => {
		assert.equal(haversineMeters(null, 46.6, 24.7, 46.6), null);
		assert.equal(haversineMeters(24.7, 46.6, 24.7, ''), null);
	});

	await t.test('same point is zero metres', () => {
		assert.equal(Math.round(haversineMeters(24.7, 46.6, 24.7, 46.6)), 0);
	});
});

test('branch identity — distance is a gate, not a weight', async (t) => {
	await t.test('identical signs far apart are two branches, whatever the score says', () => {
		const scored = identityScore(at(1, 'ستاربكس'), at(2, 'ستاربكس', 24.71, 46.61));
		assert.equal(scored.score, 1);
		assert.equal(scored.colocated, false);
		assert.equal(confidenceOf(scored), 'different-branch');
	});

	await t.test('identical signs at one address are one branch', () => {
		const scored = identityScore(at(1, 'ستاربكس'), at(2, 'ستاربكس'));
		assert.equal(confidenceOf(scored), 'same');
	});

	await t.test('unknown distance is admitted as unknown, not guessed', () => {
		const scored = identityScore(
			{ id: 1, nameAr: 'ستاربكس', lat: null, lng: null },
			{ id: 2, nameAr: 'ستاربكس', lat: null, lng: null },
		);
		assert.equal(scored.colocated, null);
		assert.equal(confidenceOf(scored), 'same-brand-unknown-branch');
	});

	await t.test('a name made only of generic words carries no identity', () => {
		const scored = identityScore(at(1, 'مطعم'), at(2, 'مطعم'));
		assert.equal(scored.score, null);
		assert.equal(confidenceOf(scored), 'unknown');
	});

	await t.test('evidence is reported separately from score', () => {
		const thin = identityScore(at(1, 'البيك'), at(2, 'البيك'));
		const rich = identityScore(
			at(1, 'البيك', 24.7, 46.6, { nameEn: 'Al Baik', brandKey: 'albaik' }),
			at(2, 'البيك', 24.7, 46.6, { nameEn: 'Al Baik', brandKey: 'albaik' }),
		);
		assert.ok(rich.evidence > thin.evidence,
			'the same score on more signals must be a stronger claim');
	});
});

test('branch qualifiers do not make neighbours look related', async (t) => {
	await t.test('two chains sharing an address and a branch suffix stay distinct', () => {
		/* Measured on live data: this exact pattern produced 5 of 7 false
		 * positives in the first sweep, because the identical branch halves are
		 * long and the differing brand halves are short. */
		const a = at(1, 'ترندي كيك - Al Yarmuk');
		const b = at(2, 'تيستي كيك -  Al Yarmuk');
		assert.ok(identityScore(a, b).score < SCORE_REVIEW);
	});
});

test('suspectedDuplicates returns the weakest matches first', async (t) => {
	await t.test('ordering is ascending by score, because that is what a reviewer needs', () => {
		const places = [
			at(1, 'الروضة كافيه'), at(2, 'الروضه كافية'),
			at(3, 'تاكو لوكو', 24.70001, 46.60001), at(4, 'تاكو تاكو', 24.70001, 46.60001),
		];
		const pairs = suspectedDuplicates(places, { minScore: 0.7 });
		assert.ok(pairs.length >= 2);
		for (let i = 1; i < pairs.length; i += 1) {
			assert.ok(pairs[i].score >= pairs[i - 1].score,
				'a random sample measures the easy matches; the margin is what the threshold decides');
		}
	});

	await t.test('pairs beyond the address radius are never proposed', () => {
		const far = [at(1, 'ستاربكس'), at(2, 'ستاربكس', 24.72, 46.62)];
		assert.deepEqual(suspectedDuplicates(far), []);
	});

	await t.test('places without coordinates are skipped rather than assumed co-located', () => {
		const pairs = suspectedDuplicates([
			{ id: 1, nameAr: 'ستاربكس', lat: null, lng: null },
			{ id: 2, nameAr: 'ستاربكس', lat: null, lng: null },
		]);
		assert.deepEqual(pairs, []);
	});

	await t.test('the address radius is the coordinate accuracy floor, not a tunable guess', () => {
		assert.equal(SAME_ADDRESS_METERS, 30);
	});
});

test('the blocking grid respects that a longitude degree is not a latitude degree', async (t) => {
	await t.test('a pair inside the radius but east-west of each other is still found', () => {
		/* A degree of longitude at this latitude is ~0.908 of a degree of latitude.
		 * Treating them alike makes the east-west cell 9% narrow, and pairs either
		 * side of a cell edge disappear with no error anywhere. This pair sits at
		 * 28 m apart, purely east-west, straddling where that edge would fall. */
		const lat = 24.7;
		const metresPerLngDegree = 111320 * Math.cos((lat * Math.PI) / 180);
		const a = { id: 'a', nameAr: 'الروضة كافيه', lat, lng: 46.6 };
		const b = { id: 'b', nameAr: 'الروضه كافية', lat, lng: 46.6 + 28 / metresPerLngDegree };
		const meters = haversineMeters(a.lat, a.lng, b.lat, b.lng);
		assert.ok(meters > 27 && meters < 29, `expected ~28 m, got ${meters}`);
		assert.equal(suspectedDuplicates([a, b], { radius: 30 }).length, 1);
	});

	await t.test('a pair just outside the radius is still excluded', () => {
		const lat = 24.7;
		const metresPerLngDegree = 111320 * Math.cos((lat * Math.PI) / 180);
		const a = { id: 'a', nameAr: 'الروضة كافيه', lat, lng: 46.6 };
		const b = { id: 'b', nameAr: 'الروضه كافية', lat, lng: 46.6 + 45 / metresPerLngDegree };
		assert.deepEqual(suspectedDuplicates([a, b], { radius: 30 }), []);
	});
});
