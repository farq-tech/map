'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
	summarize,
	evaluateSnapshot,
	REQUIRED_FIELDS,
	MAX_COUNT_DROP,
	MIN_PROVIDERS,
} = require('./read-layer-guard');

const ALL_PROVIDERS = ['brand_app', 'hungerstation', 'jahez', 'keeta', 'mrsool', 'ninja', 'thechefz', 'toyou'];

/** A snapshot shaped like the measured Riyadh baseline. */
const snap = (over = {}) => ({
	city: 'riyadh',
	generatedAt: '2026-08-16T06:40:22.854Z',
	count: 8706,
	gappedCount: 5075,
	gappedShare: 5075 / 8706,
	providers: ALL_PROVIDERS,
	districtsRepresented: 136,
	nullRates: Object.fromEntries(REQUIRED_FIELDS.map((f) => [f, 0])),
	...over,
});

const feature = (over = {}) => ({
	properties: {
		has_difference: true,
		gap: 12, cheapest_price: 20, expensive_price: 32,
		cheapest_provider_id: 'jahez', name: 'مطعم', place_id: '1', item_id: '1',
		district_id: 'riyadh-al-olaya', ...over,
	},
});

test('summarize produces a comparable fingerprint', async (t) => {
	await t.test('counts rows, providers and districts actually present', () => {
		const s = summarize([
			feature(),
			feature({ cheapest_provider_id: 'mrsool', district_id: 'riyadh-al-malqa' }),
			feature({ district_id: null }),
		], { city: 'riyadh' });
		assert.equal(s.count, 3);
		assert.deepEqual(s.providers, ['jahez', 'mrsool']);
		assert.equal(s.districtsRepresented, 2);
	});

	await t.test('an empty required field is counted as missing, including empty string', () => {
		const s = summarize([feature({ name: '' }), feature()], { city: 'riyadh' });
		assert.equal(s.nullRates.name, 0.5);
	});

	await t.test('an empty snapshot is caught as empty, not as a hundred missing columns', () => {
		/* With no rows there is nothing to have a null rate ABOUT. Reporting 100%
		 * missing on every field would bury the one fact that matters — that the
		 * rebuild produced nothing — under six identical violations. */
		const s = summarize([], { city: 'riyadh' });
		assert.equal(s.count, 0);
		assert.equal(s.gappedCount, 0);
		assert.equal(s.nullRates.gap, 0);
		assert.equal(s.nullRates.name, 1, 'identity is still required, and there is none');
		const v = evaluateSnapshot(s, null);
		assert.equal(v.accept, false);
		assert.ok(v.violations.some((x) => x.rule === 'empty-snapshot'));
	});
});

test('the guard refuses a rebuild rather than warning about it', async (t) => {
	await t.test('a normal rebuild is accepted', () => {
		const v = evaluateSnapshot(snap({ count: 8800, gappedCount: 5200, districtsRepresented: 140 }), snap(), { totalDistricts: 187 });
		assert.equal(v.accept, true);
		assert.deepEqual(v.violations, []);
	});

	await t.test('a collapse in row count is refused', () => {
		const v = evaluateSnapshot(snap({ count: 4000 }), snap(), { totalDistricts: 187 });
		assert.equal(v.accept, false);
		assert.ok(v.violations.some((x) => x.rule === 'count-collapsed'));
	});

	await t.test('normal movement below the ceiling is not refused', () => {
		/* The ceiling is a catastrophe line, not a drift line — rebuild-to-rebuild
		 * variance has not been observable with one snapshot, so the guard must not
		 * pretend to know it. */
		const justUnder = Math.ceil(8706 * (1 - MAX_COUNT_DROP) + 1);
		assert.equal(evaluateSnapshot(snap({ count: justUnder }), snap(), { totalDistricts: 187 }).accept, true);
	});

	await t.test('a required column that stopped being produced is refused', () => {
		const broken = snap({ nullRates: { ...snap().nullRates, cheapest_price: 0.9 } });
		const v = evaluateSnapshot(broken, snap(), { totalDistricts: 187 });
		assert.equal(v.accept, false);
		assert.ok(v.violations.some((x) => x.rule === 'required-field-missing'));
	});

	await t.test('losing most providers is refused twice over — by floor and by comparison', () => {
		const v = evaluateSnapshot(snap({ providers: ['jahez', 'hungerstation'] }), snap(), { totalDistricts: 187 });
		assert.equal(v.accept, false);
		const rules = v.violations.map((x) => x.rule);
		assert.ok(rules.includes('providers-disappeared'));
		assert.ok(rules.includes('providers-lost'));
	});

	await t.test('a collapse in district coverage means the geometry pass broke', () => {
		const v = evaluateSnapshot(snap({ districtsRepresented: 40 }), snap(), { totalDistricts: 187 });
		assert.equal(v.accept, false);
		assert.ok(v.violations.some((x) => x.rule === 'district-coverage-collapsed'));
	});

	await t.test('an empty rebuild is refused on its own, with nothing to compare against', () => {
		const v = evaluateSnapshot(summarize([], { city: 'riyadh' }), null, { totalDistricts: 187 });
		assert.equal(v.accept, false);
		assert.ok(v.violations.some((x) => x.rule === 'empty-snapshot'));
	});

	await t.test('the first snapshot of a process is accepted when it is sound', () => {
		assert.equal(evaluateSnapshot(snap(), null, { totalDistricts: 187 }).accept, true);
	});

	await t.test('district coverage is only judged when we know how many districts exist', () => {
		assert.equal(evaluateSnapshot(snap({ districtsRepresented: 1 }), snap()).accept, true);
	});

	await t.test('the provider floor is stated, not implied', () => {
		assert.equal(MIN_PROVIDERS, 5);
	});
});

test('a field is only required where it is actually promised', async (t) => {
	await t.test('a place with no observed price difference is not a missing column', () => {
		/* The first version of this guard checked every field on every feature and
		 * refused a perfectly good snapshot, because 3,631 of Riyadh's 8,706 places
		 * legitimately carry no gap, no prices and no item. The synthetic check
		 * caught it on its first structured run. */
		const withGap = feature();
		const withoutGap = {
			properties: {
				has_difference: false,
				gap: null, cheapest_price: null, expensive_price: null,
				cheapest_provider_id: null, item_id: null,
				name: 'مطعم بلا فرق', place_id: '2', district_id: 'riyadh-al-olaya',
			},
		};
		const s = summarize([withGap, withoutGap], { city: 'riyadh' });
		assert.equal(s.count, 2);
		assert.equal(s.gappedCount, 1);
		assert.equal(s.nullRates.gap, 0, 'gap is judged only where a gap is claimed');
		assert.equal(s.nullRates.name, 0, 'identity is required everywhere');
		/* A two-row fixture cannot satisfy the eight-provider floor; this test is
		 * about which fields are judged where, so that rule is relaxed for it. */
		assert.equal(evaluateSnapshot(s, null, { minProviders: 1 }).accept, true);
	});

	await t.test('a row that claims a gap and has no price IS a missing column', () => {
		const broken = feature({ cheapest_price: null });
		const s = summarize([broken, feature()], { city: 'riyadh' });
		assert.equal(s.nullRates.cheapest_price, 0.5);
		assert.ok(evaluateSnapshot(s, null, { minProviders: 1 })
			.violations.some((v) => v.rule === 'required-field-missing'));
	});

	await t.test('places with no comparisons at all is its own failure', () => {
		const s = summarize([
			{ properties: { has_difference: false, name: 'a', place_id: '1' } },
			{ properties: { has_difference: false, name: 'b', place_id: '2' } },
		], { city: 'riyadh' });
		const v = evaluateSnapshot(s, null, { minProviders: 0 });
		assert.equal(v.accept, false);
		assert.ok(v.violations.some((x) => x.rule === 'no-comparisons'));
	});
});
