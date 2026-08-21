#!/usr/bin/env node
/**
 * Does production actually work, or does it merely respond?
 *
 * Every deploy failure in this repo's recent history was found by a person
 * looking, not by a check. And the failure mode that matters most does not look
 * like a failure at all: a well-formed 200 carrying an empty map. This script
 * exists to fail loudly on exactly that.
 *
 * Design rules it keeps, because a flaky check is worse than no check:
 *   - deterministic: every assertion is a floor or a fixed shipped value, never
 *     an exact count of data that legitimately moves
 *   - cheap: five requests, no auth, no write
 *   - unambiguous: one line per assertion, a non-zero exit, and a final
 *     machine-readable summary a scheduler can alert on
 *
 * Run it by hand:
 *   node apps/api/scripts/synthetic-check.mjs
 *   node apps/api/scripts/synthetic-check.mjs --base http://localhost:4001
 *   node apps/api/scripts/synthetic-check.mjs --json
 *
 * Exit codes: 0 all passed · 1 at least one assertion failed · 2 could not reach
 * the service at all (a different problem, and worth telling apart).
 */

const DEFAULT_BASE = 'https://farq-map-investor.vercel.app';
const TIMEOUT_MS = 30000;

/**
 * Anchors.
 *
 * The district count is exact because it is a file we ship: 187 أحياء for
 * Riyadh. If that number moves without a deploy that intended it, something
 * replaced our boundaries. Everything else is a floor set well below the
 * observed value on 21 Aug 2026, so normal movement never trips it:
 * 5,075 opportunities, 242 in العليا.
 */
const RIYADH_DISTRICT_COUNT = 187;
const MIN_RIYADH_OPPORTUNITIES = 2000;
const ANCHOR_DISTRICT = 'riyadh-al-olaya';
const MIN_ANCHOR_OPPORTUNITIES = 50;

const args = process.argv.slice(2);
const base = (args.includes('--base') ? args[args.indexOf('--base') + 1] : DEFAULT_BASE).replace(/\/$/, '');
const asJson = args.includes('--json');

const results = [];

/**
 * One assertion. `expected` and `actual` are carried separately from the human
 * sentence because an alert has to say what it wanted and what it got — a
 * message that only says "district count check failed" sends someone to the
 * logs to find out the two numbers that were already in hand.
 */
function check(name, ok, { expected, actual, endpoint } = {}) {
	const detail = expected !== undefined || actual !== undefined
		? `expected ${expected}, got ${actual}`
		: '';
	results.push({
		name,
		ok: Boolean(ok),
		expected: expected === undefined ? null : String(expected),
		actual: actual === undefined ? null : String(actual),
		endpoint: endpoint || null,
		detail,
	});
	if (!asJson) {
		console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
	}
	return Boolean(ok);
}

async function get(path) {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
	try {
		const res = await fetch(`${base}${path}`, { signal: controller.signal });
		const text = await res.text();
		let body = null;
		try { body = JSON.parse(text); } catch { /* not json; the caller decides if that matters */ }
		return { status: res.status, headers: res.headers, body, text };
	} finally {
		clearTimeout(timer);
	}
}

async function main() {
	let reachable = false;

	/* 1. Liveness. The platform's own probe, checked here too so an availability
	 *    failure is distinguishable from a data failure at the first request. */
	try {
		const version = await get('/api/version');
		/**
		 * The BODY, not the status code. Reached through the web host, a path this
		 * service does not own is answered by the CDN with the single-page app's
		 * HTML and a 200 — so a status-only assertion would call the API alive
		 * while it was entirely down. A monitor that can be satisfied by an error
		 * page is not a monitor.
		 */
		const alive = version.status === 200
			&& version.body
			&& version.body.signal === 'liveness'
			&& version.body.service === 'farq-map-api';
		reachable = alive;
		check('service is alive', alive, {
			expected: 'HTTP 200 with signal=liveness',
			actual: alive
				? 'HTTP 200 with signal=liveness'
				: `HTTP ${version.status} with ${version.body ? `signal=${version.body.signal}` : `${version.text.slice(0, 40).replace(/\s+/g, ' ')}…`}`,
			endpoint: '/api/version',
		});
	} catch (err) {
		check('service is alive', false, { expected: 'HTTP 200 with signal=liveness', actual: `unreachable (${err.message})`, endpoint: '/api/version' });
	}

	if (!reachable) {
		finish(2);
		return;
	}

	/* 2. Readiness. The process is up; does it believe its own data? */
	try {
		const health = await get('/api/health');
		const dataOk = Boolean(health.body && health.body.ok);
		const why = health.body && health.body.data && health.body.data.last_failure
			? health.body.data.last_failure.detail
			: (health.body && health.body.data && health.body.data.refused_rebuilds || []).length
				? `rebuild refused: ${health.body.data.refused_rebuilds.map((r) => r.violations.join(',')).join('; ')}`
				: 'not ok';
		check('api reports its data is trustworthy', dataOk,
			{ expected: 'data.ok=true', actual: dataOk ? 'data.ok=true' : why, endpoint: '/api/health' });
	} catch (err) {
		check('api reports its data is trustworthy', false,
			{ expected: 'data.ok=true', actual: err.message, endpoint: '/api/health' });
	}

	/* 3. A city we serve returns a map with things on it. This is the assertion a
	 *    silently-broken read layer fails, and it is the whole point. */
	try {
		const city = await get('/api/intelligence/map/city/riyadh/opportunities');
		check('riyadh opportunities respond 200', city.status === 200,
			{ expected: 200, actual: city.status, endpoint: '/api/intelligence/map/city/riyadh/opportunities' });
		const count = city.body && Array.isArray(city.body.features) ? city.body.features.length : 0;
		check('riyadh is not empty', count >= MIN_RIYADH_OPPORTUNITIES,
			{ expected: `>= ${MIN_RIYADH_OPPORTUNITIES} features`, actual: `${count} features`, endpoint: '/api/intelligence/map/city/riyadh/opportunities' });
		const status = city.headers.get('x-farq-data-status');
		check('read layer is not flagged', status !== 'source-empty' && status !== 'stale',
			{ expected: 'ok', actual: status || 'absent', endpoint: '/api/intelligence/map/city/riyadh/opportunities' });
	} catch (err) {
		check('riyadh opportunities', false,
			{ expected: 'a populated FeatureCollection', actual: err.message, endpoint: '/api/intelligence/map/city/riyadh/opportunities' });
	}

	/* 4. The boundaries we ship are the boundaries being served, and a named حي
	 *    still counts. A broken point-in-polygon pass shows up here as a district
	 *    that suddenly counts nothing. */
	try {
		const districts = await get('/api/intelligence/map/city/riyadh/districts');
		check('riyadh districts respond 200', districts.status === 200,
			{ expected: 200, actual: districts.status, endpoint: '/api/intelligence/map/city/riyadh/districts' });
		const features = districts.body && Array.isArray(districts.body.features)
			? districts.body.features : [];
		check('riyadh ships exactly the districts we committed',
			features.length === RIYADH_DISTRICT_COUNT,
			{ expected: RIYADH_DISTRICT_COUNT, actual: features.length, endpoint: '/api/intelligence/map/city/riyadh/districts' });

		const anchor = features.find((f) => f.properties && f.properties.district_id === ANCHOR_DISTRICT);
		check(`${ANCHOR_DISTRICT} exists`, Boolean(anchor),
			{ expected: 'present', actual: anchor ? 'present' : 'missing', endpoint: '/api/intelligence/map/city/riyadh/districts' });
		const opportunities = anchor ? Number(anchor.properties.opportunities) : NaN;
		check(`${ANCHOR_DISTRICT} still counts opportunities`,
			Number.isFinite(opportunities) && opportunities >= MIN_ANCHOR_OPPORTUNITIES,
			{ expected: `>= ${MIN_ANCHOR_OPPORTUNITIES}`, actual: Number.isFinite(opportunities) ? opportunities : 'absent', endpoint: '/api/intelligence/map/city/riyadh/districts' });
	} catch (err) {
		check('riyadh districts', false,
			{ expected: `${RIYADH_DISTRICT_COUNT} districts`, actual: err.message, endpoint: '/api/intelligence/map/city/riyadh/districts' });
	}

	/* 5. A city we do not serve is a clean 404 — not a 500, and not an empty 200. */
	try {
		const missing = await get('/api/intelligence/map/city/atlantis/opportunities');
		check('an unserved city is a clean 404', missing.status === 404,
			{ expected: 404, actual: missing.status, endpoint: '/api/intelligence/map/city/atlantis/opportunities' });
	} catch (err) {
		check('an unserved city is a clean 404', false, { expected: 404, actual: err.message });
	}

	finish(results.every((r) => r.ok) ? 0 : 1);
}

function finish(code) {
	const failed = results.filter((r) => !r.ok);
	const summary = {
		ok: failed.length === 0,
		base,
		checked_at: new Date().toISOString(),
		passed: results.length - failed.length,
		failed: failed.length,
		/* Structured, because the alert needs the two numbers rather than a sentence. */
		failures: failed.map((f) => ({
			check: f.name,
			expected: f.expected,
			actual: f.actual,
			endpoint: f.endpoint,
		})),
		exit_code: code,
	};
	if (asJson) {
		console.log(JSON.stringify(summary));
	} else {
		console.log('');
		console.log(summary.ok
			? `OK — ${summary.passed} checks passed against ${base}`
			: `FAILED — ${summary.failed} of ${results.length} checks failed against ${base}`);
		for (const f of summary.failures) {
			console.log(`  · ${f.check}: expected ${f.expected}, got ${f.actual}`);
		}
	}
	process.exit(code);
}

main().catch((err) => {
	console.error('synthetic check crashed:', err.message);
	process.exit(2);
});
