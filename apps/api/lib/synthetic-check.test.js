'use strict';

/**
 * The check itself, exercised against a controllable server rather than against
 * production. Production cannot be asked to break on demand, and a monitor that
 * has never been seen to fail is not a monitor.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const { execFile } = require('node:child_process');

const SCRIPT = path.join(__dirname, '..', 'scripts', 'synthetic-check.mjs');

/** A stand-in API whose every answer the test controls. */
function makeServer(handler) {
	return new Promise((resolve) => {
		const server = http.createServer(handler);
		server.listen(0, '127.0.0.1', () => {
			const { port } = server.address();
			resolve({ server, base: `http://127.0.0.1:${port}` });
		});
	});
}

function runCheck(base) {
	return new Promise((resolve) => {
		execFile(process.execPath, [SCRIPT, '--base', base, '--json'],
			{ timeout: 60000 },
			(err, stdout) => {
				let parsed = null;
				try { parsed = JSON.parse(String(stdout).trim().split('\n').pop()); } catch { /* malformed */ }
				resolve({ code: err ? err.code : 0, stdout: String(stdout), result: parsed });
			});
	});
}

const districts = (count, olayaOpportunities) => ({
	type: 'FeatureCollection',
	features: Array.from({ length: count }, (_, i) => ({
		type: 'Feature',
		properties: {
			district_id: i === 0 ? 'riyadh-al-olaya' : `riyadh-d${i}`,
			opportunities: i === 0 ? olayaOpportunities : 1,
		},
	})),
});

const opportunities = (count) => ({
	type: 'FeatureCollection',
	city: 'riyadh',
	count,
	features: Array.from({ length: count }, (_, i) => ({ type: 'Feature', properties: { place_id: String(i) } })),
});

/** A server that answers everything correctly unless told otherwise. */
function healthyRoutes(overrides = {}) {
	return (req, res) => {
		const url = req.url.split('?')[0];
		const over = overrides[url];
		if (over) return over(req, res);
		if (url === '/version') return json(res, 200, { ok: true, signal: 'liveness' });
		if (url === '/api/health') return json(res, 200, { ok: true, signal: 'readiness', data: { ok: true } });
		if (url === '/api/intelligence/map/city/riyadh/opportunities') {
			res.setHeader('X-Farq-Data-Status', 'ok');
			return json(res, 200, opportunities(5075));
		}
		if (url === '/api/intelligence/map/city/riyadh/districts') return json(res, 200, districts(187, 242));
		if (url === '/api/intelligence/map/city/atlantis/opportunities') return json(res, 404, { error: 'unknown_city' });
		return json(res, 404, { error: 'not_found' });
	};
}

function json(res, status, body) {
	res.writeHead(status, { 'content-type': 'application/json' });
	res.end(JSON.stringify(body));
}

test('exit 0 — everything as it should be', async () => {
	const { server, base } = await makeServer(healthyRoutes());
	try {
		const run = await runCheck(base);
		assert.equal(run.code, 0);
		assert.equal(run.result.ok, true);
		assert.equal(run.result.failed, 0);
		assert.equal(run.result.passed, 10);
	} finally { server.close(); }
});

test('exit 1 — the data is wrong', async (t) => {
	await t.test('an empty city is caught, and reports the two numbers', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/riyadh/opportunities': (req, res) => {
				res.setHeader('X-Farq-Data-Status', 'ok');
				json(res, 200, opportunities(0));
			},
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1, 'an empty map is a data failure, not a success');
			const failure = run.result.failures.find((f) => f.check === 'riyadh is not empty');
			assert.ok(failure);
			assert.equal(failure.expected, '>= 2000 features');
			assert.equal(failure.actual, '0 features');
			assert.equal(failure.endpoint, '/api/intelligence/map/city/riyadh/opportunities');
		} finally { server.close(); }
	});

	await t.test('a changed district count is caught', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/riyadh/districts': (req, res) => json(res, 200, districts(150, 242)),
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1);
			const f = run.result.failures.find((x) => x.check.includes('districts we committed'));
			assert.equal(f.expected, '187');
			assert.equal(f.actual, '150');
		} finally { server.close(); }
	});

	await t.test('a حي that stopped counting is caught', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/riyadh/districts': (req, res) => json(res, 200, districts(187, 0)),
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1);
			assert.ok(run.result.failures.some((f) => f.check.includes('still counts opportunities')));
		} finally { server.close(); }
	});

	await t.test('a flagged read layer is caught even when the count is fine', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/riyadh/opportunities': (req, res) => {
				res.setHeader('X-Farq-Data-Status', 'stale');
				json(res, 200, opportunities(5075));
			},
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1);
			assert.ok(run.result.failures.some((f) => f.check === 'read layer is not flagged'));
		} finally { server.close(); }
	});

	await t.test('an unserved city answering 200 instead of 404 is caught', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/atlantis/opportunities': (req, res) => json(res, 200, opportunities(0)),
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1);
			assert.ok(run.result.failures.some((f) => f.check.includes('clean 404')));
		} finally { server.close(); }
	});

	await t.test('the api admitting its own data is untrustworthy is a data failure', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/health': (req, res) => json(res, 503, {
				ok: false, data: { ok: false, last_failure: { detail: 'read layer produced no rows for riyadh' } },
			}),
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1);
			const f = run.result.failures.find((x) => x.check.includes('trustworthy'));
			assert.match(f.actual, /no rows/);
		} finally { server.close(); }
	});
});

test('exit 2 — the service cannot be reached at all', async (t) => {
	await t.test('nothing listening is availability, not data', async () => {
		/* Bind a port, learn it, release it — so the address is real and refuses. */
		const { server, base } = await makeServer(healthyRoutes());
		await new Promise((r) => server.close(r));
		const run = await runCheck(base);
		assert.equal(run.code, 2, 'unreachable must never be reported as a data failure');
	});

	await t.test('a liveness probe that errors is availability', async () => {
		const { server, base } = await makeServer((req, res) => {
			if (req.url === '/version') { req.destroy(); return; }
			json(res, 200, {});
		});
		try {
			assert.equal((await runCheck(base)).code, 2);
		} finally { server.close(); }
	});
});

test('a malformed response is a failure, never a pass', async (t) => {
	await t.test('unparseable JSON where a FeatureCollection was promised', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/riyadh/districts': (req, res) => {
				res.writeHead(200, { 'content-type': 'application/json' });
				res.end('{"features": [ this is not json');
			},
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1);
			assert.ok(run.result.failures.some((f) => f.check.includes('districts we committed')));
		} finally { server.close(); }
	});

	await t.test('HTML where JSON was promised — the classic proxy error page', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/riyadh/opportunities': (req, res) => {
				res.writeHead(200, { 'content-type': 'text/html' });
				res.end('<!doctype html><title>502</title>');
			},
		}));
		try {
			const run = await runCheck(base);
			assert.equal(run.code, 1);
			assert.ok(run.result.failures.some((f) => f.check === 'riyadh is not empty'));
		} finally { server.close(); }
	});

	await t.test('an empty body with a 200 is still a failure', async () => {
		const { server, base } = await makeServer(healthyRoutes({
			'/api/intelligence/map/city/riyadh/districts': (req, res) => {
				res.writeHead(200, { 'content-type': 'application/json' });
				res.end('');
			},
		}));
		try {
			assert.equal((await runCheck(base)).code, 1);
		} finally { server.close(); }
	});
});
