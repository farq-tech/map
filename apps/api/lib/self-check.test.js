'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { record, snapshot, stop, start } = require('./self-check');
const integrity = require('./result-integrity');

test('a failing self-check is recorded where something is watching', async (t) => {
	await t.test('a data failure reaches the integrity channel, so /api/health turns 503', () => {
		integrity.reset();
		record({
			exitCode: 1,
			result: {
				passed: 8, failed: 2,
				failures: [{ check: 'riyadh is not empty', expected: '>= 2000 features', actual: '0 features', endpoint: '/x' }],
			},
		});
		const s = integrity.snapshot();
		assert.equal(s.counts['self-check-data-failure'], 1);
		assert.match(s.last_failure.detail, /riyadh is not empty/);
		assert.match(s.last_failure.detail, /expected >= 2000 features, got 0 features/);
		integrity.reset();
	});

	await t.test('unreachable is recorded as a different status than wrong data', () => {
		integrity.reset();
		record({ exitCode: 2, result: { passed: 0, failed: 1, failures: [] } });
		assert.equal(integrity.snapshot().counts['self-check-unreachable'], 1);
		integrity.reset();
	});

	await t.test('a healthy run records a success and raises no failure', () => {
		integrity.reset();
		record({ exitCode: 0, result: { passed: 10, failed: 0, failures: [] } });
		assert.equal(integrity.snapshot().last_failure, null);
		assert.ok(snapshot().last_success_at);
		integrity.reset();
	});

	await t.test('an unreadable check result is a failure, not a pass', () => {
		integrity.reset();
		record({ exitCode: 1, result: null });
		const s = integrity.snapshot();
		assert.equal(s.counts['self-check-data-failure'], 1);
		assert.match(s.last_failure.detail, /unreadable/);
		integrity.reset();
	});
});

test('the snapshot tells an operator what it can and cannot see', async (t) => {
	await t.test('history is kept, newest first, and bounded', () => {
		for (let i = 0; i < 60; i += 1) {
			record({ exitCode: 0, result: { passed: 10, failed: 0, failures: [] } });
		}
		const s = snapshot();
		assert.ok(s.recent.length <= 8);
		assert.ok(new Date(s.recent[0].at) >= new Date(s.recent[s.recent.length - 1].at));
		integrity.reset();
	});

	await t.test('the blind spot is stated rather than left for someone to discover', () => {
		assert.match(snapshot().blind_spot, /cannot report a total outage/);
	});
});

test('it stays off unless switched on', async (t) => {
	await t.test('no env flag means no timer', () => {
		const before = process.env.SELF_CHECK_ENABLED;
		delete process.env.SELF_CHECK_ENABLED;
		assert.equal(start({ baseUrl: 'http://127.0.0.1:1' }), null);
		if (before !== undefined) process.env.SELF_CHECK_ENABLED = before;
	});

	await t.test('switched on with nowhere to look is refused rather than guessed', () => {
		const before = { on: process.env.SELF_CHECK_ENABLED, url: process.env.SELF_CHECK_BASE_URL };
		process.env.SELF_CHECK_ENABLED = '1';
		delete process.env.SELF_CHECK_BASE_URL;
		assert.equal(start({}), null);
		stop();
		if (before.on === undefined) delete process.env.SELF_CHECK_ENABLED;
		else process.env.SELF_CHECK_ENABLED = before.on;
		if (before.url !== undefined) process.env.SELF_CHECK_BASE_URL = before.url;
	});
});
