import { localizeDigitString } from "../../lib/formatPrice";
import type { OpportunityRow } from "../../lib/farqOpportunities";
import FarqOpportunityList from "./FarqOpportunityList";

export function CoordinateStackBanner({
	count,
	isRTL,
	onOpen,
}: {
	count: number;
	isRTL: boolean;
	onOpen: () => void;
}) {
	if (count < 2) return null;
	const n = localizeDigitString(String(count), isRTL);
	return (
		<button
			type="button"
			className="w-full border-b border-[#e6eef0] bg-[#f4f8f8] px-5 py-3 text-start text-[13px] font-bold text-brand-900"
			data-testid="map-coordinate-stack-back"
			onClick={onOpen}
		>
			{isRTL
				? `${n} أماكن على نفس الإحداثيات — اعرض القائمة`
				: `${count} places at this pin — show the list`}
		</button>
	);
}

/**
 * Same-coordinate pile: one pin, every restaurant kept as its own row.
 * Never a merged identity.
 */
export default function StackedPlacePicker({
	rows,
	isRTL,
	onSelect,
	onClose,
}: {
	rows: OpportunityRow[];
	isRTL: boolean;
	onSelect: (row: OpportunityRow) => void;
	onClose: () => void;
}) {
	const n = localizeDigitString(String(rows.length), isRTL);
	return (
		<div className="flex min-h-0 flex-1 flex-col" data-testid="map-coordinate-stack">
			<div className="flex items-start justify-between gap-3 border-b border-[#e6eef0] px-5 py-4">
				<div className="min-w-0">
					<h2 className="text-[16px] font-bold text-brand-900">
						{isRTL ? `${n} أماكن على نفس الإحداثيات` : `${rows.length} places at this pin`}
					</h2>
					<p className="mt-1 text-[12px] font-bold text-[#5c6d6d]">
						{isRTL
							? "نفس النقطة الجغرافية — كل مطعم هوية مستقلة، ما ندمجهم."
							: "Same coordinates — each restaurant stays its own identity. Never merged."}
					</p>
				</div>
				<button
					type="button"
					className="shrink-0 rounded-full px-3 py-1 text-[12px] font-bold text-brand-900 hover:bg-[#e6eef0]"
					onClick={onClose}
				>
					{isRTL ? "إغلاق" : "Close"}
				</button>
			</div>
			<div className="min-h-0 flex-1 overflow-y-auto p-3">
				<FarqOpportunityList
					rows={rows}
					isRTL={isRTL}
					onSelect={onSelect}
					empty={rows.length === 0}
				/>
			</div>
		</div>
	);
}
