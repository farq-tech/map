import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
	buildReport,
	clearDiag,
	createDiagState,
	DIAG_SCHEMA,
	detectDevice,
	diag,
	isFieldTestOn,
	loadDiag,
	MAX_SAMPLES,
	percentile,
	saveDiag,
	setFieldTestOn,
	summarize,
	type DiagState,
} from "./fieldDiagnostics";

const device = { platform: "android", browser: "chrome", standalone: false };
const fresh = (): DiagState => {
	const s = createDiagState(device, "balanced");
	diag.startSession(s, 0);
	return s;
};

/** Key paths of a JSON value (objects only), to pin the report shape. */
function shape(v: unknown, prefix = ""): string[] {
	if (!v || typeof v !== "object" || Array.isArray(v)) return [prefix];
	return Object.entries(v as Record<string, unknown>).flatMap(([k, x]) =>
		k === "refused_by_reason" ? [`${prefix}${k}`] : shape(x, `${prefix}${k}.`),
	);
}

/** A short scripted drive: connect, lose the socket, poll, recover. */
function scriptedDrive(): DiagState {
	const s = fresh();
	diag.link(s, "connecting", 0);
	diag.link(s, "live", 1_200); // first connect 1.2 s
	diag.battery(s, 0.8, false, 1_200);
	for (let i = 0; i < 10; i++) {
		const t = 2_000 + i * 2_500;
		diag.fixSeen(s, 5 + i * 3, t);
		diag.fixAccepted(s);
		diag.fixSent(s);
		diag.sendAttempt(s, "ws", t);
		diag.ack(s, true, undefined, 100 + i * 20, t + 100 + i * 20);
	}
	diag.fixSeen(s, 400, 27_000);
	diag.fixRejected(s, "accuracy");
	diag.link(s, "connecting", 30_000); // tunnel
	diag.link(s, "polling", 33_000);
	diag.sendAttempt(s, "http", 34_000);
	diag.ack(s, false, "stale_fix", 900, 34_900);
	diag.link(s, "live", 38_000); // 8 s outage
	diag.peers(s, { live: 2, recent: 0, lost: 0 }, 40_000);
	diag.peers(s, { live: 1, recent: 1, lost: 0 }, 45_000);
	diag.peers(s, { live: 1, recent: 1, lost: 0 }, 50_000);
	diag.wake(s, "supported");
	diag.wake(s, "acquired");
	diag.wake(s, "lost");
	diag.battery(s, 0.7, false, 1_200 + 3_600_000); // 10 % over one hour
	return s;
}

describe("percentiles", () => {
	it("uses nearest rank and ignores input order", () => {
		const v = [50, 10, 40, 20, 30];
		expect(percentile(v, 50)).toBe(30);
		expect(percentile(v, 95)).toBe(50);
		expect(percentile(v, 0)).toBe(10);
		expect(percentile([], 50)).toBeNull();
		expect(v).toEqual([50, 10, 40, 20, 30]); // not sorted in place
	});

	it("summarises a list of 100", () => {
		const v = Array.from({ length: 100 }, (_, i) => i + 1);
		expect(summarize(v)).toEqual({ count: 100, p50: 50, p90: 90, p95: 95, p99: 99, max: 100, mean: 51 });
		expect(summarize([]).p95).toBeNull();
	});
});

describe("field diagnostics aggregation", () => {
	const r = buildReport(scriptedDrive(), 1_200 + 3_600_000);

	it("counts sends, acks and refusals by reason", () => {
		expect(r.sends).toEqual({ attempts: 11, ws: 10, http: 1, acked_ok: 10, refused: 1, unacked: 0, refused_by_reason: { stale_fix: 1 } });
		expect(r.ack_latency_ms.count).toBe(11);
		expect(r.ack_latency_ms.p50).toBe(200);
		expect(r.ack_latency_ms.max).toBe(900);
	});

	it("times the first connect and each reconnect", () => {
		expect(r.connect_ms.p50).toBe(1_200);
		expect(r.reconnects.count).toBe(1);
		expect(r.reconnects.max).toBe(8_000);
		expect(r.reconnects.total_ms).toBe(8_000);
	});

	it("splits the time between link states", () => {
		expect(r.link_ms.connecting).toBe(1_200 + 3_000);
		expect(r.link_ms.polling).toBe(5_000);
		expect(r.link_ms.live).toBe(r.duration_ms - 1_200 - 3_000 - 5_000);
		expect(r.duration_ms).toBe(1_200 + 3_600_000);
	});

	it("buckets accuracy and counts rejected fixes", () => {
		expect(r.fixes).toEqual({ seen: 11, accepted: 10, sent: 10, rejected: { accuracy: 1, out_of_order: 0, glitch: 0, too_old: 0 } });
		expect(r.accuracy_m.buckets).toEqual({ le10: 2, le30: 7, le60: 1, le150: 0, gt150: 1, unknown: 0 });
		expect(r.accuracy_m.p50).toBe(20);
	});

	it("reports battery drain per hour on battery only", () => {
		expect(r.battery).toMatchObject({ supported: true, start_pct: 80, end_pct: 70, drain_pct_per_hour: 10 });
	});

	it("does not report drain from a short or charging run", () => {
		const s = fresh();
		diag.battery(s, 0.5, false, 0);
		diag.battery(s, 0.49, false, 60_000);
		expect(buildReport(s).battery.drain_pct_per_hour).toBeNull();
		diag.battery(s, 0.6, true, 60_000 + 3_600_000);
		const b = buildReport(s).battery;
		expect(b.drain_pct_per_hour).toBeNull();
		expect(b.charging_ms).toBe(0); // the charging stretch starts at the sample that says so
	});

	it("weighs peer freshness by time watched", () => {
		expect(r.peers).toEqual({ max_members: 2, live_ms: 2 * 5_000 + 5_000, recent_ms: 5_000, lost_ms: 0, live_share: 0.75 });
	});

	it("counts wake-lock events", () => {
		expect(r.wake_lock).toEqual({ supported: true, acquired: 1, lost: 1, failed: 0 });
	});

	it("does not count an outage that started before a wipe or reload as a reconnect", () => {
		const s = fresh();
		diag.link(s, "live", 1_000);
		diag.link(s, "offline", 2_000);
		diag.endSession(s, 3_000);
		diag.startSession(s, 100_000);
		diag.link(s, "live", 100_500);
		const rep = buildReport(s);
		expect(rep.reconnects.count).toBe(0);
		expect(rep.connect_ms.count).toBe(2);
		expect(rep.sessions).toBe(2);
		expect(rep.duration_ms).toBe(3_000 + 500); // the gap between sessions is not counted
	});

	it("keeps hidden time apart and does not count peers while hidden", () => {
		const s = fresh();
		diag.peers(s, { live: 1, recent: 0, lost: 0 }, 0);
		diag.visibility(s, false, 10_000);
		diag.peers(s, { live: 1, recent: 0, lost: 0 }, 20_000);
		diag.visibility(s, true, 30_000);
		const rep = buildReport(s, 30_000);
		expect(rep.visible_ms).toBe(10_000);
		expect(rep.hidden_ms).toBe(20_000);
		expect(rep.peers.live_ms).toBe(0);
	});

	it("bounds its samples", () => {
		const s = fresh();
		for (let i = 0; i < MAX_SAMPLES + 5; i++) diag.ack(s, true, undefined, 50, 1);
		const rep = buildReport(s);
		expect(rep.ack_latency_ms.count).toBe(MAX_SAMPLES);
		expect(rep.samples_dropped).toBe(5);
	});

	it("never lets a reason string carry free text", () => {
		const s = fresh();
		diag.ack(s, false, "Ahmed at 24.71,46.67", null, 1);
		diag.ack(s, false, undefined, null, 1);
		expect(buildReport(s).sends.refused_by_reason).toEqual({ other: 1, refused: 1 });
	});

	it("reporting does not change the recorder", () => {
		const s = scriptedDrive();
		const before = JSON.stringify(s);
		buildReport(s, 9e9);
		expect(JSON.stringify(s)).toBe(before);
	});
});

describe("privacy", () => {
	const r = buildReport(scriptedDrive(), 5_000_000);
	it("holds no coordinates, names, tokens or times of day", () => {
		const json = JSON.stringify(r);
		expect(json).not.toMatch(/"(lat|lng|lon|latitude|longitude|name|display_name|token|user_id|outing_id|phone|[a-z_]*_at)"/i);
		const strings: string[] = [];
		const walk = (v: unknown) => {
			if (typeof v === "string") strings.push(v);
			else if (v && typeof v === "object") Object.values(v).forEach(walk);
		};
		walk(r);
		expect(strings.sort()).toEqual([DIAG_SCHEMA, "android", "balanced", "chrome"].sort());
	});

	it("matches the shared sample file the API validates against", () => {
		const sample = JSON.parse(readFileSync(resolve(__dirname, "../../../../../docs/field-test/sample-diagnostics.json"), "utf8"));
		expect(shape(r).sort()).toEqual(shape(sample).sort());
		expect(sample.schema).toBe(DIAG_SCHEMA);
	});
});

describe("device buckets and storage", () => {
	it("buckets user agents", () => {
		expect(detectDevice("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")).toMatchObject({ platform: "ios", browser: "safari" });
		expect(detectDevice("Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36")).toMatchObject({ platform: "android", browser: "chrome" });
		expect(detectDevice("Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/26.0 Chrome/122.0 Mobile Safari/537.36").browser).toBe("samsung");
		expect(detectDevice("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0 Mobile/15E148 Safari/604.1")).toMatchObject({ platform: "ios", browser: "chrome" });
	});

	it("is off by default and round-trips through storage", () => {
		const m = new Map<string, string>();
		const store = { get: (k: string) => m.get(k) ?? null, set: (k: string, v: string) => m.set(k, v), remove: (k: string) => m.delete(k) };
		expect(isFieldTestOn(store)).toBe(false);
		setFieldTestOn(store, true);
		expect(isFieldTestOn(store)).toBe(true);
		const s = scriptedDrive();
		saveDiag(store, "o1", s);
		expect(loadDiag(store, "o1")).toEqual(s);
		expect(loadDiag(store, "o2")).toBeNull();
		m.set("sary.fieldTest.data.o3", "{not json");
		expect(loadDiag(store, "o3")).toBeNull();
		clearDiag(store, "o1");
		expect(loadDiag(store, "o1")).toBeNull();
	});
});
