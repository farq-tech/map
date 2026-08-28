import { describe, expect, it } from "vitest";
import { appendTripPoint, emptyTrip, parseTripPoint, tripDurationMs, tripIsMoving, tripLine } from "./trip";

describe("trip session", () => {
	it("refuses malformed coordinates", () => {
		expect(parseTripPoint({ lng: "x", lat: 24 })).toBeNull();
		expect(parseTripPoint({ lng: 0, lat: 0 })).toBeNull();
	});

	it("records distance only from accepted points", () => {
		const start = emptyTrip(1_000);
		const a = appendTripPoint(start, { lng: 46.67, lat: 24.71, at: 1_000 });
		const b = appendTripPoint(a, { lng: 46.68, lat: 24.72, at: 2_000 });
		expect(b.points).toHaveLength(2);
		expect(b.distanceM).toBeGreaterThan(1000);
		const invalid = appendTripPoint(b, { lng: 0, lat: 0, at: 3_000 });
		expect(invalid.points).toHaveLength(2);
		expect(tripLine(b)?.geometry.coordinates).toHaveLength(2);
	});

	it("does not grow the line while paused", () => {
		const trip = { ...emptyTrip(1), status: "paused" as const };
		const next = appendTripPoint(trip, { lng: 46.67, lat: 24.71, at: 2 });
		expect(next.points).toHaveLength(0);
	});

	it("subtracts paused time from duration", () => {
		const trip = { ...emptyTrip(0), pausedMs: 10_000, endedAt: 60_000 };
		expect(tripDurationMs(trip, 60_000)).toBe(50_000);
	});

	it("is moving only with a recent real step while recording", () => {
		expect(tripIsMoving(null)).toBe(false);
		const parked = appendTripPoint(emptyTrip(1_000), { lng: 46.67, lat: 24.71, at: 1_000 });
		expect(tripIsMoving(parked, 1_100)).toBe(false);
		const moving = appendTripPoint(parked, { lng: 46.671, lat: 24.711, at: 2_000 });
		expect(tripIsMoving(moving, 2_200)).toBe(true);
		expect(tripIsMoving({ ...moving, status: "paused" }, 2_200)).toBe(false);
		expect(tripIsMoving(moving, 10_000)).toBe(false);
	});
});
