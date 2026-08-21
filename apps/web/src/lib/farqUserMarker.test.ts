import { describe, expect, it } from "vitest";
import { buildUserMarker, updateUserMarker } from "./farqUserMarker";

const base = { avatar: null, vehicleColor: null, heading: null, isRTL: true };
const PHOTO = "data:image/webp;base64,AAAA";

describe("before anyone personalises anything", () => {
	it("is the pulsing dot this map has always drawn", () => {
		const el = buildUserMarker(base);
		expect(el.querySelector<HTMLElement>(".farq-user-pulse")!.hidden).toBe(false);
		expect(el.querySelector<HTMLElement>(".farq-user-avatar")!.hidden).toBe(true);
	});

	it("draws no car, because how someone is travelling is not ours to assume", () => {
		const el = buildUserMarker(base);
		const vehicle = el.querySelector<HTMLElement>(".farq-user-vehicle")!;
		expect(vehicle.hidden).toBe(true);
		expect(vehicle.innerHTML).toBe("");
	});

	it("says «أنت هنا» in Arabic and «You are here» in English", () => {
		expect(buildUserMarker(base).querySelector(".farq-user-here")!.textContent).toBe("أنت هنا");
		expect(buildUserMarker({ ...base, isRTL: false }).querySelector(".farq-user-here")!.textContent)
			.toBe("You are here");
	});
});

describe("once there is a photo", () => {
	it("shows the photo above the car and retires the dot", () => {
		const el = buildUserMarker({ ...base, avatar: PHOTO });
		expect(el.querySelector<HTMLElement>(".farq-user-avatar")!.hidden).toBe(false);
		expect(el.querySelector("img")!.getAttribute("src")).toBe(PHOTO);
		expect(el.querySelector<HTMLElement>(".farq-user-vehicle")!.hidden).toBe(false);
		expect(el.querySelector<HTMLElement>(".farq-user-pulse")!.hidden).toBe(true);
	});

	it("tints the car to the chosen colour", () => {
		const el = buildUserMarker({ ...base, avatar: PHOTO, vehicleColor: "mint" });
		expect(el.querySelector(".farq-user-vehicle")!.innerHTML).toContain("#83f1b1");
	});

	it("keeps the photo decorative, because the label already carries the meaning", () => {
		const img = buildUserMarker({ ...base, avatar: PHOTO }).querySelector("img")!;
		expect(img.getAttribute("alt")).toBe("");
		expect(img.getAttribute("aria-hidden")).toBe("true");
	});

	it("does not replace the image element on every position update", () => {
		/* A new <img> on each GPS fix makes the photo flicker at walking pace. */
		const el = buildUserMarker({ ...base, avatar: PHOTO });
		const first = el.querySelector("img");
		updateUserMarker(el, { ...base, avatar: PHOTO, heading: 90 });
		expect(el.querySelector("img")).toBe(first);
	});
});

describe("pointing the car", () => {
	it("rotates to a reported heading", () => {
		const el = buildUserMarker({ ...base, avatar: PHOTO, heading: 137 });
		expect(el.querySelector<HTMLElement>(".farq-user-vehicle")!.style.transform)
			.toBe("rotate(137deg)");
	});

	it("does not point north when the device reported nothing", () => {
		/* Geolocation gives a null heading whenever the device is stationary.
		 * North would be a claim; no rotation is the absence of one. */
		const el = buildUserMarker({ ...base, avatar: PHOTO, heading: null });
		expect(el.querySelector<HTMLElement>(".farq-user-vehicle")!.style.transform).toBe("");
	});

	it("keeps the last known bearing when a fix stops reporting one", () => {
		const el = buildUserMarker({ ...base, avatar: PHOTO, heading: 90 });
		updateUserMarker(el, { ...base, avatar: PHOTO, heading: null });
		expect(el.querySelector<HTMLElement>(".farq-user-vehicle")!.style.transform)
			.toBe("rotate(90deg)");
	});

	it("wraps a negative bearing rather than rotating backwards", () => {
		const el = buildUserMarker({ ...base, avatar: PHOTO, heading: -90 });
		expect(el.querySelector<HTMLElement>(".farq-user-vehicle")!.style.transform)
			.toBe("rotate(270deg)");
	});
});

describe("removing the photo", () => {
	it("returns the marker to the plain dot and drops the image entirely", () => {
		const el = buildUserMarker({ ...base, avatar: PHOTO });
		updateUserMarker(el, base);
		expect(el.querySelector("img")).toBeNull();
		expect(el.querySelector<HTMLElement>(".farq-user-pulse")!.hidden).toBe(false);
		expect(el.querySelector<HTMLElement>(".farq-user-vehicle")!.hidden).toBe(true);
	});
});
