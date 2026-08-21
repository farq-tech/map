'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveDestination, canNavigate, metersBetween } = require('./place-navigation');

const RIYADH = { placeLat: 24.7, placeLng: 46.6 };

test('the destination is the branch the price came from', async (t) => {
	await t.test("the cheapest app's own coordinate wins, always", () => {
		const d = resolveDestination({
			...RIYADH, providerLat: 24.71, providerLng: 46.61,
			provider: 'jahez', branchSpreadMeters: 20, providerCount: 3,
		});
		assert.equal(d.source, 'branch');
		assert.equal(d.lat, 24.71);
		assert.equal(d.provider, 'jahez');
		assert.equal(d.confidence, 'exact-branch');
	});

	await t.test('it wins even when it disagrees with the pin by kilometres', () => {
		/* Measured: 591 Riyadh opportunities have their cheapest branch more than a
		 * kilometre from the pin, the worst by 28.7 km. The pin is where we draw;
		 * the branch is where the price is. */
		const d = resolveDestination({
			...RIYADH, providerLat: 24.95, providerLng: 46.6,
			provider: 'jahez', branchSpreadMeters: 28000, providerCount: 4,
		});
		assert.equal(d.source, 'branch');
		assert.ok(d.disagreementMeters > 20000,
			'the disagreement is reported, not hidden');
	});

	await t.test('the disagreement is measured against the pin, and is zero when they agree', () => {
		const d = resolveDestination({
			...RIYADH, providerLat: 24.7, providerLng: 46.6,
			provider: 'ninja', branchSpreadMeters: 5, providerCount: 2,
		});
		assert.equal(d.disagreementMeters, 0);
	});
});

test('when there is no branch coordinate, what we do depends on what the place is', async (t) => {
	await t.test('one address, no branch pin — the place pin is honest enough', () => {
		const d = resolveDestination({
			...RIYADH, providerLat: null, providerLng: null,
			branchSpreadMeters: 10, providerCount: 3,
		});
		assert.equal(d.source, 'place');
		assert.equal(d.confidence, 'place-pin');
		assert.equal(canNavigate(d), true);
	});

	await t.test('a merged chain, no branch pin — we refuse rather than guess', () => {
		/* The pin describes one branch out of several and we have no way to know it
		 * is the right one. Sending someone confidently to the wrong branch is the
		 * only outcome worse than saying we do not know. */
		const d = resolveDestination({
			...RIYADH, providerLat: null, providerLng: null,
			branchSpreadMeters: 28000, providerCount: 4,
		});
		assert.equal(d.lat, null);
		assert.equal(d.confidence, 'ambiguous-branch');
		assert.equal(canNavigate(d), false);
		assert.match(d.reason, /several branches/);
	});

	await t.test('a suspect merge is treated the same way as a certain one', () => {
		const d = resolveDestination({
			...RIYADH, providerLat: null, providerLng: null,
			branchSpreadMeters: 800, providerCount: 3,
		});
		assert.equal(canNavigate(d), false);
	});

	await t.test('a place that spans a block is offered, but marked approximate', () => {
		const d = resolveDestination({
			...RIYADH, providerLat: null, providerLng: null,
			branchSpreadMeters: 120, providerCount: 3,
		});
		assert.equal(d.source, 'place');
		assert.equal(d.confidence, 'place-pin-approximate');
	});
});

test('missing coordinates are missing, never (0, 0)', async (t) => {
	await t.test('no coordinate anywhere means no destination', () => {
		const d = resolveDestination({
			placeLat: null, placeLng: null, providerLat: null, providerLng: null,
		});
		assert.equal(d.lat, null);
		assert.equal(d.confidence, 'unknown');
		assert.equal(canNavigate(d), false);
	});

	await t.test('an empty string is not the equator', () => {
		const d = resolveDestination({
			placeLat: '', placeLng: '', providerLat: '', providerLng: '',
		});
		assert.equal(d.lat, null);
	});

	await t.test('a half-supplied branch coordinate falls back rather than inventing one', () => {
		const d = resolveDestination({
			...RIYADH, providerLat: 24.71, providerLng: null,
			branchSpreadMeters: 10, providerCount: 2,
		});
		assert.equal(d.source, 'place');
	});
});

test('distance', async (t) => {
	await t.test('is null when either side is unobserved', () => {
		assert.equal(metersBetween(24.7, null, 24.7, 46.6), null);
	});

	await t.test('is metres, and a degree of longitude here is shorter than one of latitude', () => {
		const northSouth = metersBetween(24.7, 46.6, 24.71, 46.6);
		const eastWest = metersBetween(24.7, 46.6, 24.7, 46.61);
		assert.ok(northSouth > eastWest,
			'0.01° of latitude must be longer on the ground than 0.01° of longitude at 24.7°N');
	});
});
