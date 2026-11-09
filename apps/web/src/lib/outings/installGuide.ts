/**
 * «نزّل سرى البارق وانضم» — invite fallback when the link stays in an iPhone/iPad browser.
 *
 * The page offers a direct app-open path for existing users, plus one clear install button and
 * three short numbered steps for new users. No technical words besides TestFlight, which is the
 * name of an app they have to find.
 *
 * Steps (iPhone):
 *   ١ نزّل TestFlight                 → the TestFlight app in the App Store
 *   ٢ نزّل سرى البارق                 → our public TestFlight link
 *   ٣ افتح سرى البارق، والدعوة جاهزة   → the app offers «لصق» on first launch (the invite was copied)
 *
 * The page cannot see what is installed, so it remembers which step the person left for and
 * highlights the next one when they come back. Only a step number is stored, never the token.
 */
import { IOS_TESTFLIGHT_PUBLIC_URL, TESTFLIGHT_APP_URL } from "./appInstall";

export const APP_NAME = "سرى البارق";

export type Platform = "iphone" | "android" | "other";

/** iPhone / iPad (iPadOS reports itself as a Mac with touch), Android, or anything else. */
export function platformOf(userAgent: string, maxTouchPoints = 0): Platform {
	if (/iPhone|iPad|iPod/i.test(userAgent)) return "iphone";
	if (/Macintosh/i.test(userAgent) && maxTouchPoints > 1) return "iphone";
	if (/Android/i.test(userAgent)) return "android";
	return "other";
}

export type GuideStep = 1 | 2 | 3;

export type GuideStepInfo = { n: GuideStep; text: string; icon: "testflight" | "sary" | "sary-ready"; href: string | null };

/** The three steps, in the owner's words (≤ 5 words each). */
export function guideSteps(betaUrl: string | null = IOS_TESTFLIGHT_PUBLIC_URL): GuideStepInfo[] {
	return [
		{ n: 1, text: "نزّل TestFlight", icon: "testflight", href: TESTFLIGHT_APP_URL },
		{ n: 2, text: `نزّل ${APP_NAME}`, icon: "sary", href: betaUrl },
		{ n: 3, text: `افتح ${APP_NAME}، والدعوة جاهزة`, icon: "sary-ready", href: null },
	];
}

const STEP_KEY = "sary.install.step";

type Store = Pick<Storage, "getItem" | "setItem">;

function safeStore(): Store | null {
	try {
		return typeof localStorage === "undefined" ? null : localStorage;
	} catch {
		return null;
	}
}

/** The step to highlight now (1 for a first visit). */
export function loadStep(store: Store | null = safeStore()): GuideStep {
	try {
		const n = Number(store?.getItem(STEP_KEY));
		return n === 2 || n === 3 ? n : 1;
	} catch {
		return 1;
	}
}

/** Leaving for step `tapped`: when they come back, the step after it is the one to do. Never goes back. */
export function stepAfterLeaving(current: GuideStep, tapped: GuideStep): GuideStep {
	const next = Math.min(3, tapped + 1) as GuideStep;
	return next > current ? next : current;
}

export function saveStep(step: GuideStep, store: Store | null = safeStore()): void {
	try {
		store?.setItem(STEP_KEY, String(step));
	} catch {
		/* private mode: the highlight just stays on step 1 */
	}
}

/** The big button's label: «افتح» once they have been through the install, else «نزّل». */
export function mainButtonText(step: GuideStep): string {
	return step === 3 ? `افتح ${APP_NAME} وانضم` : `نزّل ${APP_NAME} وانضم`;
}

/** «دعاك فلان لطلعة كشتة النفود 🏕️» */
export function inviteLine(owner: string, outing: string): string {
	return `دعاك ${owner} لطلعة ${outing} 🏕️`;
}

/**
 * Try the app; if the page is still in front after `waitMs`, it is not installed — go install.
 * (A visitor who already has the app usually never sees this page: the link opens the app.)
 */
export function openAppOrInstall(
	appUrl: string,
	installUrl: string,
	deps: {
		go: (url: string) => void;
		visible: () => boolean;
		setTimeout: (fn: () => void, ms: number) => unknown;
	},
	waitMs = 1600,
): void {
	deps.go(appUrl);
	deps.setTimeout(() => {
		if (deps.visible()) deps.go(installUrl);
	}, waitMs);
}

/** The persistent strip on the trip page while following in the browser. */
export function browserBanner(platform: Platform): { line: string; action: string | null } {
	if (platform === "android") return { line: "تتابع من المتصفح · موقعك يوقف إذا قفلت الجوال", action: "تطبيق أندرويد قريب" };
	return { line: "تتابع من المتصفح · موقعك يوقف إذا قفلت الجوال", action: `نزّل ${APP_NAME}` };
}

/** Under the strip: what keeps their location flowing, honest about phones without a screen lock API. */
export function keepOpenNote(wakeSupported: boolean): string {
	return wakeSupported
		? "خلّ الصفحة مفتوحة عشان يوصل موقعك — الشاشة تبقى شغّالة"
		: "خلّ الصفحة مفتوحة والشاشة شغّالة عشان يوصل موقعك";
}

/** What the leader sends a member who is following in the browser (same text in the iPhone app). */
export function installGuideMessage(betaUrl: string | null = IOS_TESTFLIGHT_PUBLIC_URL): string {
	return [
		`عشان يوصل موقعك للربع والجوال مقفل، نزّل ${APP_NAME}:`,
		`١ نزّل TestFlight: ${TESTFLIGHT_APP_URL}`,
		`٢ نزّل ${APP_NAME}: ${betaUrl ?? TESTFLIGHT_APP_URL}`,
		`٣ افتح ${APP_NAME}، وافتح رابط الدعوة مرة ثانية`,
	].join("\n");
}
