import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { InstallGuide } from "../../components/outings/InstallGuide";
import { IOS_TESTFLIGHT_PUBLIC_URL, TESTFLIGHT_APP_URL } from "./appInstall";
import {
	browserBanner,
	guideSteps,
	installGuideMessage,
	inviteLine,
	keepOpenNote,
	loadStep,
	mainButtonText,
	openAppOrInstall,
	platformOf,
	saveStep,
	stepAfterLeaving,
} from "./installGuide";
import { createWakeKeeper } from "./wakeLock";

const tok = `${"A".repeat(42)}b`;
const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1";
const ANDROID = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/126 Mobile Safari/537.36";

function memStore() {
	const m = new Map<string, string>();
	return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
}

const render = (step?: 1 | 2 | 3) =>
	renderToStaticMarkup(
		createElement(InstallGuide, { owner: "أبو فهد", outingName: "كشتة النفود", token: tok, onBrowser: () => undefined, initialStep: step }),
	);

describe("install guide (iPhone, no app)", () => {
	it("tells the platform apart (iPadOS = iPhone path)", () => {
		expect(platformOf(IPHONE)).toBe("iphone");
		expect(platformOf("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 5)).toBe("iphone");
		expect(platformOf(ANDROID)).toBe("android");
		expect(platformOf("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 0)).toBe("other");
	});

	it("renders one line, one big button, three numbered steps and the small browser link", () => {
		const html = render(1);
		expect(html).toContain("دعاك أبو فهد لطلعة كشتة النفود 🏕️");
		expect(html).toContain("نزّل سرى البارق وانضم");
		expect(html).toContain('data-testid="outing-guide-open-app"');
		expect(html).toContain("عندك التطبيق؟ افتح الدعوة فيه");
		expect(html.match(/data-testid="outing-guide-step-\d"/g)).toHaveLength(3);
		expect(html).toContain("نزّل TestFlight");
		expect(html).toContain("نزّل سرى البارق<");
		expect(html).toContain("افتح سرى البارق، والدعوة جاهزة");
		expect(html).toContain(`href="${TESTFLIGHT_APP_URL}"`);
		expect(html).toContain(`href="${IOS_TESTFLIGHT_PUBLIC_URL}"`);
		expect(html).toContain("ما تبي تنزّل؟ تابع من المتصفح");
		expect(html).toContain("/icons/sary-albarq-app.png");
		/* The token never lands in the markup (it is copied on tap only). */
		expect(html).not.toContain(tok);
	});

	it("highlights the current step and ticks the ones done", () => {
		const one = render(1);
		expect(one).toMatch(/sary-o-guide-step is-current"[^>]*aria-current="step"[^>]*data-testid="outing-guide-step-1"/);
		const three = render(3);
		expect(three).toMatch(/is-current"[^>]*data-testid="outing-guide-step-3"/);
		expect(three).toMatch(/is-done"[^>]*data-testid="outing-guide-step-1"/);
		expect(three).toContain("افتح سرى البارق وانضم");
	});

	it("keeps every step short (≤ 5 words) and uses the full app name", () => {
		for (const s of guideSteps()) expect(s.text.replace("،", "").split(/\s+/).length).toBeLessThanOrEqual(5);
		expect(guideSteps().map((s) => s.text).join(" ")).not.toMatch(/ويب|PWA|سرى(?! البارق)/);
		expect(mainButtonText(1)).toBe("نزّل سرى البارق وانضم");
		expect(inviteLine("فهد", "كشتة")).toBe("دعاك فهد لطلعة كشتة 🏕️");
	});

	it("remembers the step they left for, never going back; storage failures fall back to step 1", () => {
		const store = memStore();
		expect(loadStep(store)).toBe(1);
		expect(stepAfterLeaving(1, 1)).toBe(2);
		expect(stepAfterLeaving(1, 2)).toBe(3);
		expect(stepAfterLeaving(3, 1)).toBe(3);
		saveStep(3, store);
		expect(loadStep(store)).toBe(3);
		const broken = { getItem: () => { throw new Error("x"); }, setItem: () => { throw new Error("x"); } };
		expect(() => saveStep(2, broken)).not.toThrow();
		expect(loadStep(broken)).toBe(1);
	});

	it("opens the app, and goes to install only if the page is still in front", () => {
		const go = vi.fn();
		let fire = () => undefined as void;
		openAppOrInstall("saryalbarq://join/x", "https://tf", { go, visible: () => true, setTimeout: (fn) => (fire = fn) });
		fire();
		expect(go.mock.calls.map((c) => c[0])).toEqual(["saryalbarq://join/x", "https://tf"]);
		const go2 = vi.fn();
		openAppOrInstall("saryalbarq://join/x", "https://tf", { go: go2, visible: () => false, setTimeout: (fn) => (fire = fn) });
		fire();
		expect(go2).toHaveBeenCalledTimes(1);
	});
});

describe("following from the browser", () => {
	it("iPhone strip offers the app; Android says the app is coming", () => {
		expect(browserBanner("iphone")).toEqual({ line: "تتابع من المتصفح · موقعك يوقف إذا قفلت الجوال", action: "نزّل سرى البارق" });
		expect(browserBanner("android").action).toBe("تطبيق أندرويد قريب");
	});

	it("without the Wake Lock API: no lock, and the note asks to keep the screen on", () => {
		const k = createWakeKeeper({}, { visibilityState: "visible", addEventListener: () => undefined, removeEventListener: () => undefined });
		k.set(true);
		expect([k.supported, k.held]).toEqual([false, false]);
		expect(keepOpenNote(k.supported)).toBe("خلّ الصفحة مفتوحة والشاشة شغّالة عشان يوصل موقعك");
		expect(keepOpenNote(true)).toContain("خلّ الصفحة مفتوحة عشان يوصل موقعك");
	});

	it("the leader's message carries the three steps and both links", () => {
		const m = installGuideMessage();
		expect(m).toContain(TESTFLIGHT_APP_URL);
		expect(m).toContain(String(IOS_TESTFLIGHT_PUBLIC_URL));
		expect(m.split("\n")).toHaveLength(4);
	});
});
