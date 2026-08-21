#!/usr/bin/env node
'use strict';

/**
 * Turn a synthetic check result into an alert, using GitHub Issues.
 *
 * No new alerting service. The repository already runs GitHub Actions, and
 * GitHub already notifies watchers when an issue opens, is commented on, and
 * closes. That gives deduplication (one open issue per failure kind), a natural
 * thread for a continuing outage, and a recovery notification that is impossible
 * to miss — for the cost of a workflow file.
 *
 * All the judgement lives in ../lib/synthetic-alert.js, which is pure and
 * tested. This file only reads the world and carries out the decision.
 *
 * Usage (normally from .github/workflows/synthetic.yml):
 *   node apps/api/scripts/synthetic-alert.js --result result.json --exit-code 1
 *   node apps/api/scripts/synthetic-alert.js --result result.json --exit-code 1 --dry-run
 *
 * Requires `gh` on PATH and GH_TOKEN in the environment, both of which a GitHub
 * Actions runner already has. With --dry-run it prints what it would do and
 * touches nothing, which is how to try it by hand.
 */

const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const { decideAlert, LABELS } = require('../lib/synthetic-alert');

const args = process.argv.slice(2);
const arg = (name, fallback = null) => {
	const i = args.indexOf(name);
	return i === -1 ? fallback : args[i + 1];
};
const dryRun = args.includes('--dry-run');
const environment = arg('--environment', 'production');
const repo = arg('--repo', process.env.GITHUB_REPOSITORY || 'farq-tech/map');
const exitCode = Number(arg('--exit-code', '0'));

function gh(argv) {
	return execFileSync('gh', argv, { encoding: 'utf8', env: process.env });
}

/** What is already open, so we do not open it again. */
function readOpenAlerts() {
	const alerts = [];
	for (const [kind, label] of Object.entries(LABELS)) {
		let rows = [];
		try {
			rows = JSON.parse(gh([
				'issue', 'list', '--repo', repo, '--label', label,
				'--state', 'open', '--json', 'number,createdAt,comments', '--limit', '5',
			]) || '[]');
		} catch (err) {
			console.error(`[alert] could not list issues for ${label}: ${err.message}`);
			continue;
		}
		for (const row of rows) {
			const comments = Array.isArray(row.comments) ? row.comments : [];
			const lastComment = comments.length ? comments[comments.length - 1].createdAt : null;
			alerts.push({ kind, id: row.number, lastNotifiedAt: lastComment || row.createdAt });
		}
	}
	return alerts;
}

/** When did this check last pass completely? Straight from the workflow history. */
function lastSuccessAt() {
	try {
		const rows = JSON.parse(gh([
			'run', 'list', '--repo', repo, '--workflow', 'synthetic.yml',
			'--status', 'success', '--limit', '1', '--json', 'createdAt',
		]) || '[]');
		return rows.length ? rows[0].createdAt : null;
	} catch {
		return null;
	}
}

function main() {
	const resultPath = arg('--result');
	let result = {};
	if (resultPath && fs.existsSync(resultPath)) {
		try {
			result = JSON.parse(fs.readFileSync(resultPath, 'utf8'));
		} catch (err) {
			/* A check that produced unparseable output is itself a failure, and the
			 * alert must say that rather than crashing silently. */
			result = { base: 'unknown', failures: [{ check: 'synthetic check output', expected: 'valid JSON', actual: err.message, endpoint: null }] };
		}
	}

	const openAlerts = dryRun ? [] : readOpenAlerts();
	if (!result.last_success_at && !dryRun) {
		const at = lastSuccessAt();
		if (at) result.last_success_at = at;
	}

	const decision = decideAlert({ exitCode, result, environment, openAlerts });
	console.log(`[alert] ${decision.action} — ${decision.reason}`);

	if (dryRun) {
		if (decision.body) console.log('\n--- would post ---\n' + decision.body);
		return;
	}

	if (decision.action === 'open') {
		/* Create the label if it does not exist yet; harmless when it does. */
		try {
			gh(['label', 'create', decision.label, '--repo', repo, '--color', 'B60205',
				'--description', 'Opened automatically by the synthetic production check']);
		} catch { /* already exists */ }
		const out = gh(['issue', 'create', '--repo', repo, '--title', decision.title,
			'--label', decision.label, '--body', decision.body]);
		console.log(`[alert] opened ${out.trim()}`);
	} else if (decision.action === 'comment') {
		for (const id of decision.targets) {
			gh(['issue', 'comment', String(id), '--repo', repo, '--body', decision.body]);
			console.log(`[alert] commented on #${id}`);
		}
	} else if (decision.action === 'close') {
		for (const id of decision.targets) {
			gh(['issue', 'comment', String(id), '--repo', repo, '--body', decision.body]);
			gh(['issue', 'close', String(id), '--repo', repo, '--reason', 'completed']);
			console.log(`[alert] closed #${id}`);
		}
	}
}

try {
	main();
} catch (err) {
	/* Never let the alerter mask the thing it was alerting about. */
	console.error(`[alert] failed to deliver: ${err.message}`);
	process.exit(0);
}
