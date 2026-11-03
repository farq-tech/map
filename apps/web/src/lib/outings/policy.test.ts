import { describe, expect, it } from "vitest";
import {
	accuracyGrade,
	bearingDeg,
	directionLabel,
	FixFilter,
	freshness,
	shouldSend,
	tierFor,
	trustedHeading,
	type DeviceFix,
} from "./policy";
import { lerp, tweenMs } from "./motion";

const base: DeviceFix = { lat: 24.7, lng: 46.7, accuracy: 8, heading: null, speed: null, at: 0 };
/** metres north of base */
const north = (m: number, at: number, extra: Partial<DeviceFix> = {}): DeviceFix => ({ ...base, lat: base.lat + m / 111_195, at, ...extra });

describe("send policy — off-road tiers", () => {
	it("picks the tier by speed", () => {
		expect(tierFor(35)).toEqual({ intervalMs: 2_500, distanceM: 50 }); // 126 km/h
		expect(tierFor(15)).toEqual({ intervalMs: 4_000, distanceM: 35 }); // 54 km/h
		expect(tierFor(3)).toEqual({ intervalMs: 6_000, distanceM: 15 }); // dunes
		expect(tierFor(3, "saver")).toEqual({ intervalMs: 12_000, distanceM: 30 });
	});

	it("sends on distance or time while moving, whichever first", () => {
		const last = { fix: base, sentAt: 0 };
		/* 140 km/h: 39 m/s — 50 m is crossed in under 2 s */
		expect(shouldSend(north(60, 1500, { speed: 39 }), last, "balanced", 1500)).toBe(true);
		/* road speed, 20 m in 2 s: neither 35 m nor 4 s yet */
		expect(shouldSend(north(20, 2000, { speed: 10 }), last, "balanced", 2000)).toBe(false);
		/* road speed, 4 s passed */
		expect(shouldSend(north(20, 4000, { speed: 10 }), last, "balanced", 4000)).toBe(true);
		/* never twice inside the 1 s floor */
		expect(shouldSend(north(200, 500, { speed: 39 }), last, "balanced", 500)).toBe(false);
	});

	it("parked: only the 30 s heartbeat, never jitter", () => {
		const last = { fix: base, sentAt: 0 };
		expect(shouldSend(north(3, 10_000, { speed: 0 }), last, "balanced", 10_000)).toBe(false);
		expect(shouldSend(north(3, 30_000, { speed: 0 }), last, "balanced", 30_000)).toBe(true);
	});

	it("never sends an older or useless fix", () => {
		const last = { fix: north(0, 5000), sentAt: 5000 };
		expect(shouldSend(north(500, 4000), last, "balanced", 60_000)).toBe(false);
		expect(shouldSend(north(500, 9000, { accuracy: 400 }), last, "balanced", 60_000)).toBe(false);
	});
});

describe("fix filter — a glitch must not move you across the dunes", () => {
	it("holds an implausible jump until the next fix agrees", () => {
		const f = new FixFilter();
		expect(f.accept(north(0, 0))).not.toBeNull();
		/* 2 km in 2 s = 1000 m/s: held */
		expect(f.accept(north(2000, 2000))).toBeNull();
		/* back near the trusted track: accepted, glitch forgotten */
		expect(f.accept(north(30, 4000))).not.toBeNull();
		/* a real relocation confirmed by the next fix */
		expect(f.accept(north(5000, 6000))).toBeNull();
		expect(f.accept(north(5030, 8000))).not.toBeNull();
	});

	it("accepts high but real highway speed", () => {
		const f = new FixFilter();
		f.accept(north(0, 0));
		expect(f.accept(north(200, 5000, { speed: 40 }))).not.toBeNull(); // 144 km/h
	});

	it("gives inaccurate fixes the benefit of their error", () => {
		const f = new FixFilter();
		f.accept(north(0, 0, { accuracy: 100 }));
		expect(f.accept(north(250, 2000, { accuracy: 100 }))).not.toBeNull();
	});
});

describe("freshness — never call an old position live", () => {
	it("moving: live for 15 s", () => {
		expect(freshness({ fixAgeMs: 10_000, speedMps: 20, lastSeenAgeMs: 2_000 })).toBe("live");
		expect(freshness({ fixAgeMs: 20_000, speedMps: 20, lastSeenAgeMs: 2_000 })).toBe("recent");
	});
	it("parked: live for 45 s (fresh fix every 30 s)", () => {
		expect(freshness({ fixAgeMs: 40_000, speedMps: 0, lastSeenAgeMs: 5_000 })).toBe("live");
	});
	it("connected but no new GPS is last-known, not lost", () => {
		expect(freshness({ fixAgeMs: 5 * 60_000, speedMps: 10, lastSeenAgeMs: 10_000 })).toBe("recent");
	});
	it("nothing heard for 60 s is lost", () => {
		expect(freshness({ fixAgeMs: 90_000, speedMps: 10, lastSeenAgeMs: 90_000 })).toBe("lost");
		expect(freshness({ fixAgeMs: 90_000, speedMps: 10, lastSeenAgeMs: null })).toBe("lost");
	});
});

describe("geometry and display", () => {
	it("bearing and Arabic direction", () => {
		expect(Math.round(bearingDeg({ lat: 24, lng: 46 }, { lat: 25, lng: 46 }))).toBe(0);
		expect(Math.round(bearingDeg({ lat: 24, lng: 46 }, { lat: 24, lng: 47 }))).toBe(90);
		expect(directionLabel(45, true)).toBe("شمال شرق");
		expect(directionLabel(350, true)).toBe("شمال");
	});
	it("no arrow for a parked car", () => {
		expect(trustedHeading(90, 0.5)).toBeNull();
		expect(trustedHeading(null, 20)).toBeNull();
		expect(trustedHeading(-90, 20)).toBe(270);
	});
	it("accuracy grades", () => {
		expect(accuracyGrade(12)).toBe("good");
		expect(accuracyGrade(45)).toBe("fair");
		expect(accuracyGrade(90)).toBe("poor");
	});
	it("motion interpolates between real fixes and never overshoots", () => {
		const a = { lng: 46, lat: 24 };
		const b = { lng: 46.01, lat: 24.01 };
		expect(lerp(a, b, 0)).toEqual(a);
		expect(lerp(a, b, 1)).toEqual(b);
		expect(lerp(a, b, 5)).toEqual(b);
		expect(tweenMs(4000, 100, false)).toBe(1000);
		expect(tweenMs(4000, 5000, false)).toBe(0); // snap a long jump
		expect(tweenMs(4000, 100, true)).toBe(0); // reduced motion
	});
});
