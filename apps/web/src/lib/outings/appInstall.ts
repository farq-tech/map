/**
 * The invite page on an iPhone (build 21): open the invite in the app if it is installed, or
 * install it and carry on with the same invite afterwards (a deferred deep link).
 *
 * - «افتح في التطبيق»: `saryalbarq://join/<token>` (the app's own scheme; a universal link tapped
 *   from this same site would stay in Safari). The app reads the token from the last path part.
 * - «نزّل التطبيق»: copies the invite link to the clipboard in the same tap, then goes to the App
 *   Store / TestFlight. On the first launch the app sees "a link is on the pasteboard" (no paste
 *   banner) and offers the system «لصق» button: one tap and the invite opens — no onboarding.
 *
 * The token never goes into a query string or to any server: only into the custom-scheme URL
 * and the clipboard, both on this phone.
 */

/** The public App Store page, once the app is listed. null until then. */
export const IOS_APP_STORE_URL: string | null = null;
/** A public TestFlight link (App Store Connect → TestFlight → external group → public link). null until one exists. */
export const IOS_TESTFLIGHT_PUBLIC_URL: string | null = null;
/** Apple's TestFlight app (needed for any TestFlight build). */
export const TESTFLIGHT_APP_URL = "https://apps.apple.com/app/testflight/id899247664";

export const APP_SCHEME = "saryalbarq";

export type InstallTarget = { url: string; kind: "app-store" | "testflight" | "testflight-app" };

/** Where «نزّل التطبيق» goes: the App Store listing, else the public TestFlight link, else the TestFlight app. */
export function installTarget(appStore: string | null = IOS_APP_STORE_URL, testflight: string | null = IOS_TESTFLIGHT_PUBLIC_URL): InstallTarget {
	if (appStore) return { url: appStore, kind: "app-store" };
	if (testflight) return { url: testflight, kind: "testflight" };
	return { url: TESTFLIGHT_APP_URL, kind: "testflight-app" };
}

/** iPhone / iPad (iPadOS reports itself as a Mac with touch). */
export function isAppleMobile(userAgent: string, maxTouchPoints = 0): boolean {
	if (/iPhone|iPad|iPod/i.test(userAgent)) return true;
	return /Macintosh/i.test(userAgent) && maxTouchPoints > 1;
}

const TOKEN = /^[A-Za-z0-9_-]{43}$/;

/** The app's own link for this invite, or null for anything that is not a token. */
export function appOpenUrl(token: string): string | null {
	return TOKEN.test(token) ? `${APP_SCHEME}://join/${token}` : null;
}

/** The invite link exactly as the app parses it (token in the fragment). */
export function inviteLink(origin: string, token: string): string | null {
	if (!TOKEN.test(token)) return null;
	return `${origin.replace(/\/+$/, "")}/outings/join#${token}`;
}

/** Copy in the same tap (iOS Safari needs the user gesture); falls back to a hidden textarea. */
export async function copyText(text: string): Promise<boolean> {
	try {
		if (navigator.clipboard?.writeText) {
			await navigator.clipboard.writeText(text);
			return true;
		}
	} catch {
		/* fall through */
	}
	try {
		const ta = document.createElement("textarea");
		ta.value = text;
		ta.setAttribute("readonly", "");
		ta.style.position = "fixed";
		ta.style.opacity = "0";
		document.body.appendChild(ta);
		ta.select();
		const ok = document.execCommand("copy");
		document.body.removeChild(ta);
		return ok;
	} catch {
		return false;
	}
}
