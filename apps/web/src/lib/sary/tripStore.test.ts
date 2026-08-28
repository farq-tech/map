import { describe, expect, it } from "vitest";
import { saveTrip } from "./tripStore";

describe("trip store", () => {
	it("rejects an invalid trip before writing", async () => {
		await expect(saveTrip({} as never)).rejects.toThrow("invalid_trip");
	});
});
