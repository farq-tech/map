'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
	decideAlert,
	kindForExit,
	COOLDOWN_MS,
	KIND_DATA,
	KIND_AVAILABILITY,
} = require('./synthetic-alert');

const NOW = Date.parse('2026-08-21T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString();

const dataFailure = {
	base: 'https://example.test',
	passed: 8,
	failed: 2,
	failures: [{
		check: 'riyadh ships exactly the districts we committed',
		expected: '187', actual: '0',
		endpoint: '/api/intelligence/map/city/riyadh/districts',
	}],
};

test('an unreachable service and wrong data are different problems', async (t) => {
	await t.test('exit codes map to distinct kinds', () => {
		assert.equal(kindForExit(0), null);
		assert.equal(kindForExit(1), KIND_DATA);
		assert.equal(kindForExit(2), KIND_AVAILABILITY);
	});

	await t.test('each kind opens its own alert, never a shared one', () => {
		const data = decideAlert({ exitCode: 1, result: dataFailure, now: NOW });
		const avail = decideAlert({ exitCode: 2, result: {}, now: NOW });
		assert.equal(data.kind, KIND_DATA);
		assert.equal(avail.kind, KIND_AVAILABILITY);
		assert.notEqual(data.label, avail.label);
		assert.notEqual(data.title, avail.title);
	});

	await t.test('an unreachable service while a data alert is open is new information', () => {
		const d = decideAlert({
			exitCode: 2, result: {}, now: NOW,
			openAlerts: [{ kind: KIND_DATA, id: 7, lastNotifiedAt: iso(NOW) }],
		});
		assert.equal(d.action, 'open');
		assert.equal(d.kind, KIND_AVAILABILITY);
	});

	await t.test('an availability alert says unreachable, and does not invent assertions', () => {
		const d = decideAlert({ exitCode: 2, result: {}, now: NOW });
		assert.match(d.body, /SYNTHETIC AVAILABILITY FAILURE/);
		assert.match(d.body, /Reason: service unreachable/);
		assert.match(d.body, /Exit code: 2/);
	});
});

test('an alert carries what it wanted and what it got', async (t) => {
	await t.test('every field the responder needs is in the body', () => {
		const d = decideAlert({ exitCode: 1, result: dataFailure, now: NOW, environment: 'production' });
		assert.match(d.body, /SYNTHETIC DATA FAILURE/);
		assert.match(d.body, /Environment: production/);
		assert.match(d.body, /2026-08-21T12:00:00/);
		assert.match(d.body, /Exit code: 1/);
		assert.match(d.body, /riyadh ships exactly the districts we committed/);
		assert.match(d.body, /endpoint: \/api\/intelligence\/map\/city\/riyadh\/districts/);
		assert.match(d.body, /expected: 187/);
		assert.match(d.body, /actual:   0/);
	});

	await t.test('the last good run is reported when known, and admitted when not', () => {
		assert.match(decideAlert({ exitCode: 1, result: dataFailure, now: NOW }).body,
			/Last fully successful run: not recorded/);
		assert.match(decideAlert({
			exitCode: 1, now: NOW,
			result: { ...dataFailure, last_success_at: '2026-08-21T11:45:00Z' },
		}).body, /Last fully successful run: 2026-08-21T11:45:00Z/);
	});
});

test('a continuing outage does not flood the channel', async (t) => {
	await t.test('the first failure opens exactly one alert', () => {
		assert.equal(decideAlert({ exitCode: 1, result: dataFailure, now: NOW }).action, 'open');
	});

	await t.test('a second failure inside the cooldown says nothing', () => {
		const d = decideAlert({
			exitCode: 1, result: dataFailure, now: NOW + 15 * 60000,
			openAlerts: [{ kind: KIND_DATA, id: 7, lastNotifiedAt: iso(NOW) }],
		});
		assert.equal(d.action, 'none');
		assert.match(d.reason, /cooldown/);
	});

	await t.test('four hours of failure at a 15-minute cadence produces one alert and four notes', () => {
		let lastNotifiedAt = iso(NOW);
		let opened = 1;
		let comments = 0;
		for (let minute = 15; minute <= 240; minute += 15) {
			const d = decideAlert({
				exitCode: 1, result: dataFailure, now: NOW + minute * 60000,
				openAlerts: [{ kind: KIND_DATA, id: 7, lastNotifiedAt }],
			});
			if (d.action === 'open') opened += 1;
			if (d.action === 'comment') {
				comments += 1;
				lastNotifiedAt = iso(NOW + minute * 60000);
			}
		}
		assert.equal(opened, 1, 'never a second alert for the same live problem');
		assert.equal(comments, 4, '16 failing runs, 4 notes — one an hour');
	});

	await t.test('the cooldown is stated, not implied', () => {
		assert.equal(COOLDOWN_MS, 60 * 60 * 1000);
	});
});

test('recovery is announced, because silence is ambiguous', async (t) => {
	await t.test('a healthy run closes what is open and says why', () => {
		const d = decideAlert({
			exitCode: 0, result: { base: 'https://example.test', passed: 10 }, now: NOW,
			openAlerts: [{ kind: KIND_DATA, id: 7 }],
		});
		assert.equal(d.action, 'close');
		assert.deepEqual(d.targets, [7]);
		assert.match(d.body, /SYNTHETIC RECOVERY/);
		assert.match(d.body, /All 10 checks passing again/);
	});

	await t.test('a healthy run with nothing open stays quiet', () => {
		const d = decideAlert({ exitCode: 0, result: { passed: 10 }, now: NOW });
		assert.equal(d.action, 'none');
	});

	await t.test('recovery closes both kinds when both were open', () => {
		const d = decideAlert({
			exitCode: 0, result: { passed: 10 }, now: NOW,
			openAlerts: [{ kind: KIND_DATA, id: 7 }, { kind: KIND_AVAILABILITY, id: 8 }],
		});
		assert.deepEqual(d.targets.sort(), [7, 8]);
	});
});
