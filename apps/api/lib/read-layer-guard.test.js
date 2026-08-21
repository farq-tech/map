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
	count: 5075,
	providers: ALL_PROVIDERS,
	districtsRepresented: 136,
	nullRates: Object.fromEntries(REQUIRED_FIELDS.map((f) => [f, 0])),
	...over,
});

const feature = (over = {}) => ({
	properties: {
		gap: 12, cheapest_price: 20, expensive_price: 32,
		cheapest_provider_id: 'jahez', name: 'مطعم', item_id: '1',
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

	await t.test('an empty snapshot reports every required field as fully missing', () => {
		const s = summarize([], { city: 'riyadh' });
		assert.equal(s.count, 0);
		assert.equal(s.nullRates.gap, 1);
	});
});

test('the guard refuses a rebuild rather than warning about it', async (t) => {
	await t.test('a normal rebuild is accepted', () => {
		const v = evaluateSnapshot(snap({ count: 5210, districtsRepresented: 140 }), snap(), { totalDistricts: 187 });
		assert.equal(v.accept, true);
		assert.deepEqual(v.violations, []);
	});

	await t.test('a collapse in row count is refused', () => {
		const v = evaluateSnapshot(snap({ count: 3000 }), snap(), { totalDistricts: 187 });
		assert.equal(v.accept, false);
		assert.ok(v.violations.some((x) => x.rule === 'count-collapsed'));
	});

	await t.test('normal movement below the ceiling is not refused', () => {
		/* The ceiling is a catastrophe line, not a drift line — rebuild-to-rebuild
		 * variance has not been observable with one snapshot, so the guard must not
		 * pretend to know it. */
		const justUnder = Math.ceil(5075 * (1 - MAX_COUNT_DROP) + 1);
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
