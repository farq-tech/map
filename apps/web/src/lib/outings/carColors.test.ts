import { describe, expect, it } from "vitest";
import { memberColors, OUTING_CAR_COLORS } from "./carColors";

describe("participant car colours", () => {
	it("gives each member a different colour, by join order", () => {
		const m = [
			{ user_id: "b", joined_at: "2026-11-03T10:00:02Z" },
			{ user_id: "a", joined_at: "2026-11-03T10:00:01Z" },
			{ user_id: "c", joined_at: "2026-11-03T10:00:03Z" },
		];
		const c = memberColors(m);
		expect(c.get("a")).toBe(OUTING_CAR_COLORS[0]);
		expect(c.get("b")).toBe(OUTING_CAR_COLORS[1]);
		expect(new Set(c.values()).size).toBe(3);
	});

	it("is the same on every device whatever order the list arrives in", () => {
		const m = Array.from({ length: 12 }, (_, i) => ({ user_id: `u${i}`, joined_at: `2026-11-03T10:00:${String(i).padStart(2, "0")}Z` }));
		expect([...memberColors(m)]).toEqual([...memberColors([...m].reverse())]);
		expect(new Set(memberColors(m).values()).size).toBe(12);
	});
});
