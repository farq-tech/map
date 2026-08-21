import { beforeEach, describe, expect, it } from "vitest";
import {
	AVATAR_PX,
	MAX_SOURCE_BYTES,
	clearAvatar,
	loadAvatar,
	loadVehicleColor,
	normalizeHeading,
	saveAvatar,
	saveVehicleColor,
	squareCrop,
	validateImageFile,
	vehicleColorHex,
	vehicleSvg,
} from "./farqAvatar";

describe("rejecting a file before decoding it", () => {
	it("refuses anything that is not an image", () => {
		expect(validateImageFile({ type: "application/pdf", size: 100 })).toBe("not-an-image");
		expect(validateImageFile({ type: "", size: 100 })).toBe("not-an-image");
	});

	it("refuses a file too large to be a portrait", () => {
		expect(validateImageFile({ type: "image/jpeg", size: MAX_SOURCE_BYTES + 1 })).toBe("too-large");
	});

	it("accepts an ordinary photo", () => {
		expect(validateImageFile({ type: "image/heic", size: 3_000_000 })).toBeNull();
	});

	it("treats a missing file as unreadable rather than crashing", () => {
		expect(validateImageFile(null)).toBe("unreadable");
		expect(validateImageFile(undefined)).toBe("unreadable");
	});
});

describe("cropping a photo to a square", () => {
	it("takes the largest square that fits", () => {
		expect(squareCrop(1000, 600).size).toBe(600);
		expect(squareCrop(600, 1000).size).toBe(600);
	});

	it("centres a landscape photo horizontally", () => {
		const { sx, sy } = squareCrop(1000, 600);
		expect(sx).toBe(200);
		expect(sy).toBe(0);
	});

	it("pulls a portrait crop upward, because a centred crop cuts the forehead off", () => {
		const { sy, size } = squareCrop(600, 1000);
		expect(size).toBe(600);
		expect(sy).toBeLessThan((1000 - 600) / 2);
		expect(sy).toBeGreaterThan(0);
	});

	it("never produces a negative offset on a square photo", () => {
		expect(squareCrop(500, 500)).toEqual({ sx: 0, sy: 0, size: 500 });
	});

	it("survives a degenerate size", () => {
		expect(squareCrop(0, 0).size).toBe(1);
	});
});

describe("heading", () => {
	it("is null when the device did not report one — never a guess", () => {
		/* Geolocation returns null for heading while stationary. Pointing the car
		 * north because we do not know is inventing a fact. */
		expect(normalizeHeading(null)).toBeNull();
		expect(normalizeHeading(undefined)).toBeNull();
		expect(normalizeHeading(NaN)).toBeNull();
		expect(normalizeHeading("north")).toBeNull();
	});

	it("wraps into 0–360", () => {
		expect(normalizeHeading(0)).toBe(0);
		expect(normalizeHeading(359.5)).toBe(359.5);
		expect(normalizeHeading(-90)).toBe(270);
		expect(normalizeHeading(450)).toBe(90);
	});
});

describe("keeping the photo on this device", () => {
	beforeEach(() => {
		localStorage.clear();
	});

	it("round-trips an image", () => {
		const png = "data:image/png;base64,iVBORw0KGgo=";
		expect(saveAvatar(png)).toBe(true);
		expect(loadAvatar()).toBe(png);
	});

	it("refuses to store something that is not an image", () => {
		expect(saveAvatar("https://example.com/me.jpg")).toBe(false);
		expect(loadAvatar()).toBeNull();
	});

	it("ignores a stored value that is not an image, rather than rendering it", () => {
		localStorage.setItem("farq.map.avatar.v1", "javascript:alert(1)");
		expect(loadAvatar()).toBeNull();
	});

	it("clears completely, because removing a photo must actually remove it", () => {
		saveAvatar("data:image/webp;base64,AAAA");
		clearAvatar();
		expect(loadAvatar()).toBeNull();
	});

	it("defaults the car colour and remembers a chosen one", () => {
		expect(loadVehicleColor()).toBe("navy");
		saveVehicleColor("mint");
		expect(loadVehicleColor()).toBe("mint");
	});

	it("falls back to the default when the stored colour is unknown", () => {
		localStorage.setItem("farq.map.vehicle.v1", "chartreuse");
		expect(loadVehicleColor()).toBe("navy");
	});
});

describe("the car", () => {
	it("is tinted to the chosen colour", () => {
		expect(vehicleColorHex("mint")).toBe("#83f1b1");
		expect(vehicleSvg("#83f1b1")).toContain("#83f1b1");
	});

	it("falls back to a real colour for an unknown id", () => {
		expect(vehicleColorHex("chartreuse")).toBe("#1b2a4a");
		expect(vehicleColorHex(null)).toBe("#1b2a4a");
	});

	it("is drawn top-down, because the map is flat", () => {
		const svg = vehicleSvg("#1b2a4a");
		expect(svg).toContain('viewBox="0 0 40 78"');
		expect(svg).toContain('aria-hidden="true"');
	});

	it("renders the avatar big enough to stay crisp on a phone", () => {
		expect(AVATAR_PX).toBeGreaterThanOrEqual(3 * 40);
	});
});
