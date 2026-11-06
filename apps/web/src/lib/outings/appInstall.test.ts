import { describe, expect, it } from "vitest";
import { appOpenUrl, installTarget, inviteLink, isAppleMobile, TESTFLIGHT_APP_URL } from "./appInstall";

const tok = `${"A".repeat(42)}b`;

describe("invite page → the iPhone app", () => {
	it("opens the invite in the app with its own scheme", () => {
		expect(appOpenUrl(tok)).toBe(`saryalbarq://join/${tok}`);
		expect(appOpenUrl("nope")).toBeNull();
		expect(appOpenUrl(`${tok}?x=1`)).toBeNull();
	});

	it("keeps the token in the fragment of the copied link (never a query string)", () => {
		const l = inviteLink("https://sary.example/", tok);
		expect(l).toBe(`https://sary.example/outings/join#${tok}`);
		expect(l).not.toContain("?");
		expect(inviteLink("https://sary.example", "short")).toBeNull();
	});

	it("installs from the App Store, else public TestFlight, else the TestFlight app", () => {
		expect(installTarget("https://apps.apple.com/app/id1", "https://testflight.apple.com/join/X")).toEqual({ url: "https://apps.apple.com/app/id1", kind: "app-store" });
		expect(installTarget(null, "https://testflight.apple.com/join/X")).toEqual({ url: "https://testflight.apple.com/join/X", kind: "testflight" });
		expect(installTarget(null, null)).toEqual({ url: TESTFLIGHT_APP_URL, kind: "testflight-app" });
	});

	it("shows the app path on iPhone and iPad only", () => {
		expect(isAppleMobile("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)")).toBe(true);
		expect(isAppleMobile("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 5)).toBe(true);
		expect(isAppleMobile("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 0)).toBe(false);
		expect(isAppleMobile("Mozilla/5.0 (Linux; Android 14)")).toBe(false);
	});
});
