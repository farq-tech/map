import { describe, expect, it } from "vitest";
import {
	canNavigate,
	navigationNote,
	navigationUrl,
	type NavigationDestination,
} from "./farqNavigation";

const branch: NavigationDestination = {
	lat: 24.712345, lng: 46.678901, source: "branch",
	provider: "jahez", confidence: "exact-branch", disagreementMeters: 9363,
};

describe("building a directions link", () => {
	it("sends coordinates, never a name", () => {
		/* A name lets the map provider resolve the destination to its own idea of
		 * which branch you meant — silently, and looking correct. */
		const url = navigationUrl(branch)!;
		expect(url).toContain("destination=24.712345%2C46.678901");
		expect(url).not.toMatch(/jahez/i);
	});

	it("uses the universal form so one link serves every client", () => {
		expect(navigationUrl(branch)).toMatch(/^https:\/\/www\.google\.com\/maps\/dir\/\?api=1/);
	});

	it("rounds to a precision a pin can actually support", () => {
		const url = navigationUrl({ ...branch, lat: 24.7123456789, lng: 46.6789012345 })!;
		expect(url).toContain("24.712346%2C46.678901");
	});

	it("refuses to build a link the server would not vouch for", () => {
		expect(navigationUrl({ lat: null, lng: null, source: null, confidence: "ambiguous-branch" })).toBeNull();
		expect(navigationUrl(null)).toBeNull();
		expect(navigationUrl(undefined)).toBeNull();
	});

	it("treats a non-finite coordinate as missing rather than as the equator", () => {
		expect(canNavigate({ lat: NaN, lng: 46.6, source: "place", confidence: "place-pin" })).toBe(false);
		expect(canNavigate({ lat: 0, lng: 0, source: "place", confidence: "place-pin" })).toBe(true);
	});
});

describe("saying only what needs saying", () => {
	it("stays quiet when the destination is the exact branch", () => {
		expect(navigationNote(branch, true)).toBeNull();
	});

	it("admits when a listing covers several branches", () => {
		const note = navigationNote(
			{ lat: null, lng: null, source: null, confidence: "ambiguous-branch" }, true);
		expect(note).toContain("أكثر من فرع");
	});

	it("marks an approximate pin as approximate", () => {
		expect(navigationNote({ ...branch, confidence: "place-pin-approximate" }, false))
			.toMatch(/Approximate/);
	});

	it("says nothing about a destination that does not exist", () => {
		expect(navigationNote(null, true)).toBeNull();
	});
});
