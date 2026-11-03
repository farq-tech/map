import { describe, expect, it } from "vitest";
import { nearestOnLines } from "./roadSnap";

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
		const p = { lng: 46.665, lat: 24.781 }; // ~110 m away
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
