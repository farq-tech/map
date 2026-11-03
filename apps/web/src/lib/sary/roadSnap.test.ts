import { describe, expect, it } from "vitest";
import { nearestOnLines, snapRadius } from "./roadSnap";

/* A street running east–west along latitude 24.78. */
const street = [
	[46.66, 24.78],
	[46.67, 24.78],
];

describe("drawing a car on the street", () => {
	it("moves a fix inside a house onto the street beside it", () => {
		/* ~20 m north of the street, inside the block. */
		const p = { lng: 46.665, lat: 24.78018 };
		const s = nearestOnLines(p, [street])!;
		expect(s.lat).toBeCloseTo(24.78, 6);
		expect(s.lng).toBeCloseTo(46.665, 6);
	});

	it("leaves a car alone when no street is near (open desert)", () => {
		const p = { lng: 46.665, lat: 24.7808 }; // ~88 m away
		expect(nearestOnLines(p, [street])).toBeNull();
	});

	it("picks the nearest of two streets", () => {
		const north = [
			[46.66, 24.7802],
			[46.67, 24.7802],
		];
		const s = nearestOnLines({ lng: 46.665, lat: 24.78015 }, [street, north])!;
		expect(s.lat).toBeCloseTo(24.7802, 6);
	});
});

describe("a house set back from the street", () => {
	it("still lands on the street ~50 m away", () => {
		const s = nearestOnLines({ lng: 46.665, lat: 24.78045 }, [street]);
		expect(s?.lat).toBeCloseTo(24.78, 6);
	});
});

describe("how far a car may be moved", () => {
	it("follows the fix's own accuracy, 25–60 m", () => {
		expect(snapRadius(5)).toBe(25);
		expect(snapRadius(30)).toBe(45);
		expect(snapRadius(65)).toBe(60);
		expect(snapRadius(null)).toBe(40);
	});

	it("a sharp fix 50 m from a main road is not dragged onto it", () => {
		expect(nearestOnLines({ lng: 46.665, lat: 24.78045 }, [street], snapRadius(5))).toBeNull();
	});
});
