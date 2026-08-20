import { describe, expect, it } from "vitest";
import {
	shouldShow3dObjects,
	shouldSkipGlobeIntro,
} from "./farqMapDevice";

describe("map device gates", () => {
	it("turns Standard 3D off on iPhone / Safari / coarse pointer", () => {
		expect(shouldShow3dObjects({ coarsePointer: true })).toBe(false);
		expect(shouldShow3dObjects({ iphoneOrSafari: true })).toBe(false);
		expect(
			shouldShow3dObjects({ coarsePointer: false, iphoneOrSafari: false }),
		).toBe(true);
	});

	it("skips the globe intro on mobile, Safari, and reduced motion", () => {
		expect(shouldSkipGlobeIntro({ reducedMotion: true })).toBe(true);
		expect(shouldSkipGlobeIntro({ coarsePointer: true })).toBe(true);
		expect(shouldSkipGlobeIntro({ iphoneOrSafari: true })).toBe(true);
		expect(
			shouldSkipGlobeIntro({
				reducedMotion: false,
				coarsePointer: false,
				iphoneOrSafari: false,
			}),
		).toBe(false);
	});
});
