import { describe, expect, it } from "vitest";
import {
	PRADO_ASSETS,
	pickPradoPose,
	pradoHeadingRotate,
	buildPradoMarker,
	updatePradoMarker,
} from "./pradoMarker";

describe("prado marker assets", () => {
	it("uses the idle render when stationary and near", () => {
		expect(pickPradoPose({ simplified: false, motion: "idle" })).toBe("idle");
		expect(PRADO_ASSETS.idle).toBe("/sary/prado-stationary-idle.png");
	});

	it("uses the dust render only when actually moving", () => {
		expect(pickPradoPose({ simplified: false, motion: "moving" })).toBe("moving");
		expect(PRADO_ASSETS.moving).toBe("/sary/prado-moving-active.png");
	});

	it("falls back to the 64px marker at far zoom", () => {
		expect(pickPradoPose({ simplified: true, motion: "moving" })).toBe("marker");
		expect(PRADO_ASSETS.marker).toBe("/sary/prado-map-marker-64.png");
	});

	it("does not invent a heading rotation", () => {
		expect(pradoHeadingRotate(null, "idle")).toBe("");
		expect(pradoHeadingRotate(Number.NaN, "idle")).toBe("");
		expect(pradoHeadingRotate(0, "idle")).toBe("rotate(-250deg)");
	});

	it("swaps the image without rebuilding the marker", () => {
		const el = buildPradoMarker();
		expect(el.querySelector("img")?.getAttribute("src")).toBe(PRADO_ASSETS.idle);
		updatePradoMarker(el, { heading: 90, simplified: false, motion: "moving" });
		expect(el.dataset.pose).toBe("moving");
		expect(el.querySelector("img")?.getAttribute("src")).toBe(PRADO_ASSETS.moving);
		updatePradoMarker(el, { heading: 90, simplified: true, motion: "moving" });
		expect(el.dataset.pose).toBe("marker");
		expect(el.querySelector("img")?.getAttribute("src")).toBe(PRADO_ASSETS.marker);
	});
});
