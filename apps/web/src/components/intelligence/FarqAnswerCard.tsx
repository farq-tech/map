/**
 * The copilot's answer, where the results live: above the list, with the rows
 * it was built from as tappable cards and the natural follow-ups as chips.
 * Nothing here is text the map cannot also show — every cited place is a row.
 */
import { Sparkles, X } from "lucide-react";
import type { OpportunityRow } from "../../lib/farqOpportunities";
import { FOLLOW_UPS, type CopilotResponse, type CopilotRow } from "../../lib/farqAsk";
import { FarqOpportunityCard } from "./FarqOpportunityList";

export function rowToOpportunity(r: CopilotRow): OpportunityRow {
	return {
		placeId: r.place_id,
		name: r.name || "",
		amount: r.gap || 0,
		lat: r.lat,
		lng: r.lng,
		cheapestPrice: r.cheapest_price,
		expensivePrice: r.expensive_price,
		productName: r.product_name,
		cheapestProvider: r.cheapest_provider_id,
		expensiveProvider: r.expensive_provider_id,
		distanceMeters: r.distance_m ?? null,
	};
}

export default function FarqAnswerCard({
	question,
	response,
	busy,
	error,
	isRTL,
	onAsk,
	onSelect,
	onClose,
}: {
	question: string;
	response: CopilotResponse | null;
	busy: boolean;
	error: string | null;
	isRTL: boolean;
	onAsk: (text: string) => void;
	onSelect: (row: OpportunityRow) => void;
	onClose: () => void;
}) {
	const rows = (response?.results || []).filter((r) => r.gap);
	const lines = String(response?.answer || "").split("\n").filter(Boolean);
	return (
		<section className="farq-answer" data-testid="farq-answer" aria-live="polite">
			<header className="farq-answer-head">
				<span className="farq-answer-kicker">
					<Sparkles className="size-3.5" aria-hidden />
					{isRTL ? "اسأل فرق" : "Ask Farq"}
				</span>
				<button
					type="button"
					className="farq-answer-close"
					aria-label={isRTL ? "إغلاق الإجابة" : "Close answer"}
					onClick={onClose}
				>
					<X className="size-3.5" />
				</button>
			</header>
			<p className="farq-answer-question">{question}</p>
			{busy ? (
				<p className="farq-answer-busy">{isRTL ? "نقرأ الفروقات من المصدر…" : "Reading observed gaps…"}</p>
			) : error ? (
				<p className="farq-answer-error">{error}</p>
			) : (
				<>
					<div className="farq-answer-text">
						{lines.slice(0, rows.length ? 1 : 6).map((line, i) => (
							<p key={i}>{line}</p>
						))}
					</div>
					{rows.length ? (
						<ul className="farq-answer-rows" data-testid="farq-answer-rows">
							{rows.slice(0, 5).map((r) => (
								<li key={r.place_id}>
									<FarqOpportunityCard row={rowToOpportunity(r)} isRTL={isRTL} onSelect={onSelect} />
								</li>
							))}
						</ul>
					) : null}
					<div className="farq-answer-chips" role="group" aria-label={isRTL ? "أسئلة متابعة" : "Follow-ups"}>
						{FOLLOW_UPS.map((chip) => (
							<button
								key={chip.id}
								type="button"
								className="farq-map-chip"
								onClick={() => onAsk(isRTL ? chip.ar : chip.en)}
							>
								{isRTL ? chip.ar : chip.en}
							</button>
						))}
					</div>
					<p className="farq-answer-foot">
						{isRTL
							? "كل رقم هنا من مقارنة مرصودة — بدون تخمين."
							: "Every number here is an observed comparison — no guessing."}
					</p>
				</>
			)}
		</section>
	);
}
