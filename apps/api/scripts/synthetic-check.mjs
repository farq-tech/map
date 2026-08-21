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

function check(name, ok, detail) {
	results.push({ name, ok: Boolean(ok), detail: detail || '' });
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

	/* 1. The service answers at all, and says whether it believes its own data. */
	try {
		const health = await get('/api/health');
		reachable = true;
		check('health responds 200', health.status === 200, `got ${health.status}`);
		check('health reports ok', health.body && health.body.ok === true,
			health.body && health.body.data_integrity && health.body.data_integrity.last_failure
				? `last failure: ${health.body.data_integrity.last_failure.detail}`
				: '');
	} catch (err) {
		check('health responds', false, `unreachable: ${err.message}`);
	}

	if (!reachable) {
		finish(2);
		return;
	}

	/* 2. A city we serve returns a map with things on it. This is the assertion
	 *    that a silently-broken read layer fails, and it is the whole point. */
	try {
		const city = await get('/api/intelligence/map/city/riyadh/opportunities');
		check('riyadh opportunities respond 200', city.status === 200, `got ${city.status}`);
		const count = city.body && Array.isArray(city.body.features) ? city.body.features.length : 0;
		check('riyadh is not empty', count >= MIN_RIYADH_OPPORTUNITIES,
			`${count} features, floor ${MIN_RIYADH_OPPORTUNITIES}`);
		const status = city.headers.get('x-farq-data-status');
		check('read layer is not flagged', status !== 'source-empty', `status=${status || 'absent'}`);
		if (status === 'stale') {
			check('read layer freshness', false, 'layer is past the staleness ceiling');
		}
	} catch (err) {
		check('riyadh opportunities', false, err.message);
	}

	/* 3. The boundaries we ship are the boundaries being served. */
	try {
		const districts = await get('/api/intelligence/map/city/riyadh/districts');
		check('riyadh districts respond 200', districts.status === 200, `got ${districts.status}`);
		const features = districts.body && Array.isArray(districts.body.features)
			? districts.body.features : [];
		check('riyadh ships exactly the districts we committed',
			features.length === RIYADH_DISTRICT_COUNT,
			`${features.length}, expected ${RIYADH_DISTRICT_COUNT}`);

		/* 4. A named حي that must exist and must have opportunities in it. A
		 *    filter bug or a broken point-in-polygon pass shows up here as a
		 *    district that suddenly counts nothing. */
		const anchor = features.find((f) => f.properties && f.properties.district_id === ANCHOR_DISTRICT);
		check(`${ANCHOR_DISTRICT} exists`, Boolean(anchor));
		const opportunities = anchor && Number(anchor.properties.opportunities);
		check(`${ANCHOR_DISTRICT} still counts opportunities`,
			Number.isFinite(opportunities) && opportunities >= MIN_ANCHOR_OPPORTUNITIES,
			`${opportunities}, floor ${MIN_ANCHOR_OPPORTUNITIES}`);
	} catch (err) {
		check('riyadh districts', false, err.message);
	}

	/* 5. A city we do not serve is a clean 404, not a 500 and not an empty 200. */
	try {
		const missing = await get('/api/intelligence/map/city/atlantis/opportunities');
		check('an unserved city is a clean 404', missing.status === 404, `got ${missing.status}`);
	} catch (err) {
		check('unserved city', false, err.message);
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
		failures: failed.map((f) => `${f.name}${f.detail ? `: ${f.detail}` : ''}`),
	};
	if (asJson) {
		console.log(JSON.stringify(summary));
	} else {
		console.log('');
		console.log(summary.ok
			? `OK — ${summary.passed} checks passed against ${base}`
			: `FAILED — ${summary.failed} of ${results.length} checks failed against ${base}`);
		for (const f of summary.failures) console.log(`  · ${f}`);
	}
	process.exit(code);
}

main().catch((err) => {
	console.error('synthetic check crashed:', err.message);
	process.exit(2);
});
