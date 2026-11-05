import { afterEach, describe, expect, it, vi } from "vitest";
import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { act } from "react";
import { applyRead, chatBus, checkDraft, deletedLabel, mergeMessages, newClientId, receipt, unreadCount, type ChatMessage } from "./chat";
import { OutingChat } from "../../components/outings/OutingChat";

const ME = "00000000-0000-4000-8000-00000000000a";
const B = "00000000-0000-4000-8000-00000000000b";
const C = "00000000-0000-4000-8000-00000000000c";

function msg(seq: number, over: Partial<ChatMessage> = {}): ChatMessage {
	return {
		id: `m${seq}`,
		outing_id: "o1",
		seq,
		conv: "group",
		sender_id: B,
		recipient_id: null,
		sender_name: "سعد",
		client_id: `c${seq}`,
		kind: "text",
		text: `رسالة ${seq}`,
		point: null,
		created_at: new Date(1_700_000_000_000 + seq * 1000).toISOString(),
		deleted: false,
		deleted_by: null,
		...over,
	};
}

describe("chat helpers", () => {
	it("merges by sender+client_id, orders by server seq, pending last", () => {
		const pending = msg(0, { id: "local-x", client_id: "x", sender_id: ME, pending: "sending" });
		let list = mergeMessages([], [msg(3), msg(1), pending]);
		expect(list.map((m) => m.seq)).toEqual([1, 3, 0]);
		/* The server copy replaces the pending one (same client_id). */
		list = mergeMessages(list, [msg(4, { client_id: "x", sender_id: ME })]);
		expect(list.map((m) => m.id)).toEqual(["m1", "m3", "m4"]);
		/* A late pending echo never overwrites the stored one. */
		list = mergeMessages(list, [{ ...pending, pending: "failed" }]);
		expect(list.find((m) => m.client_id === "x")?.pending).toBeUndefined();
		/* Duplicates (socket + HTTP) collapse to one. */
		expect(mergeMessages(list, [msg(3)]).length).toBe(3);
		/* A deletion sticks even if the original arrives again afterwards. */
		const del = mergeMessages(list, [msg(3, { deleted: true, text: null, deleted_by: "leader" })]);
		expect(mergeMessages(del, [msg(3)]).find((m) => m.seq === 3)?.deleted).toBe(true);
	});

	it("receipts: ✓ stored, ✓✓ when every other member read it", () => {
		const mine = msg(5, { sender_id: ME });
		expect(receipt(mine, ME, [], 2)).toBe("sent");
		expect(receipt(mine, ME, [{ user_id: B, seq: 5 }], 2)).toBe("sent");
		expect(receipt(mine, ME, [{ user_id: B, seq: 6 }, { user_id: C, seq: 5 }], 2)).toBe("read");
		expect(receipt(msg(5), ME, [], 2)).toBeNull();
		expect(receipt({ ...mine, pending: "failed" }, ME, [], 2)).toBe("failed");
		expect(applyRead([{ user_id: B, seq: 9 }], B, 3)).toEqual([{ user_id: B, seq: 9 }]);
		expect(applyRead([{ user_id: B, seq: 2 }], B, 3)).toEqual([{ user_id: B, seq: 3 }]);
	});

	it("unread: others' visible messages above my marker", () => {
		const list = [msg(1), msg(2, { sender_id: ME }), msg(3, { deleted: true }), msg(4)];
		expect(unreadCount(list, ME, 0)).toBe(2);
		expect(unreadCount(list, ME, 1)).toBe(1);
	});

	it("drafts: trimmed, 1000 code points max", () => {
		expect(checkDraft("  هلا  ")).toEqual({ ok: true, text: "هلا" });
		expect(checkDraft("   ")).toEqual({ ok: false, reason: "empty" });
		expect(checkDraft("🚙".repeat(1000)).ok).toBe(true);
		expect(checkDraft("ب".repeat(1001))).toEqual({ ok: false, reason: "too_long" });
		expect(newClientId(() => 0.5, 1)).toMatch(/^[A-Za-z0-9_.:-]{1,64}$/);
		expect(deletedLabel(msg(1, { deleted: true, deleted_by: "leader" }))).toBe("حذفها أمير الرحلة");
	});

	it("bus: only chat_* frames", () => {
		const seen: string[] = [];
		const off = chatBus.on((e) => seen.push(e.type));
		expect(chatBus.emit({ type: "position" })).toBe(false);
		expect(chatBus.emit({ type: "chat_typing" })).toBe(true);
		off();
		chatBus.emit({ type: "chat_read" });
		expect(seen).toEqual(["chat_typing"]);
	});
});

describe("OutingChat panel", () => {
	afterEach(() => {
		vi.unstubAllGlobals();
		document.body.innerHTML = "";
	});

	it("loads the group chat, shows live messages, sends with a client id, ✓✓ on read", async () => {
		(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
		localStorage.setItem("sary.outings.identity.v1", JSON.stringify({ token: "t".repeat(43), user: { id: ME, display_name: "أنا" } }));
		const calls: Array<{ method: string; url: string; body: unknown }> = [];
		vi.stubGlobal(
			"fetch",
			vi.fn(async (url: string, init: RequestInit = {}) => {
				const body = init.body ? JSON.parse(String(init.body)) : undefined;
				calls.push({ method: init.method || "GET", url, body });
				const json = (x: unknown) => new Response(JSON.stringify({ ok: true, ...(x as object) }), { status: 200 });
				if (/\/chat\/group\?/.test(url)) return json({ with: "group", messages: [msg(1)], has_more: false, my_read_seq: 0, reads: [], writable: true, read_only_reason: null });
				if (/\/chat\/group\/read$/.test(url)) return json({ last_read_seq: body.seq });
				if (/\/chat\/group$/.test(url) && init.method === "POST") return json({ message: msg(3, { sender_id: ME, client_id: body.client_id, text: body.text, kind: body.kind }), duplicate: false });
				return new Response("{}", { status: 404 });
			}),
		);
		const host = document.createElement("div");
		document.body.appendChild(host);
		const root = createRoot(host);
		const onSeen = vi.fn();
		await act(async () => {
			root.render(
				createElement(OutingChat, {
					outingId: "o1",
					meId: ME,
					isRTL: true,
					live: true,
					names: new Map([[B, "فهد أخوي"], [ME, "أنا"]]),
					colors: new Map([[B, "#d6452f"]]),
					othersCount: 1,
					canModerate: false,
					myLocation: null,
					onShowPoint: () => {},
					onSeen,
				}),
			);
		});
		await act(async () => {
			await new Promise((r) => setTimeout(r, 0));
		});
		const items = () => [...host.querySelectorAll('[data-testid="outing-chat-message"]')];
		expect(items().length).toBe(1);
		expect(host.textContent).toContain("فهد أخوي");
		expect(calls.some((c) => c.url.endsWith("/chat/group/read") && (c.body as { seq: number }).seq === 1)).toBe(true);
		expect(onSeen).toHaveBeenCalled();

		/* A message arrives on the live socket. */
		await act(async () => {
			chatBus.emit({ type: "chat_message", message: msg(2, { text: "وينكم؟" }) });
		});
		expect(items().length).toBe(2);
		expect(host.textContent).toContain("وينكم؟");

		/* Quick reply → POST with a client id; then ✓ → ✓✓ when B reads it. */
		const quick = [...host.querySelectorAll('[data-testid="outing-chat-quick"] button')].find((b) => b.textContent === "وصلت") as HTMLButtonElement;
		await act(async () => {
			quick.click();
			await new Promise((r) => setTimeout(r, 0));
		});
		const post = calls.find((c) => c.method === "POST" && c.url.endsWith("/chat/group"));
		expect(post?.body).toMatchObject({ kind: "quick", text: "وصلت" });
		expect(typeof (post?.body as { client_id: string }).client_id).toBe("string");
		expect(host.querySelector('[data-testid="outing-chat-receipt"]')?.getAttribute("data-state")).toBe("sent");
		await act(async () => {
			chatBus.emit({ type: "chat_read", conv: "group", user_id: B, peer_id: null, seq: 3 });
		});
		expect(host.querySelector('[data-testid="outing-chat-receipt"]')?.getAttribute("data-state")).toBe("read");

		/* Direct messages never land in the group panel. */
		await act(async () => {
			chatBus.emit({ type: "chat_message", message: msg(4, { conv: "direct", recipient_id: ME }) });
		});
		expect(items().length).toBe(3);
		await act(async () => root.unmount());
	});
});
