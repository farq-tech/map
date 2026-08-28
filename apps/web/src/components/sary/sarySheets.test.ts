import { describe, expect, it } from "vitest";
import { aroundLines, summarizeAround } from "../../lib/sary/aroundYou";
import type { OutdoorEntity } from "../../lib/sary/domain";

describe("sheet copy states", () => {
	it("around-you, empty, and weak-gps do not invent features", () => {
		expect(aroundLines(summarizeAround([], { lat: 24.7, lng: 46.6 }), true)).toEqual([]);
		const well: OutdoorEntity = {
			id: "wells:1",
			kind: "well",
			group: "place",
			name: "بئر",
			lng: 46.6,
			lat: 24.7,
			source: "osm",
			evidence: "public",
		};
		const lines = aroundLines(summarizeAround([well], { lat: 24.7, lng: 46.6 }), true);
		expect(lines.some((l) => l.includes("بئر"))).toBe(true);
	});
});
