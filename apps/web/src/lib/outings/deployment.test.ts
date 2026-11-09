// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const rawConfig = readFileSync(new URL("../../../../../vercel.json", import.meta.url), "utf8");
const config = JSON.parse(rawConfig) as {
	headers: Array<{ source: string; headers: Array<{ key: string; value: string }> }>;
	rewrites: Array<{ source: string; destination: string }>;
};

describe("invite deployment routing", () => {
	it("has one Vercel headers rule list so the AASA MIME rule is not overwritten", () => {
		expect(rawConfig.match(/^\t"headers"\s*:/gm)).toHaveLength(1);
		expect(config.headers).toContainEqual({
			source: "/.well-known/apple-app-site-association",
			headers: [{ key: "Content-Type", value: "application/json" }],
		});
	});

	it("serves the invite route from its token-preserving invite HTML", () => {
		expect(config.rewrites).toContainEqual({
			source: "/outings/join",
			destination: "/outings-join.html",
		});
	});
});
