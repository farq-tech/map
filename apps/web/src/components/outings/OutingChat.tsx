import { useCallback, useEffect, useRef, useState } from "react";
import { OutingApiError } from "../../lib/outings/api";
import {
	applyRead,
	ChatApi,
	chatBus,
	chatErrorText,
	checkDraft,
	deletedLabel,
	mergeMessages,
	newClientId,
	QUICK_REPLIES,
	receipt,
	type ChatMessage,
	type ChatPoint,
	type ChatRead,
	type SendBody,
} from "../../lib/outings/chat";

/**
 * «دردشة الطلعة» — the group chat panel inside the live outing sheet. Text,
 * quick replies and «موقعي» go over HTTP; new messages, deletions and read
 * markers arrive on the live socket (chatBus), with a slow poll as fallback.
 */
export function OutingChat({
	outingId,
	meId,
	isRTL,
	live,
	names,
	colors,
	othersCount,
	canModerate,
	myLocation,
	onShowPoint,
	onSeen,
}: {
	outingId: string;
	meId: string;
	isRTL: boolean;
	live: boolean;
	names: Map<string, string>;
	colors: Map<string, string>;
	othersCount: number;
	canModerate: boolean;
	myLocation: { lat: number; lng: number } | null;
	onShowPoint: (p: ChatPoint) => void;
	onSeen: () => void;
}) {
	const [messages, setMessages] = useState<ChatMessage[]>([]);
	const [reads, setReads] = useState<ChatRead[]>([]);
	const [hasMore, setHasMore] = useState(false);
	const [writable, setWritable] = useState(true);
	const [readOnlyReason, setReadOnlyReason] = useState<string | null>(null);
	const [draft, setDraft] = useState("");
	const [error, setError] = useState<string | null>(null);
	const [typing, setTyping] = useState<string | null>(null);
	const [loaded, setLoaded] = useState(false);
	const listRef = useRef<HTMLOListElement | null>(null);
	const lastReadSent = useRef(0);

	const lastSeq = messages.reduce((s, m) => (m.pending ? s : Math.max(s, m.seq)), 0);

	const load = useCallback(async () => {
		try {
			const p = await ChatApi.page(outingId, "group", { limit: 50 });
			setMessages((prev) => mergeMessages(prev, p.messages));
			setReads(p.reads);
			setHasMore((h) => (loaded ? h : p.has_more));
			setWritable(p.writable);
			setReadOnlyReason(p.read_only_reason);
			setLoaded(true);
		} catch (e) {
			if (!loaded) setError(e instanceof OutingApiError ? chatErrorText(e.code, isRTL) : chatErrorText("network", isRTL));
		}
	}, [outingId, isRTL, loaded]);

	useEffect(() => {
		void load();
		// first page once per outing
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [outingId]);

	/* No socket: catch up every 10 s. */
	useEffect(() => {
		if (live) return;
		const t = window.setInterval(() => void load(), 10_000);
		return () => window.clearInterval(t);
	}, [live, load]);

	useEffect(
		() =>
			chatBus.on((e) => {
				if (e.type === "chat_message" || e.type === "chat_deleted") {
					if (e.message.conv !== "group") return;
					setMessages((prev) => mergeMessages(prev, [e.message]));
				} else if (e.type === "chat_read" && e.conv === "group") {
					setReads((r) => applyRead(r, e.user_id, e.seq));
				} else if (e.type === "chat_typing" && e.conv === "group" && e.user_id !== meId) {
					setTyping(e.on ? e.user_id : null);
				}
			}),
		[meId],
	);

	useEffect(() => {
		if (!typing) return;
		const t = window.setTimeout(() => setTyping(null), 5_000);
		return () => window.clearTimeout(t);
	}, [typing]);

	/* Seen while the panel is open → read marker (✓✓ for the others). */
	useEffect(() => {
		if (!lastSeq || lastSeq <= lastReadSent.current) return;
		lastReadSent.current = lastSeq;
		onSeen();
		void ChatApi.read(outingId, "group", lastSeq).catch(() => (lastReadSent.current = 0));
	}, [lastSeq, outingId, onSeen]);

	useEffect(() => {
		const el = listRef.current;
		if (el) el.scrollTop = el.scrollHeight;
	}, [messages.length]);

	async function older() {
		const first = messages.find((m) => !m.pending);
		if (!first) return;
		try {
			const p = await ChatApi.page(outingId, "group", { before: first.seq, limit: 50 });
			setMessages((prev) => mergeMessages(prev, p.messages));
			setHasMore(p.has_more);
		} catch {
			/* keep what we have */
		}
	}

	async function send(body: Omit<SendBody, "client_id">, retryOf?: ChatMessage) {
		const client_id = retryOf?.client_id || newClientId();
		const local: ChatMessage = {
			id: `local-${client_id}`,
			outing_id: outingId,
			seq: 0,
			conv: "group",
			sender_id: meId,
			recipient_id: null,
			sender_name: names.get(meId) || null,
			client_id,
			kind: body.kind,
			text: body.text ?? null,
			point: body.point ?? null,
			created_at: retryOf?.created_at || new Date().toISOString(),
			deleted: false,
			deleted_by: null,
			pending: "sending",
		};
		setMessages((prev) => mergeMessages(prev, [local]));
		setError(null);
		try {
			const r = await ChatApi.send(outingId, "group", { ...body, client_id });
			setMessages((prev) => mergeMessages(prev, [r.message]));
		} catch (e) {
			const code = e instanceof OutingApiError ? e.code : "network";
			setMessages((prev) => mergeMessages(prev, [{ ...local, pending: "failed" }]));
			setError(chatErrorText(code, isRTL));
			if (code === "outing_ended" || code === "chat_read_only") setWritable(false);
		}
	}

	function submit() {
		const c = checkDraft(draft);
		if (!c.ok) {
			if (c.reason === "too_long") setError(chatErrorText("text_too_long", isRTL));
			return;
		}
		setDraft("");
		void send({ kind: "text", text: c.text });
	}

	async function remove(m: ChatMessage) {
		try {
			const r = await ChatApi.remove(outingId, m.id);
			setMessages((prev) => mergeMessages(prev, [r.message]));
		} catch (e) {
			setError(chatErrorText(e instanceof OutingApiError ? e.code : "network", isRTL));
		}
	}

	const tooLong = [...draft].length > 1000;

	return (
		<div className="sary-o-panel sary-o-chat" data-testid="outing-chat" dir={isRTL ? "rtl" : "ltr"}>
			<h3 className="sary-o-chat-title">{isRTL ? "دردشة الطلعة" : "Trip chat"}</h3>
			{hasMore ? (
				<button type="button" className="sary-o-secondary" onClick={() => void older()} data-testid="outing-chat-older">
					{isRTL ? "رسائل أقدم" : "Older messages"}
				</button>
			) : null}
			<ol className="sary-o-chat-list" ref={listRef} data-testid="outing-chat-list" aria-live="polite">
				{loaded && !messages.length ? <li className="sary-o-note">{isRTL ? "ما فيه رسائل بعد. قل هلا 👋" : "No messages yet."}</li> : null}
				{messages.map((m) => {
					const mine = m.sender_id === meId;
					const color = colors.get(m.sender_id) || "#9aa5ad";
					const rc = receipt(m, meId, reads, othersCount);
					return (
						<li
							key={m.client_id ? `${m.sender_id}:${m.client_id}` : m.id}
							className={`sary-o-chat-msg${mine ? " is-mine" : ""}${m.deleted ? " is-deleted" : ""}`}
							style={{ borderInlineStartColor: color }}
							data-testid="outing-chat-message"
							data-seq={m.seq || undefined}
							data-pending={m.pending || undefined}
						>
							{!mine ? (
								<strong className="sary-o-chat-who" style={{ color }}>
									{names.get(m.sender_id) || m.sender_name || (isRTL ? "عضو سابق" : "Former member")}
								</strong>
							) : null}
							{m.deleted ? (
								<em data-testid="outing-chat-deleted">{deletedLabel(m, isRTL)}</em>
							) : m.kind === "location" && m.point ? (
								<button type="button" className="sary-o-chat-point" onClick={() => onShowPoint(m.point!)} data-testid="outing-chat-point">
									📍 {m.point.label || (isRTL ? "موقع على الخريطة" : "A point on the map")}
								</button>
							) : (
								<span dir="auto" style={{ whiteSpace: "pre-wrap" }}>
									{m.text}
								</span>
							)}
							<small className="sary-o-chat-meta">
								{new Date(m.created_at).toLocaleTimeString(isRTL ? "ar-SA" : "en-GB", { hour: "2-digit", minute: "2-digit" })}
								{rc === "read" ? <span data-testid="outing-chat-receipt" data-state="read"> ✓✓</span> : null}
								{rc === "sent" ? <span data-testid="outing-chat-receipt" data-state="sent"> ✓</span> : null}
								{rc === "sending" ? <span data-testid="outing-chat-receipt" data-state="sending"> …</span> : null}
								{rc === "failed" ? (
									<button type="button" className="sary-o-link-btn" onClick={() => void send({ kind: m.kind, text: m.text ?? undefined, point: m.point ?? undefined }, m)} data-testid="outing-chat-retry">
										{isRTL ? " لم تُرسل — أعد" : " Not sent — retry"}
									</button>
								) : null}
								{!m.deleted && !m.pending && (mine || canModerate) ? (
									<button type="button" className="sary-o-link-btn" onClick={() => void remove(m)} data-testid="outing-chat-delete" aria-label={isRTL ? "احذف الرسالة" : "Delete message"}>
										{isRTL ? " حذف" : " Delete"}
									</button>
								) : null}
							</small>
						</li>
					);
				})}
			</ol>
			{typing ? <p className="sary-o-note" data-testid="outing-chat-typing">{(names.get(typing) || "") + (isRTL ? " يكتب…" : " is typing…")}</p> : null}
			{error ? <p className="sary-o-error" role="alert" data-testid="outing-chat-error">{error}</p> : null}
			{writable ? (
				<>
					<div className="sary-o-chat-quick" data-testid="outing-chat-quick">
						{QUICK_REPLIES.map((q) => (
							<button key={q} type="button" className="sary-layer-chip" onClick={() => void send({ kind: "quick", text: q })}>
								{q}
							</button>
						))}
						{myLocation ? (
							<button type="button" className="sary-layer-chip" onClick={() => void send({ kind: "location", point: { ...myLocation, label: null } })} data-testid="outing-chat-share-location">
								📍 {isRTL ? "موقعي" : "My location"}
							</button>
						) : null}
					</div>
					<form
						className="sary-o-chat-compose"
						onSubmit={(e) => {
							e.preventDefault();
							submit();
						}}
					>
						<textarea
							value={draft}
							onChange={(e) => setDraft(e.target.value)}
							onKeyDown={(e) => {
								if (e.key === "Enter" && !e.shiftKey) {
									e.preventDefault();
									submit();
								}
							}}
							rows={2}
							dir="auto"
							placeholder={isRTL ? "اكتب رسالة للطلعة…" : "Message the group…"}
							aria-invalid={tooLong || undefined}
							data-testid="outing-chat-input"
						/>
						<button type="submit" className="sary-o-primary" disabled={!draft.trim() || tooLong} data-testid="outing-chat-send">
							{isRTL ? "أرسل" : "Send"}
						</button>
					</form>
				</>
			) : (
				<p className="sary-o-note" data-testid="outing-chat-readonly">
					{chatErrorText(readOnlyReason || "outing_ended", isRTL)}
				</p>
			)}
		</div>
	);
}
