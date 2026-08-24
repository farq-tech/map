import { describe, expect, it } from "vitest";
import { resolveLandingCamera } from "./farqMapCamera";
import { RIYADH_LNG_LAT } from "./mapboxAccess";

const CITY = { center: RIYADH_LNG_LAT, zoom: 12.15 };
/* Observed getPlace coords — بابا عنتر 1381 and كوتد 6254. */
const SESSION = {
	center: [46.6215488247467, 24.4855703069545] as [number, number],
	zoom: 16,
	pitch: 20,
	bearing: 40,
};
const URL = { center: [46.8017741891959, 24.6765097741797] as [number, number], zoom: 15.2 };

describe("landing camera", () => {
	it("lets a link's camera win over the last pan on remount", () => {
		const landing = resolveLandingCamera({
			initialCamera: URL,
			session: SESSION,
			resumeSession: true,
			fallback: CITY,
		});
		expect(landing.center).toEqual(URL.center);
		expect(landing.zoom).toBe(15.2);
		expect(landing.pitch).toBe(20);
	});

	it("does not resume a session camera for a bare place link", () => {
		const landing = resolveLandingCamera({
			initialCamera: null,
			session: SESSION,
			resumeSession: false,
			fallback: CITY,
		});
		expect(landing.center).toEqual(CITY.center);
		expect(landing.zoom).toBe(12.15);
		expect(landing.pitch).toBe(0);
	});
});
