/**
 * Floating map interpretation tool — not a ChatGPT page.
 * Asks Farq’s comparison source (named place / city / near you).
 * Viewport bbox is an optional hint, not a hard box.
 */
import { MessageCircle, Send, X } from "lucide-react";
import { useCallback, useState } from "react";
import FarqBrandMark from "../FarqBrandMark";

const CHIPS = [
	{ id: "biggest", text: "وين أكبر فرق؟" },
	{ id: "cheap", text: "أرخص مطعم حولي؟" },
	{ id: "grocery", text: "وين أوفر بقالة؟" },
	{ id: "save", text: "وش أقدر أوفر الآن؟" },
	{ id: "near", text: "وش أفضل فرصة قريبة مني؟" },
] as const;

type ChatLine = { role: "user" | "assistant"; text: string };

export default function MapAskChat({
	isRTL,
	language,
	getViewportBbox,
	selectedPlaceName,
	userLat,
	userLng,
}: {
	isRTL: boolean;
	language: "ar" | "en";
	getViewportBbox: () => string;
	selectedPlaceName?: string;
	userLat?: number;
	userLng?: number;
}) {
	const [open, setOpen] = useState(false);
	const [draft, setDraft] = useState("");
	const [busy, setBusy] = useState(false);
	const [lines, setLines] = useState<ChatLine[]>([]);

	const send = useCallback(
		async (text: string) => {
			const message = text.trim();
			if (!message || busy) return;
			setDraft("");
			setLines((cur) => [...cur, { role: "user", text: message }]);
			setBusy(true);
			try {
				const res = await fetch("/api/chat", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({
						message,
						bbox: getViewportBbox() || undefined,
						selected_place: selectedPlaceName || undefined,
						language,
						user_lat: Number.isFinite(userLat) ? userLat : undefined,
						user_lng: Number.isFinite(userLng) ? userLng : undefined,
					}),
				});
				const body: {
					text?: string;
					message_ar?: string;
					error?: string;
				} | null = await res.json().catch(() => null);
				const reply =
					(body && (body.text || body.message_ar)) ||
					(res.status === 503
						? "المحادثة غير مفعّلة حالياً — مفتاح النموذج غير مضبوط على الخادم."
						: "تعذر تفسير الخريطة الآن. الخريطة نفسها ما زالت تعمل.");
				setLines((cur) => [...cur, { role: "assistant", text: reply }]);
			} catch {
				setLines((cur) => [
					...cur,
					{
						role: "assistant",
						text: "تعذر تفسير الخريطة الآن. الخريطة نفسها ما زالت تعمل.",
					},
				]);
			} finally {
				setBusy(false);
			}
		},
		[busy, getViewportBbox, selectedPlaceName, language, userLat, userLng],
	);

	return (
		<div
			className={`farq-map-ask ${open ? "is-open" : ""}`}
			data-testid="farq-map-ask"
			dir="rtl"
		>
			{open ? (
				<div className="farq-map-ask-panel" data-testid="farq-map-ask-panel">
					<header className="farq-map-ask-head">
						<FarqBrandMark variant="circle" size={22} />
						<h2>اسأل فرق</h2>
						<button
							type="button"
							className="farq-map-ask-close"
							aria-label={isRTL ? "إغلاق" : "Close"}
							onClick={() => setOpen(false)}
						>
							<X className="size-3.5" />
						</button>
					</header>
					<div className="farq-map-ask-chips" data-testid="farq-map-ask-chips">
						{CHIPS.map((chip) => (
							<button
								key={chip.id}
								type="button"
								className="farq-map-ask-chip"
								disabled={busy}
								onClick={() => void send(chip.text)}
							>
								{chip.text}
							</button>
						))}
					</div>
					<div className="farq-map-ask-thread" aria-live="polite">
						{lines.length === 0 ? (
							<p className="farq-map-ask-hint">
								نبحث من مصدر مقارنة فرق — مو بس الشاشة، وبدون اختراع أسعار.
							</p>
						) : (
							lines.map((line, i) => (
								<p
									key={`${line.role}-${i}`}
									className={`farq-map-ask-bubble farq-map-ask-bubble--${line.role}`}
								>
									{line.text}
								</p>
							))
						)}
						{busy ? (
							<p className="farq-map-ask-hint">نقرأ الفروقات من المصدر…</p>
						) : null}
					</div>
					<form
						className="farq-map-ask-form"
						onSubmit={(e) => {
							e.preventDefault();
							void send(draft);
						}}
					>
						<input
							value={draft}
							onChange={(e) => setDraft(e.target.value)}
							placeholder="وش تبي تعرف؟ أرخص برجر في المغرزات…"
							aria-label="اسأل فرق"
							data-testid="farq-map-ask-input"
							disabled={busy}
						/>
						<button
							type="submit"
							disabled={busy || !draft.trim()}
							aria-label="إرسال"
							data-testid="farq-map-ask-send"
						>
							<Send className="size-3.5" />
						</button>
					</form>
				</div>
			) : (
				<button
					type="button"
					className="farq-map-ask-fab"
					data-testid="farq-map-ask-fab"
					aria-label="اسأل فرق"
					onClick={() => setOpen(true)}
				>
					<MessageCircle className="size-4" />
				</button>
			)}
		</div>
	);
}
