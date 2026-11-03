import { describe, expect, it } from "vitest";
import { CHIP_MS, liveChips, newClipsToPlay, pickRecordingMime, playable, type ClipMeta } from "./voice";

const clip = (over: Partial<ClipMeta>): ClipMeta => ({
	id: "c1",
	user_id: "saad",
	mime: "audio/mp4",
	duration_ms: 3000,
	at: new Date(1_000_000).toISOString(),
	expires_at: new Date(1_000_000 + 600_000).toISOString(),
	url: "/api/outings/o/clips/c1",
	...over,
});

describe("recording format", () => {
	it("asks for AAC/MP4 first — what iOS Safari records and every browser plays", () => {
		const safari = (t: string) => t.startsWith("audio/mp4");
		expect(pickRecordingMime(safari)).toBe("audio/mp4;codecs=mp4a.40.2");
	});
	it("falls back to WebM/Opus without transcoding where MP4 is not recordable", () => {
		const oldChrome = (t: string) => t.startsWith("audio/webm");
		expect(pickRecordingMime(oldChrome)).toBe("audio/webm;codecs=opus");
	});
	it("lets the browser choose when nothing matches or the probe throws", () => {
		expect(pickRecordingMime(() => false)).toBe("");
		expect(pickRecordingMime(() => {
			throw new Error("x");
		})).toBe("");
		expect(pickRecordingMime(undefined)).toBe("");
	});
	it("checks the receiver can play the container", () => {
		expect(playable("audio/webm", (t) => (t.includes("webm") ? "maybe" : ""))).toBe(true);
		expect(playable("audio/webm", (t) => (t.includes("mp4") ? "probably" : ""))).toBe(false);
		expect(playable("audio/mp4", undefined)).toBe(false);
	});
});

describe("which clips are news", () => {
	const now = 1_000_000 + 5_000;
	it("chips: someone else's, unexpired, recent; newest per sender", () => {
		const chips = liveChips([clip({}), clip({ id: "c2", at: new Date(1_002_000).toISOString() }), clip({ id: "mine", user_id: "me" })], "me", now);
		expect([...chips.keys()]).toEqual(["saad"]);
		expect(chips.get("saad")!.id).toBe("c2");
		expect(liveChips([clip({})], "me", 1_000_000 + CHIP_MS + 3_001).size).toBe(0);
	});
	it("autoplay only new, recent clips from others, oldest first", () => {
		const seen = new Set(["old"]);
		const list = [clip({ id: "b", at: new Date(1_003_000).toISOString() }), clip({ id: "a" }), clip({ id: "old" }), clip({ id: "mine", user_id: "me" })];
		expect(newClipsToPlay(list, seen, "me", now).map((c) => c.id)).toEqual(["a", "b"]);
		expect(newClipsToPlay([clip({})], new Set(), "me", 1_000_000 + 200_000)).toEqual([]);
	});
});

describe("voice clips in the outing picture", async () => {
	const { fromSnapshot, applyEvent } = await import("./outingState");
	const snap = {
		outing: { id: "o", name: "x", status: "active" as const, owner_id: "a", created_at: "", started_at: null, ended_at: null },
		me: { user_id: "me", role: "member" as const, sharing: true },
		members: [
			{ user_id: "me", display_name: "أنا", avatar: null, role: "member" as const, sharing: true, joined_at: "" },
			{ user_id: "saad", display_name: "سعد", avatar: null, role: "owner" as const, sharing: true, joined_at: "" },
		],
		positions: [],
		invite: null,
		server_now: new Date(1_000_000).toISOString(),
	};
	it("a clip event adds it; the sender leaving or the outing ending removes it", () => {
		let v = fromSnapshot(snap, 1_000_000);
		v = applyEvent(v, { type: "voice_clip", clip: clip({}) });
		expect(v.snapshot.voice_clips?.map((c) => c.id)).toEqual(["c1"]);
		v = applyEvent(v, { type: "voice_clip", clip: clip({ id: "x", user_id: "stranger" }) });
		expect(v.snapshot.voice_clips?.length).toBe(1);
		expect(applyEvent(v, { type: "member_left", user_id: "saad", reason: "left" }).snapshot.voice_clips).toEqual([]);
		expect(applyEvent(v, { type: "outing_status", status: "ended" }).snapshot.voice_clips).toEqual([]);
	});
});
