import { describe, expect, it } from "vitest";
import { isIOS, pushSupport, urlBase64ToUint8Array, type PushEnv } from "./push";

const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1";
const IPAD_DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15";
const ANDROID = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36";

const full: PushEnv = { userAgent: ANDROID, maxTouchPoints: 5, standalone: false, hasServiceWorker: true, hasPushManager: true, hasNotification: true, permission: "default" };

describe("push support", () => {
	it("detects iPhone and iPadOS-as-Mac", () => {
		expect(isIOS(IPHONE)).toBe(true);
		expect(isIOS(IPAD_DESKTOP_UA, 5)).toBe(true);
		expect(isIOS(IPAD_DESKTOP_UA, 0)).toBe(false);
		expect(isIOS(ANDROID, 5)).toBe(false);
	});

	it("iOS in a Safari tab must be added to the home screen first", () => {
		expect(pushSupport({ ...full, userAgent: IPHONE, hasPushManager: false, hasNotification: false })).toBe("ios-needs-home-screen");
		expect(pushSupport({ ...full, userAgent: IPHONE })).toBe("ios-needs-home-screen");
	});

	it("iOS from the home screen can ask", () => {
		expect(pushSupport({ ...full, userAgent: IPHONE, standalone: true })).toBe("available");
	});

	it("Android/desktop: available, denied or unsupported", () => {
		expect(pushSupport(full)).toBe("available");
		expect(pushSupport({ ...full, permission: "denied" })).toBe("denied");
		expect(pushSupport({ ...full, hasPushManager: false })).toBe("unsupported");
	});

	it("decodes a base64url VAPID key", () => {
		const bytes = urlBase64ToUint8Array("BAEC_-8");
		expect(Array.from(bytes)).toEqual([4, 1, 2, 255, 239]);
	});
});
