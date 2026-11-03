import { describe, expect, it } from "vitest";
import { addFix, deserialize, emptyTrip, serialize, totals, type TripState } from "./trip";

const north = (m: number) => 25.2105 + m / 111_195;
const fix = (m: number, at: number, accuracy = 8) => ({ lat: north(m), lng: 46.6201, accuracy, heading: 0, speed: null, at });

function run(fixes: ReturnType<typeof fix>[]): TripState {
	return fixes.reduce(addFix, emptyTrip());
}

describe("trip summary from my own fixes", () => {
	it("adds real steps and counts the time between first and last fix", () => {
		const s = run([fix(0, 0), fix(100, 10_000), fix(200, 20_000), fix(300, 30_000)]);
		const t = totals(s);
		expect(t.distance_m).toBeGreaterThan(295);
		expect(t.distance_m).toBeLessThan(305);
		expect(t.duration_s).toBe(30);
		expect(t.moving_s).toBe(30);
	});
	it("ignores GPS wander while parked, weak fixes and teleports", () => {
		const s = run([fix(0, 0), fix(3, 10_000), fix(-2, 20_000), fix(5000, 21_000), fix(150, 40_000, 400), fix(4, 60_000)]);
		const t = totals(s);
		expect(t.distance_m).toBe(0);
		expect(t.duration_s).toBe(60);
		expect(t.moving_s).toBe(0);
	});
	it("does not bridge a long gap with a straight line", () => {
		const s = run([fix(0, 0), fix(100, 10_000), fix(20_000, 10_000 + 30 * 60_000), fix(20_100, 10_000 + 30 * 60_000 + 10_000)]);
		expect(totals(s).distance_m).toBeLessThan(210);
	});
	it("keeps only totals and one previous fix on the phone — never a list of points", () => {
		const s = run([fix(0, 0), fix(100, 10_000), fix(200, 20_000)]);
		const raw = serialize(s);
		const parsed = JSON.parse(raw);
		expect(Object.keys(parsed).sort()).toEqual(["d", "f", "l", "m", "p", "v"]);
		expect(Array.isArray(parsed.p)).toBe(false);
		expect(totals(deserialize(raw))).toEqual(totals(s));
		expect(deserialize("garbage")).toEqual(emptyTrip());
		expect(deserialize(null)).toEqual(emptyTrip());
	});
});
