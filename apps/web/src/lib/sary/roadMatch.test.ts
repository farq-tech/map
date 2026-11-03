import { describe, expect, it } from "vitest";
import { alignHeading, axialDiff, roadCandidates, RoadMatcher, type RoadLine } from "./roadSnap";

/* Metres → degrees around Riyadh (24.78 N). */
const M_LAT = 1 / 110_540;
const M_LNG = 1 / (111_320 * Math.cos((24.78 * Math.PI) / 180));
const at = (eastM: number, northM: number) => ({ lng: 46.665 + eastM * M_LNG, lat: 24.78 + northM * M_LAT });
const ew = (key: string, northM: number): RoadLine => ({ key, coords: [[46.66, 24.78 + northM * M_LAT], [46.67, 24.78 + northM * M_LAT]] });
const ns = (key: string, eastM: number): RoadLine => ({ key, coords: [[46.665 + eastM * M_LNG, 24.775], [46.665 + eastM * M_LNG, 24.785]] });

/* Two parallel east–west streets 24 m apart; the car drives east on "south". */
const south = ew("south", 0);
const north = ew("north", 24);

describe("staying on the same road across fixes", () => {
	it("does not jump to a parallel street on one wandering fix", () => {
		const m = new RoadMatcher();
		expect(m.match(at(0, 4), [south, north], 90).key).toBe("south");
		/* GPS wanders 16 m north: north street is now nearer (8 m vs 16 m). */
		const r = m.match(at(5, 16), [south, north], 90);
		expect(r.key).toBe("south");
		expect(r.point.lat).toBeCloseTo(24.78, 6);
		/* Back near south: never left it. */
		expect(m.match(at(10, 5), [south, north], 90).key).toBe("south");
	});

	it("moves to the other street once it is clearly closer on two fixes in a row", () => {
		const m = new RoadMatcher();
		m.match(at(0, 3), [south, north], 90);
		expect(m.match(at(5, 21), [south, north], 90).key).toBe("south");
		expect(m.match(at(10, 22), [south, north], 90).key).toBe("north");
	});

	it("needs the two better fixes to be in a row", () => {
		const m = new RoadMatcher();
		m.match(at(0, 3), [south, north], 90);
		m.match(at(5, 21), [south, north], 90);
		m.match(at(10, 4), [south, north], 90);
		expect(m.match(at(15, 21), [south, north], 90).key).toBe("south");
	});

	it("is not fooled by the same fix delivered twice (a re-render)", () => {
		const m = new RoadMatcher();
		m.match(at(0, 3), [south, north], 90);
		const p = at(5, 21);
		m.match(p, [south, north], 90);
		expect(m.match(p, [south, north], 90).key).toBe("south");
	});

	it("takes the nearest road at once when the held one is out of reach", () => {
		const m = new RoadMatcher();
		m.match(at(0, 3), [south, north], 90);
		expect(m.match(at(0, 70), [south, ew("far", 80)], 90, 40).key).toBe("far");
	});

	it("lets go of the road in open desert, and draws the real fix", () => {
		const m = new RoadMatcher();
		m.match(at(0, 3), [south], 90);
		const p = at(0, 200);
		const r = m.match(p, [south], 90);
		expect(r.key).toBeNull();
		expect(r.point).toEqual(p);
		expect(m.road).toBeNull();
	});
});

describe("preferring the road the car is driving along", () => {
	/* A junction: south (east–west) crossed by a north–south street. */
	const cross = ns("cross", 0);

	it("near a junction, a car heading north is put on the north–south street even if the other is a bit nearer", () => {
		const m = new RoadMatcher();
		/* 6 m from south, 9 m from cross. */
		const r = m.match(at(9, 6), [south, cross], 0);
		expect(r.key).toBe("cross");
		expect(r.heading).toBeCloseTo(0, 6);
	});

	it("without a course, nearest wins", () => {
		const m = new RoadMatcher();
		expect(m.match(at(9, 6), [south, cross], null).key).toBe("south");
	});

	it("follows a real turn onto the cross street within two fixes", () => {
		const m = new RoadMatcher();
		m.match(at(-30, 2), [south, cross], 90);
		m.match(at(-10, 1), [south, cross], 90);
		/* Turned left (north) at the junction. */
		const a = m.match(at(1, 12), [south, cross], 5);
		const b = m.match(at(1, 25), [south, cross], 2);
		expect([a.key, b.key]).toContain("cross");
		expect(b.key).toBe("cross");
	});
});

describe("drawing the car along the road", () => {
	it("points the car down the road, in the direction it is driving", () => {
		expect(alignHeading(80, 90)).toBe(90);
		expect(alignHeading(265, 90)).toBe(270);
		expect(alignHeading(355, 180)).toBe(0);
	});

	it("keeps the car's own course while it turns across a road", () => {
		expect(alignHeading(45, 90)).toBe(45);
	});

	it("never gives a parked car a direction", () => {
		expect(alignHeading(null, 90)).toBeNull();
	});

	it("reports the road's direction at the snapped point", () => {
		const [c] = roadCandidates(at(0, 5), [south]);
		expect(axialDiff(90, c.bearing)).toBeCloseTo(0, 3);
		expect(c.distM).toBeCloseTo(5, 0);
	});

	it("aligns a moving car on a matched road", () => {
		const m = new RoadMatcher();
		expect(m.match(at(0, 4), [south], 98).heading).toBeCloseTo(90, 3);
		expect(m.match(at(5, 4), [south], 278).heading).toBeCloseTo(270, 3);
	});
});
