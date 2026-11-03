import { describe, expect, it } from "vitest";
import { angleDiff, coarseBbox, groupMotion, rankAlong, shareLine } from "./ahead";

const O = { lat: 25.2, lng: 46.6 };
const km = (dLatKm: number, dLngKm: number) => ({ lat: O.lat + dLatKm / 111.195, lng: O.lng + dLngKm / (111.195 * Math.cos((O.lat * Math.PI) / 180)) });

describe("group direction", () => {
	it("averages the courses of cars that are actually moving", () => {
		const g = groupMotion([
			{ ...O, heading: 350, speed: 20 },
			{ ...O, heading: 10, speed: 20 },
			{ ...O, heading: 180, speed: 0.5 },
		])!;
		expect(g.heading === 0 || g.heading === 360).toBe(true);
		expect(g.movers).toBe(2);
	});
	it("claims no direction when the group disagrees or nobody moves", () => {
		expect(groupMotion([{ ...O, heading: 90, speed: 10 }, { ...O, heading: 270, speed: 10 }])!.heading).toBeNull();
		expect(groupMotion([{ ...O, heading: 90, speed: 0 }])!.heading).toBeNull();
		expect(groupMotion([])).toBeNull();
	});
	it("angleDiff wraps", () => {
		expect(angleDiff(350, 10)).toBe(20);
		expect(angleDiff(10, 350)).toBe(-20);
	});
});

describe("nearest along the way", () => {
	const behind = { id: "b", kind: "fuel", name: "خلفنا", ...km(-3, 0) };
	const ahead = { id: "a", kind: "fuel", name: "قدامنا", ...km(12, 1) };
	const side = { id: "s", kind: "fuel", name: "يمين", ...km(0, 8) };
	it("heading north: the station ahead wins over a nearer one behind", () => {
		const r = rankAlong(O, 0, [behind, ahead, side]);
		expect(r[0].id).toBe("a");
		expect(r[0].ahead).toBe(true);
		expect(Math.round(r[0].alongM! / 1000)).toBe(12);
		expect(r.find((x) => x.id === "b")!.alongM!).toBeLessThan(0);
	});
	it("no heading: plain nearest", () => {
		expect(rankAlong(O, null, [ahead, behind])[0].id).toBe("b");
	});
	it("coarse bbox hides the exact position and stays cacheable", () => {
		expect(coarseBbox({ lat: 25.2105, lng: 46.6201 })).toEqual(coarseBbox({ lat: 25.13, lng: 46.58 }));
		const [w, s, e, n] = coarseBbox(O);
		expect(e - w).toBe(1);
		expect(n - s).toBe(1);
	});
	it("share line fits a car note", () => {
		const r = rankAlong(O, 0, [ahead])[0];
		const line = shareLine(r, true, (m) => `${Math.round(m / 1000)} كم`);
		expect(line).toBe("⛽ قدامنا — 12 كم قدّام");
		expect([...line].length).toBeLessThanOrEqual(80);
	});
});
