import { describe, expect, it } from "vitest";
import { aroundLines, summarizeAround } from "./aroundYou";
import type { OutdoorEntity } from "./domain";

const origin = { lat: 24.71, lng: 46.67 };

function ent(over: Partial<OutdoorEntity>): OutdoorEntity {
	return {
		id: "x",
		kind: "well",
		group: "place",
		name: "بئر",
		lng: 46.671,
		lat: 24.711,
		source: "osm",
		evidence: "public",
		...over,
	};
}

describe("around you", () => {
	it("is empty without a real origin", () => {
		const s = summarizeAround([ent({})], null);
		expect(s.tracks).toBe(0);
		expect(s.nearestWell).toBeNull();
		expect(aroundLines(s, true)).toEqual([]);
	});

	it("counts only features inside the radius", () => {
		const s = summarizeAround(
			[
				ent({ id: "w", kind: "well", group: "place" }),
				ent({ id: "far", kind: "well", group: "place", lng: 50, lat: 26 }),
				ent({ id: "t", kind: "osm_track", group: "movement" }),
				ent({ id: "r", kind: "rawdah", group: "nature", name: "روضة" }),
			],
			origin,
			15_000,
		);
		expect(s.tracks).toBe(1);
		expect(s.nearestWell?.id).toBe("w");
		expect(s.nearestRawdah?.id).toBe("r");
		expect(aroundLines(s, true).some((l) => l.includes("مسارات"))).toBe(true);
	});
});
