import { useEffect, useRef } from "react";
import { localizeDigitString } from "../../lib/formatPrice";
import { formatObservedDistance } from "../../lib/farqOpportunities";
import type { OpportunityRow } from "../../lib/farqOpportunities";
import { getProviderLabel } from "../../lib/platformLogos";

function ProviderPriceLine({
	kind,
	provider,
	price,
	isRTL,
}: {
	kind: "cheap" | "expensive";
	provider?: string | null;
	price?: number | null;
	isRTL: boolean;
}) {
	if (!provider && price == null) return null;
	/* A price without a provider is still observed — name it as a price, not as an unknown app. */
	const name = provider ? getProviderLabel(provider, { isRTL }) || provider : "";
	const label =
		kind === "cheap"
			? isRTL
				? "الأرخص"
				: "Cheapest"
			: provider
				? isRTL
					? "الأغلى"
					: "Highest"
				: isRTL
					? "أعلى سعر مرصود"
					: "Highest observed price";
	const amount =
		price != null
			? `${localizeDigitString(String(Math.round(price)), isRTL)} ${isRTL ? "ر.س" : "SAR"}`
			: "";
	return (
		<p
			className={`farq-opportunity-line farq-opportunity-line--${kind}`}
			data-testid={`farq-opportunity-${kind}`}
		>
			{label}
			{name ? `: ${name}` : ""}
			{amount ? ` — ${amount}` : ""}
		</p>
	);
}

export function FarqOpportunityCard({
	row,
	isRTL,
	selected,
	onSelect,
}: {
	row: OpportunityRow;
	isRTL: boolean;
	selected?: boolean;
	onSelect: (row: OpportunityRow) => void;
}) {
	const gap = localizeDigitString(String(Math.round(row.amount)), isRTL);
	const title =
		row.productName || row.name || (isRTL ? "فرصة مرصودة" : "Observed opportunity");
	const distance = formatObservedDistance(row.distanceMeters, isRTL);
	return (
		<button
			type="button"
			className={`farq-opportunity-card ${selected ? "is-selected" : ""}`}
			data-testid="intelligence-map-top-saving"
			data-opportunity-id={row.placeId}
			data-place-id={row.placeId}
			aria-current={selected ? "true" : undefined}
			onClick={() => onSelect(row)}
		>
			<p className="farq-opportunity-gap">
				🔥 {gap} {isRTL ? "ر.س فرق" : "SAR gap"}
			</p>
			<p className="farq-opportunity-item">{title}</p>
			{row.productName && row.name && row.name !== row.productName ? (
				<p className="farq-opportunity-place">{row.name}</p>
			) : null}
			<ProviderPriceLine
				kind="cheap"
				provider={row.cheapestProvider}
				price={row.cheapestPrice}
				isRTL={isRTL}
			/>
			<ProviderPriceLine
				kind="expensive"
				provider={row.expensiveProvider}
				price={row.expensivePrice}
				isRTL={isRTL}
			/>
			{/* How much evidence is under the number, and whether the dish is a
			    dinner order at all — a 63 SAR gap resting on one comparison and one
			    resting on 221 used to look identical on the card. */}
			<p className="farq-opportunity-meta">
				{row.categoryGap != null && row.categoryLabel ? (
					<span className="farq-opportunity-tag is-category">
						{isRTL
							? `${row.categoryLabel}: ${localizeDigitString(String(row.categoryGap), true)} ر.س`
							: `${row.categoryLabel}: ${row.categoryGap} SAR`}
					</span>
				) : null}
				{row.demoteReason ? (
					<span className="farq-opportunity-tag">
						{row.demoteReason === "share"
							? isRTL
								? "طلب مشاركة"
								: "Sharing item"
							: isRTL
								? "منتج معبأ"
								: "Packaged product"}
					</span>
				) : null}
				{row.comparisons ? (
					<span>
						{isRTL
							? `من ${localizeDigitString(String(row.comparisons), true)} ${row.comparisons === 1 ? "مقارنة" : "مقارنة"}`
							: `from ${row.comparisons} comparison${row.comparisons === 1 ? "" : "s"}`}
					</span>
				) : null}
				{row.branchCount && row.branchCount > 1 ? (
					<span>
						{isRTL
							? `${localizeDigitString(String(row.branchCount), true)} فروع`
							: `${row.branchCount} branches`}
					</span>
				) : null}
				{distance ? <span className="farq-opportunity-distance">{distance}</span> : null}
			</p>
		</button>
	);
}

export default function FarqOpportunityList({
	rows,
	isRTL,
	selectedPlaceId,
	onSelect,
	empty,
	countLabel,
}: {
	rows: OpportunityRow[];
	isRTL: boolean;
	selectedPlaceId?: string;
	onSelect: (row: OpportunityRow) => void;
	empty: boolean;
	countLabel?: string;
}) {
	const listRef = useRef<HTMLDivElement | null>(null);

	useEffect(() => {
		if (!selectedPlaceId || !listRef.current) return;
		const node = listRef.current.querySelector(
			`[data-opportunity-id="${CSS.escape(selectedPlaceId)}"]`,
		);
		if (node instanceof HTMLElement) {
			node.scrollIntoView({ block: "nearest", behavior: "smooth" });
		}
	}, [selectedPlaceId, rows]);

	return (
		<div
			ref={listRef}
			className="farq-opportunity-list"
			data-testid="farq-opportunity-list"
		>
			{countLabel ? (
				<p className="farq-opportunity-count">{countLabel}</p>
			) : null}
			{empty ? (
				<div
					className="farq-opportunity-empty"
					data-testid="intelligence-map-empty"
				>
					<p className="text-[16px] font-extrabold text-brand-900">
						{isRTL
							? "ما رصدنا فرق يستحق حولك بعد"
							: "No worthwhile gap observed around you yet"}
					</p>
				</div>
			) : (
				<ul className="farq-opportunity-ul">
					{rows.map((row) => (
						<li key={row.placeId}>
							<FarqOpportunityCard
								row={row}
								isRTL={isRTL}
								selected={row.placeId === selectedPlaceId}
								onSelect={onSelect}
							/>
						</li>
					))}
				</ul>
			)}
		</div>
	);
}
