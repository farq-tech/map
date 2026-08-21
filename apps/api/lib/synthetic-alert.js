'use strict';

/**
 * What to do about a synthetic check result.
 *
 * Deliberately a pure function: it takes the check's output and the alerts that
 * are already open, and returns a decision. Nothing here talks to a network, so
 * every rule below — deduplication, cooldown, recovery — is testable without a
 * running service or a real outage.
 *
 * Three things it exists to get right:
 *
 *   1. "Farq is unreachable" and "Farq's data is wrong" are different problems
 *      with different responders, so they never share an alert.
 *   2. A four-hour outage must not produce sixteen alerts. One alert, then
 *      occasional reminders, then a clear recovery.
 *   3. Recovery is itself a notification. An alert that goes quiet is
 *      indistinguishable from a monitor that died.
 */

/** Exit codes the check speaks. */
const EXIT_OK = 0;
const EXIT_DATA_FAILURE = 1;
const EXIT_UNREACHABLE = 2;

const KIND_DATA = 'data';
const KIND_AVAILABILITY = 'availability';

/** One label per kind, so the two never collapse into one thread. */
const LABELS = {
	[KIND_DATA]: 'synthetic-data',
	[KIND_AVAILABILITY]: 'synthetic-availability',
};

const TITLES = {
	[KIND_DATA]: (env) => `[synthetic] ${env} — data failure`,
	[KIND_AVAILABILITY]: (env) => `[synthetic] ${env} — unreachable`,
};

/**
 * How long to stay quiet on an alert that is already open.
 *
 * At a fifteen-minute cadence a sustained outage would otherwise post four
 * comments an hour. One an hour is enough to show the condition is still live
 * without burying the original report.
 */
const COOLDOWN_MS = 60 * 60 * 1000;

function kindForExit(exitCode) {
	if (exitCode === EXIT_UNREACHABLE) return KIND_AVAILABILITY;
	if (exitCode === EXIT_OK) return null;
	return KIND_DATA;
}

/**
 * Decide.
 *
 * `openAlerts` is what the alert system currently has open for this
 * environment: `[{ kind, id, lastNotifiedAt }]`. `now` is injected so cooldown
 * is testable.
 */
function decideAlert({
	exitCode,
	result = {},
	environment = 'production',
	openAlerts = [],
	now = Date.now(),
	cooldownMs = COOLDOWN_MS,
} = {}) {
	const kind = kindForExit(exitCode);

	/* Recovered. Close whatever is open, and say so — a channel that simply goes
	 * quiet tells you nothing about whether the problem or the monitor stopped. */
	if (kind === null) {
		const toClose = openAlerts.filter((a) => a.kind === KIND_DATA || a.kind === KIND_AVAILABILITY);
		if (!toClose.length) return { action: 'none', reason: 'healthy, nothing open' };
		return {
			action: 'close',
			kind: null,
			targets: toClose.map((a) => a.id),
			title: null,
			body: recoveryBody({ environment, result, now }),
			reason: `recovered; closing ${toClose.length} open alert(s)`,
		};
	}

	const existing = openAlerts.find((a) => a.kind === kind);

	/* A different kind of failure than the one already open is its own alert —
	 * an unreachable service while a data alert is open is new information. */
	if (!existing) {
		return {
			action: 'open',
			kind,
			label: LABELS[kind],
			title: TITLES[kind](environment),
			body: failureBody({ kind, environment, exitCode, result, now }),
			reason: `first ${kind} failure`,
		};
	}

	const last = existing.lastNotifiedAt ? Date.parse(existing.lastNotifiedAt) : 0;
	if (Number.isFinite(last) && now - last < cooldownMs) {
		return {
			action: 'none',
			kind,
			targets: [existing.id],
			reason: `still failing; ${Math.round((cooldownMs - (now - last)) / 60000)} min left of cooldown`,
		};
	}

	return {
		action: 'comment',
		kind,
		targets: [existing.id],
		body: failureBody({ kind, environment, exitCode, result, now, continued: true }),
		reason: 'still failing; cooldown elapsed',
	};
}

function failureBody({ kind, environment, exitCode, result, now, continued = false }) {
	const heading = kind === KIND_AVAILABILITY
		? 'SYNTHETIC AVAILABILITY FAILURE'
		: 'SYNTHETIC DATA FAILURE';
	const lines = [
		continued ? `${heading} (still failing)` : heading,
		'',
		`Environment: ${environment}`,
		`Time: ${new Date(now).toISOString()}`,
		`Target: ${result.base || 'unknown'}`,
		`Exit code: ${exitCode}`,
	];
	if (kind === KIND_AVAILABILITY) {
		lines.push('Reason: service unreachable');
	}
	const failures = Array.isArray(result.failures) ? result.failures : [];
	if (failures.length) {
		lines.push('', 'Failed checks:');
		for (const f of failures) {
			lines.push(`  · ${f.check}`);
			if (f.endpoint) lines.push(`      endpoint: ${f.endpoint}`);
			lines.push(`      expected: ${f.expected}`);
			lines.push(`      actual:   ${f.actual}`);
		}
	}
	if (result.passed !== undefined) {
		lines.push('', `Passed ${result.passed} of ${result.passed + (result.failed || 0)} checks.`);
	}
	if (result.last_success_at) {
		lines.push(`Last fully successful run: ${result.last_success_at}`);
	} else {
		lines.push('Last fully successful run: not recorded');
	}
	return lines.join('\n');
}

function recoveryBody({ environment, result, now }) {
	return [
		'SYNTHETIC RECOVERY',
		'',
		`Environment: ${environment}`,
		`Time: ${new Date(now).toISOString()}`,
		`Target: ${result.base || 'unknown'}`,
		`All ${result.passed || 0} checks passing again.`,
	].join('\n');
}

module.exports = {
	decideAlert,
	kindForExit,
	failureBody,
	recoveryBody,
	LABELS,
	TITLES,
	COOLDOWN_MS,
	KIND_DATA,
	KIND_AVAILABILITY,
	EXIT_OK,
	EXIT_DATA_FAILURE,
	EXIT_UNREACHABLE,
};
