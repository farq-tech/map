import { describe, expect, it } from "vitest";
import { expiresIn } from "./format";

describe("expiresIn", () => {
	const now = Date.UTC(2026, 10, 3, 10, 0, 0);
	it("says minutes under an hour", () => {
		expect(expiresIn(now + 40 * 60_000, true, now)).toBe("ينتهي بعد ٤٠ دقيقة");
		expect(expiresIn(now + 40 * 60_000, false, now)).toBe("expires in 40 min");
	});
	it("says hours under two days", () => {
		expect(expiresIn(now + 23 * 3_600_000, true, now)).toBe("ينتهي بعد ٢٣ ساعة");
	});
	it("says days beyond", () => {
		expect(expiresIn(now + 5 * 86_400_000, true, now)).toBe("ينتهي بعد ٥ أيام");
	});
	it("says expired when past", () => {
		expect(expiresIn(now - 1, true, now)).toBe("انتهت صلاحيته");
	});
});
