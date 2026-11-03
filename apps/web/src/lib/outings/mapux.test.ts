import { describe, expect, it } from "vitest";
import { avoidRect, edgeSpot, screenAngle, spreadOnEdges, type Insets } from "./edgeArrows";
import { TRAIL_GAP_MS, TRAIL_MS, trailOpacity, Trails } from "./trail";
import { lightPresetAt, solarElevationDeg, sunsetUtc } from "./sun";
import { DRIVE_HOLD_MS, DRIVE_IDLE, drivingOn, nextDriveState } from "./driving";

const view = { w: 390, h: 844 };
/* top bar to 110 px, peek sheet 148 px */
const insets: Insets = { top: 110, right: 0, bottom: 148, left: 0 };
const chip = { w: 120, h: 34 };

describe("off-screen arrows — geometry", () => {
	it("no chip while the car is inside the visible map", () => {
		expect(edgeSpot({ x: 200, y: 400 }, view, insets, chip)).toBeNull();
	});

	it("a car hidden under the top bar or the sheet counts as off screen", () => {
		const up = edgeSpot({ x: 195, y: 60 }, view, insets, chip)!;
		expect(up.edge).toBe("top");
		expect(up.y).toBeGreaterThanOrEqual(110 + chip.h / 2);
		const down = edgeSpot({ x: 195, y: 780 }, view, insets, chip)!;
		expect(down.edge).toBe("bottom");
		expect(down.y).toBeLessThanOrEqual(844 - 148 - chip.h / 2);
	});

	it("sits on the line from the centre towards the car and points at it", () => {
		/* far east, level with the centre of the visible area */
		const cy = (110 + (844 - 148)) / 2;
		const s = edgeSpot({ x: 5000, y: cy }, view, insets, chip)!;
		expect(s.edge).toBe("right");
		expect(s.y).toBeCloseTo(cy, 5);
		expect(s.x + chip.w / 2).toBeLessThanOrEqual(390);
		expect(s.angle).toBeCloseTo(90, 5);
	});

	it("keeps the whole chip on screen in the corners", () => {
		const s = edgeSpot({ x: -3000, y: -3000 }, view, insets, chip)!;
		expect(s.x - chip.w / 2).toBeGreaterThanOrEqual(0);
		expect(s.y - chip.h / 2).toBeGreaterThanOrEqual(110);
		expect(s.angle).toBeGreaterThan(270);
	});

	it("ignores points the map could not project", () => {
		expect(edgeSpot({ x: NaN, y: 10 }, view, insets, chip)).toBeNull();
	});

	it("screen angles are clockwise from up", () => {
		expect(screenAngle(0, -1)).toBeCloseTo(0);
		expect(screenAngle(1, 0)).toBeCloseTo(90);
		expect(screenAngle(0, 1)).toBeCloseTo(180);
		expect(screenAngle(-1, 0)).toBeCloseTo(270);
	});

	it("chips on the same edge never cover each other and stay inside", () => {
		const spots = [5000, 5001, 5002].map((d, i) => edgeSpot({ x: d, y: 400 + i }, view, insets, chip)!);
		const spread = spreadOnEdges(spots, view, insets, chip);
		const ys = spread.map((s) => s.y).sort((a, b) => a - b);
		expect(ys[1] - ys[0]).toBeGreaterThanOrEqual(chip.h);
		expect(ys[2] - ys[1]).toBeGreaterThanOrEqual(chip.h);
		for (const y of ys) {
			expect(y - chip.h / 2).toBeGreaterThanOrEqual(110);
			expect(y + chip.h / 2).toBeLessThanOrEqual(844 - 148);
		}
	});
});

describe("short trail — memory only, real fixes only", () => {
	const fix = (lng: number, at: number, approximate = false) => ({ lng, lat: 25, at, approximate });

	it("keeps the last two minutes and prunes the rest", () => {
		const t = new Trails();
		t.add("b", fix(46.0, 0), 0);
		t.add("b", fix(46.001, 30_000), 30_000);
		t.add("b", fix(46.002, 100_000), 100_000);
		t.prune(TRAIL_MS + 10_000);
		expect(t.points("b").map((p) => p.at)).toEqual([30_000, 100_000]);
		t.prune(TRAIL_MS + 200_000);
		expect(t.points("b")).toHaveLength(0);
		expect(t.users()).toEqual([]);
	});

	it("never takes approximate, repeated, stale or out-of-order fixes", () => {
		const t = new Trails();
		t.add("b", fix(46.0, 10_000), 10_000);
		t.add("b", fix(46.5, 12_000, true), 12_000);
		t.add("b", fix(46.1, 9_000), 13_000);
		t.add("b", fix(46.2, 10_000), 13_000);
		t.add("b", fix(46.3, 1_000), 1_000 + TRAIL_MS + 1);
		expect(t.points("b").map((p) => p.lng)).toEqual([46.0]);
	});

	it("draws a piece only between consecutive real fixes, breaking on long gaps", () => {
		const t = new Trails();
		t.add("b", fix(46.0, 0), 0);
		t.add("b", fix(46.001, 4_000), 4_000);
		t.add("b", fix(46.002, 4_000 + TRAIL_GAP_MS + 1), 4_000 + TRAIL_GAP_MS + 1);
		const fc = t.features(4_000 + TRAIL_GAP_MS + 1, () => "#d6452f");
		expect(fc.features).toHaveLength(1);
		expect(fc.features[0].geometry.coordinates).toEqual([[46.0, 25], [46.001, 25]]);
		expect(fc.features[0].properties).toMatchObject({ user: "b", color: "#d6452f" });
	});

	it("fades with age", () => {
		expect(trailOpacity(0)).toBe(0.85);
		expect(trailOpacity(TRAIL_MS / 2)).toBeCloseTo(0.43, 2);
		expect(trailOpacity(TRAIL_MS)).toBe(0);
	});

	it("is cleared per person and for everyone", () => {
		const t = new Trails();
		t.add("a", fix(46, 1), 1);
		t.add("b", fix(46, 1), 1);
		t.retain(["a"]);
		expect(t.users()).toEqual(["a"]);
		t.clearAll();
		expect(t.users()).toEqual([]);
	});
});

describe("sun — night look without network", () => {
	const riyadh = { lat: 24.7136, lng: 46.6753 };

	it("Riyadh sunset on 3 Nov 2026 is about 17:13 local (14:13 UTC)", () => {
		const s = sunsetUtc(new Date("2026-11-03T09:00:00Z"), riyadh.lat, riyadh.lng)!;
		const minutes = s.getUTCHours() * 60 + s.getUTCMinutes();
		expect(Math.abs(minutes - (14 * 60 + 13))).toBeLessThanOrEqual(6);
	});

	it("London midsummer sunset is about 20:21 UTC", () => {
		const s = sunsetUtc(new Date("2026-06-21T12:00:00Z"), 51.5074, -0.1278)!;
		const minutes = s.getUTCHours() * 60 + s.getUTCMinutes();
		expect(Math.abs(minutes - (20 * 60 + 21))).toBeLessThanOrEqual(6);
	});

	it("sun is high at Riyadh noon, under the horizon at midnight", () => {
		expect(solarElevationDeg(new Date("2026-11-03T08:50:00Z"), riyadh.lat, riyadh.lng)).toBeGreaterThan(45);
		expect(solarElevationDeg(new Date("2026-11-03T21:00:00Z"), riyadh.lat, riyadh.lng)).toBeLessThan(-30);
	});

	it("picks day, dusk, night and dawn", () => {
		const at = (iso: string) => lightPresetAt(new Date(iso), riyadh.lat, riyadh.lng);
		expect(at("2026-11-03T09:00:00Z")).toBe("day");
		expect(at("2026-11-03T14:15:00Z")).toBe("dusk");
		expect(at("2026-11-03T17:00:00Z")).toBe("night");
		expect(at("2026-11-04T02:50:00Z")).toBe("dawn");
	});
});

describe("driving mode", () => {
	it("turns on when moving and off only after a quiet spell", () => {
		let s = nextDriveState(DRIVE_IDLE, 2, 0);
		expect(s.moving).toBe(false);
		s = nextDriveState(s, 8, 1_000);
		expect(s.moving).toBe(true);
		s = nextDriveState(s, 0.5, 2_000);
		expect(s.moving).toBe(true);
		s = nextDriveState(s, 2, 5_000); // rolling again: the clock restarts
		expect(s.slowSince).toBeNull();
		s = nextDriveState(s, null, 6_000);
		s = nextDriveState(s, 0, 6_000 + DRIVE_HOLD_MS - 1);
		expect(s.moving).toBe(true);
		s = nextDriveState(s, 0, 6_000 + DRIVE_HOLD_MS);
		expect(s.moving).toBe(false);
	});

	it("can be forced on or off", () => {
		expect(drivingOn("on", DRIVE_IDLE)).toBe(true);
		expect(drivingOn("off", { moving: true, slowSince: null })).toBe(false);
		expect(drivingOn("auto", { moving: true, slowSince: null })).toBe(true);
	});
});

describe("edge arrows keep my own name chip clear", () => {
	const view = { w: 390, h: 844 };
	const insets: Insets = { top: 100, right: 70, bottom: 200, left: 0 };
	const chip = { w: 120, h: 40 };
	const hit = (a: { x: number; y: number }, r: { left: number; top: number; right: number; bottom: number }) =>
		a.x - chip.w / 2 < r.right && a.x + chip.w / 2 > r.left && a.y - chip.h / 2 < r.bottom && a.y + chip.h / 2 > r.top;

	it("slides a chip off «أنت» along its edge, to the nearer side", () => {
		/* My label sits at the bottom edge, where a friend behind me would get a chip. */
		const me = { left: 140, top: 600, right: 200, bottom: 630 };
		const spot = edgeSpot({ x: 170, y: 900 }, view, insets, chip)!;
		expect(spot.edge).toBe("bottom");
		expect(hit(spot, me)).toBe(true);
		const [moved] = avoidRect([{ ...spot, id: "b" }], me, view, insets, chip);
		expect(hit(moved, me)).toBe(false);
		expect(moved.edge).toBe("bottom");
		expect(moved.y).toBe(spot.y);
		expect(moved.angle).toBe(spot.angle); // still points at the friend
	});

	it("pushes a neighbour on instead of stacking two chips", () => {
		const me = { left: 140, top: 600, right: 200, bottom: 630 };
		const wide: Insets = { ...insets, right: 0 };
		const a = { ...edgeSpot({ x: 170, y: 900 }, view, wide, chip)!, id: "a" };
		const b = { ...a, x: 120, id: "b" };
		const out = avoidRect([a, b], me, view, wide, chip);
		expect(out.every((s) => !hit(s, me))).toBe(true);
		expect(Math.abs(out[0].x - out[1].x)).toBeGreaterThanOrEqual(chip.w);
	});

	it("leaves chips alone when nothing is covered or there is no label", () => {
		const s = { ...edgeSpot({ x: 20, y: 900 }, view, insets, chip)!, id: "c" };
		expect(avoidRect([s], null, view, insets, chip)).toEqual([s]);
		expect(avoidRect([s], { left: 300, top: 120, right: 320, bottom: 140 }, view, insets, chip)[0]).toEqual(s);
	});
});
