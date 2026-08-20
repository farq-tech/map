import type { MapSort, MapViewMode } from "../../routes/map";

export default function FarqViewSortBar({
	view,
	onView,
	sort,
	onSort,
	isRTL,
	nearReady,
	cheapReady,
	hideViewToggle = false,
}: {
	view: MapViewMode;
	onView: (view: MapViewMode) => void;
	sort: MapSort;
	onSort: (sort: MapSort) => void;
	isRTL: boolean;
	nearReady: boolean;
	cheapReady: boolean;
	/** On the phone the list is the sheet; there is no "view" to toggle. */
	hideViewToggle?: boolean;
}) {
	return (
		<div className="farq-view-sort" data-testid="farq-view-sort">
			{hideViewToggle ? null : (
			<div
				className="farq-view-toggle"
				role="tablist"
				aria-label={isRTL ? "طريقة العرض" : "View"}
				data-testid="farq-view-toggle"
			>
				<button
					type="button"
					role="tab"
					aria-selected={view === "list"}
					data-testid="farq-view-list"
					className={`farq-view-toggle-btn ${view === "list" ? "is-on" : ""}`}
					onClick={() => onView("list")}
				>
					{isRTL ? "قائمة" : "List"}
				</button>
				<button
					type="button"
					role="tab"
					aria-selected={view === "map"}
					data-testid="farq-view-map"
					className={`farq-view-toggle-btn ${view === "map" ? "is-on" : ""}`}
					onClick={() => onView("map")}
				>
					{isRTL ? "خريطة" : "Map"}
				</button>
			</div>
			)}
			<div
				className="farq-sort-rail"
				role="group"
				aria-label={isRTL ? "ترتيب الفرص" : "Sort opportunities"}
				data-testid="farq-sort-rail"
			>
				<button
					type="button"
					aria-pressed={sort === "near"}
					data-testid="farq-sort-near"
					title={
						nearReady
							? undefined
							: isRTL
								? "الأقرب يحتاج موقعك المرصود"
								: "Nearest needs your observed location"
					}
					className={`farq-map-chip ${sort === "near" ? "is-on" : ""}`}
					/* Asking for location belongs to whoever owns `onSort` — it already
					 * requests a fix when "near" is picked without one, and the drawer
					 * reaches the same handler. Calling it here too fired the intent twice. */
					onClick={() => onSort("near")}
				>
					{isRTL ? "الأقرب" : "Nearest"}
				</button>
				<button
					type="button"
					aria-pressed={sort === "gap"}
					data-testid="farq-sort-gap"
					className={`farq-map-chip ${sort === "gap" ? "is-on" : ""}`}
					onClick={() => onSort("gap")}
				>
					{isRTL ? "أكبر فرق" : "Biggest gap"}
				</button>
				<button
					type="button"
					aria-pressed={sort === "cheap"}
					data-testid="farq-sort-cheap"
					title={
						cheapReady
							? undefined
							: isRTL
								? "الترتيب يحتاج سعر أرخص مرصود"
								: "Needs an observed cheapest price"
					}
					className={`farq-map-chip ${sort === "cheap" ? "is-on" : ""}`}
					onClick={() => onSort("cheap")}
				>
					{isRTL ? "الأرخص" : "Cheapest"}
				</button>
			</div>
		</div>
	);
}
