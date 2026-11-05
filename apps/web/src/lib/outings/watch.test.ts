// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { ago, arabicDigits, fetchWatchStatus, formatDue, relativeDue, takeWatchToken, telHref, tokenFromHash } from "./watch";

const TOKEN = "Abc_def-0123456789ABCDEFGHIJKLMNOPQRSTUVWXY";

describe("watch link token", () => {
	afterEach(() => {
		sessionStorage.clear();
		localStorage.clear();
		window.history.replaceState(null, "", "/");
	});

	it("reads a 43-char base64url token from the fragment only", () => {
		expect(TOKEN).toHaveLength(43);
		expect(tokenFromHash(`#${TOKEN}`)).toBe(TOKEN);
		expect(tokenFromHash(`#token=${TOKEN}`)).toBe(TOKEN);
		expect(tokenFromHash("#short")).toBeNull();
		expect(tokenFromHash(`#${TOKEN}x`)).toBeNull();
		expect(tokenFromHash("")).toBeNull();
	});

	it("wipes the token from the address bar, keeps it for this tab", () => {
		window.history.replaceState(null, "", `/watch#${TOKEN}`);
		expect(takeWatchToken()).toBe(TOKEN);
		expect(window.location.hash).toBe("");
		expect(window.location.pathname).toBe("/watch");
		expect(takeWatchToken()).toBe(TOKEN);
		sessionStorage.clear();
		expect(takeWatchToken()).toBeNull();
	});

	it("posts the token in the body, never the URL; 404 is an invalid link", async () => {
		const calls: Array<{ url: string; init: RequestInit }> = [];
		const fake = (async (url: string, init: RequestInit) => {
			calls.push({ url, init });
			return new Response(JSON.stringify({ ok: true, state: "armed", members: [] }), { status: 200 });
		}) as unknown as typeof fetch;
		const r = await fetchWatchStatus(TOKEN, fake);
		expect(r.ok).toBe(true);
		expect(calls[0].url).toMatch(/\/api\/outings\/watch\/status$/);
		expect(calls[0].url).not.toContain(TOKEN);
		expect(JSON.parse(String(calls[0].init.body))).toEqual({ token: TOKEN });
		const gone = (async () => new Response("{}", { status: 404 })) as unknown as typeof fetch;
		expect(await fetchWatchStatus(TOKEN, gone)).toEqual({ ok: false, reason: "invalid" });
		const down = (async () => {
			throw new Error("offline");
		}) as unknown as typeof fetch;
		expect(await fetchWatchStatus(TOKEN, down)).toEqual({ ok: false, reason: "network" });
	});
});

describe("watch formatting", () => {
	const now = Date.parse("2026-11-04T15:00:00Z");
	it("Arabic-Indic digits and relative times", () => {
		expect(arabicDigits("12:05")).toBe("١٢:٠٥");
		expect(relativeDue("2026-11-04T16:10:00Z", now)).toBe("باقي ساعة و١٠ دقائق");
		expect(relativeDue("2026-11-04T14:35:00Z", now)).toBe("متأخرين ٢٥ دقيقة");
		expect(relativeDue("2026-11-04T17:00:00Z", now)).toBe("باقي ساعتين");
		expect(ago("2026-11-04T14:40:00Z", now)).toBe("قبل ٢٠ دقيقة");
		expect(ago("2026-11-04T14:59:50Z", now)).toBe("قبل أقل من دقيقة");
		expect(formatDue("2026-11-04T16:30:00Z", now)).toMatch(/[٠-٩]/);
	});
	it("tel: only for an E.164 number", () => {
		expect(telHref("+966551234567")).toBe("tel:+966551234567");
		expect(telHref("0551234567")).toBeNull();
		expect(telHref(null)).toBeNull();
		expect(telHref("javascript:alert(1)")).toBeNull();
	});
});
