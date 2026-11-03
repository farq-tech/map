// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { INVITE_IMAGE_PATH, inviteHtml, publicOrigin } from "./inviteMeta";

const index = readFileSync(new URL("../../../index.html", import.meta.url), "utf8");

describe("invite link preview page", () => {
	const html = inviteHtml(index, "https://sary.example");
	it("carries the Arabic card WhatsApp reads", () => {
		expect(html).toContain('<meta property="og:title" content="دعوة إلى طلعة" />');
		expect(html).toContain('<meta property="og:image" content="https://sary.example/og/outing-invite.png" />');
		expect(html).toContain('<meta property="og:locale" content="ar_SA" />');
		expect(html).toMatch(/<title>دعوة إلى طلعة · سَرى البارق<\/title>/);
		expect(html.match(/name="description"/g)).toHaveLength(1);
	});
	it("still boots the app", () => {
		expect(html).toContain('<div id="root"></div>');
		expect(html).toContain('src="/src/main.tsx"');
	});
	it("names no outing, person or token", () => {
		expect(html).not.toMatch(/#[A-Za-z0-9_-]{43}/);
		expect(html).toContain('content="https://sary.example/outings/join"');
	});
	it("origin comes from the build env, or stays relative", () => {
		expect(publicOrigin({ VERCEL_PROJECT_PRODUCTION_URL: "sary.vercel.app" })).toBe("https://sary.vercel.app");
		expect(publicOrigin({ SARY_PUBLIC_ORIGIN: "https://map.farq.sa/", VERCEL_URL: "x.vercel.app" })).toBe("https://map.farq.sa");
		expect(publicOrigin({ VERCEL_URL: "evil.com/\"><script>" })).toBe("");
		expect(publicOrigin({})).toBe("");
		expect(inviteHtml(index, "")).toContain(`content="${INVITE_IMAGE_PATH}"`);
	});
});
