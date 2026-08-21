'use strict';

/**
 * Run the synthetic check from inside the service, on a timer.
 *
 * This exists because the intended scheduler is not available: GitHub Actions
 * is locked on this account for billing, so neither the synthetic workflow nor
 * CI has run since it was set up. The workflow is correct and will start working
 * the moment that is fixed; this is what covers the gap meanwhile.
 *
 * Be clear about what it can and cannot see. A monitor living inside the thing
 * it monitors cannot report that the thing is down — nothing runs to report it.
 * What it CAN see is the failure class this whole layer was built for: a healthy
 * process serving wrong or empty data, which is the eleven-day outage shape and
 * is invisible to any liveness probe. Total outage is already covered elsewhere:
 * the platform polls /version with a restart policy.
 *
 * It runs the check SCRIPT as a child process rather than reimplementing the
 * assertions. Two copies of "what correct looks like" would drift, and the one
 * that drifted would be the one nobody was reading.
 *
 * Off unless SELF_CHECK_ENABLED=1.
 */

const path = require('node:path');
const { execFile } = require('node:child_process');
const integrity = require('./result-integrity');

const SCRIPT = path.join(__dirname, '..', 'scripts', 'synthetic-check.mjs');

/**
 * Fifteen minutes, matching the workflow, so behaviour does not change when the
 * scheduler moves back to Actions. Measured cost of a cycle: four requests,
 * ~512 KB gzipped, ~1.4 s.
 */
const DEFAULT_INTERVAL_MS = 15 * 60 * 1000;

/** Give the process time to warm its cache before judging it. */
const DEFAULT_DELAY_MS = 2 * 60 * 1000;

const history = [];
const HISTORY_LIMIT = 48; /* twelve hours at a fifteen-minute cadence */
let timer = null;
let lastSuccessAt = null;

function runOnce(baseUrl) {
	return new Promise((resolve) => {
		execFile(process.execPath, [SCRIPT, '--base', baseUrl, '--json'],
			{ timeout: 60000 },
			(err, stdout) => {
				const exitCode = err ? (typeof err.code === 'number' ? err.code : 1) : 0;
				let result = null;
				try {
					result = JSON.parse(String(stdout).trim().split('\n').pop());
				} catch { /* an unreadable check is itself a failure, handled below */ }
				resolve({ exitCode, result });
			});
	});
}

function record({ exitCode, result }) {
	const at = new Date().toISOString();
	const entry = {
		at,
		exit_code: exitCode,
		ok: exitCode === 0,
		passed: result ? result.passed : null,
		failed: result ? result.failed : null,
		failures: result ? result.failures : [{
			check: 'synthetic check output',
			expected: 'valid JSON',
			actual: 'unreadable',
			endpoint: null,
		}],
	};
	history.unshift(entry);
	if (history.length > HISTORY_LIMIT) history.length = HISTORY_LIMIT;

	if (exitCode === 0) {
		lastSuccessAt = at;
		return entry;
	}

	/* Recorded through the same channel as every other integrity failure, so
	 * /api/health answers 503 and anything watching that endpoint sees it. */
	integrity.record({
		status: exitCode === 2 ? 'self-check-unreachable' : 'self-check-data-failure',
		severity: 'failed',
		city: 'self-check',
		count: entry.passed || 0,
		sourceCount: (entry.passed || 0) + (entry.failed || 0),
		detail: (entry.failures || [])
			.map((f) => `${f.check}: expected ${f.expected}, got ${f.actual}`)
			.join('; ') || 'check failed with no detail',
	});
	return entry;
}

function start({
	baseUrl = process.env.SELF_CHECK_BASE_URL,
	intervalMs = Number(process.env.SELF_CHECK_INTERVAL_MS) || DEFAULT_INTERVAL_MS,
	delayMs = DEFAULT_DELAY_MS,
} = {}) {
	if (process.env.SELF_CHECK_ENABLED !== '1') return null;
	if (!baseUrl) {
		console.warn('[self-check] SELF_CHECK_ENABLED=1 but no SELF_CHECK_BASE_URL — not started');
		return null;
	}
	const tick = async () => {
		try {
			const entry = record(await runOnce(baseUrl));
			if (!entry.ok) {
				console.error('[self-check] exit %d — %s', entry.exit_code,
					(entry.failures || []).map((f) => f.check).join(', '));
			}
		} catch (err) {
			/* Never let the monitor take down the thing it monitors. */
			console.error('[self-check] could not run: %s', err.message);
		}
	};
	setTimeout(tick, delayMs).unref();
	timer = setInterval(tick, intervalMs);
	timer.unref();
	console.log('[self-check] watching %s every %d minutes', baseUrl, Math.round(intervalMs / 60000));
	return timer;
}

function stop() {
	if (timer) clearInterval(timer);
	timer = null;
}

/** What an operator, or /api/health, needs to see. */
function snapshot() {
	return {
		enabled: process.env.SELF_CHECK_ENABLED === '1',
		base_url: process.env.SELF_CHECK_BASE_URL || null,
		last_success_at: lastSuccessAt,
		last_run: history[0] || null,
		recent: history.slice(0, 8),
		/* Said plainly, because a monitor inside the process it watches has a real
		 * blind spot and whoever reads this should know it. */
		blind_spot: 'runs inside the API, so it cannot report a total outage; the platform probes /version for that',
	};
}

module.exports = { start, stop, snapshot, runOnce, record, DEFAULT_INTERVAL_MS };
