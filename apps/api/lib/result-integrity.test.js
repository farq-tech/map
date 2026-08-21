'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { classifyResult, record, snapshot, reset, STALE_AFTER_MS } = require('./result-integrity');

const NOW = Date.parse('2026-08-21T09:00:00Z');
const fresh = new Date(NOW - 60 * 60 * 1000).toISOString();

test('an empty result is classified, never assumed', async (t) => {
	await t.test('no rows at all from a city we serve is a failure, not an empty city', () => {
		const r = classifyResult({ city: 'riyadh', count: 0, sourceCount: 0, generatedAt: fresh, now: NOW });
		assert.equal(r.status, 'source-empty');
		assert.equal(r.severity, 'failed');
	});

	await t.test("a filter that removes everything is the user's doing, and fine", () => {
		const r = classifyResult({ city: 'riyadh', count: 0, sourceCount: 5075, generatedAt: fresh, now: NOW });
		assert.equal(r.status, 'filtered-zero');
		assert.equal(r.severity, 'ok');
	});

	await t.test('rows from a layer past the staleness ceiling are degraded, not ok', () => {
		const old = new Date(NOW - STALE_AFTER_MS - 1000).toISOString();
		const r = classifyResult({ city: 'riyadh', count: 5075, sourceCount: 5075, generatedAt: old, now: NOW });
		assert.equal(r.status, 'stale');
		assert.equal(r.severity, 'degraded');
	});

	await t.test('the current five-day rebuild cadence is not flagged as broken', () => {
		/* Measured: the layer rebuilds roughly every five days today. The ceiling
		 * exists to catch a pipeline that stopped, not one that is merely slow. */
		const fiveDays = new Date(NOW - 5 * 86400000).toISOString();
		assert.equal(classifyResult({ city: 'riyadh', count: 8590, sourceCount: 8590, generatedAt: fiveDays, now: NOW }).status, 'ok');
	});

	await t.test('an unknown generation time is not treated as fresh or as stale', () => {
		const r = classifyResult({ city: 'riyadh', count: 10, sourceCount: 10, generatedAt: null, now: NOW });
		assert.equal(r.status, 'ok');
		assert.equal(r.ageMs, null);
	});

	await t.test('an absent sourceCount means the request was unfiltered', () => {
		assert.equal(classifyResult({ city: 'riyadh', count: 0, generatedAt: fresh, now: NOW }).status, 'source-empty');
		assert.equal(classifyResult({ city: 'riyadh', count: 7, generatedAt: fresh, now: NOW }).status, 'ok');
	});
});

test('the condition is observable from outside the process', async (t) => {
	await t.test('a failure is counted and kept, so a check can see it without reading logs', () => {
		reset();
		record(classifyResult({ city: 'riyadh', count: 0, sourceCount: 0, generatedAt: fresh, now: NOW }));
		record(classifyResult({ city: 'jeddah', count: 6, sourceCount: 6, generatedAt: fresh, now: NOW }));
		const s = snapshot();
		assert.equal(s.counts['source-empty'], 1);
		assert.equal(s.counts.ok, 1);
		assert.equal(s.last_failure.city, 'riyadh');
		reset();
	});
});
