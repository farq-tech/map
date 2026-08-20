/**
 * Isolated mobile presentation layer for the Farq Price Opportunity Map.
 * Floats over the full-screen Mapbox canvas — never a layout slot under the map.
 * Desktop chrome stays in IntelligenceMapSplit.
 */
import {
	ChevronLeft,
	ChevronRight,
	CircleDot,
	Info,
	Menu,
	Search,
	X,
} from "lucide-react";
import {
	useRef,
	useState,
	type PointerEvent as ReactPointerEvent,
} from "react";
import { localizeCity } from "../../lib/cityNames";
import { localizeDigitString } from "../../lib/formatPrice";
import { getProviderLabel } from "../../lib/platformLogos";
import type { OpportunityRow } from "../../lib/farqOpportunities";
import type { MapSort, MapViewMode } from "../../routes/map";
import { ProviderLogoMark } from "../ProviderLogoMark";
import type { MapboxBasemap } from "../../lib/mapboxAccess";
import type {
	IntelligenceCategory,
	IntelligenceCategoryGroup,
	IntelligenceCityCoverage,
} from "../../services/intelligenceService";
import FarqBrandMark from "../FarqBrandMark";
import FarqViewSortBar from "./FarqViewSortBar";
import { FarqOpportunityCard } from "./FarqOpportunityList";

export type ExploreRadius = "hawally" | "1km" | "3km" | "5km" | "city";
export type FilterRailId = "gaps" | "restaurants" | "grocery" | "cheapest";
export type SheetSnap = "closed" | "peek" | "expanded";
export type MapLayerId =
	| "opportunities"
	| "restaurants"
	| "providers"
	| "prices"
	| "delivery";

export type ExploreSaving = OpportunityRow;

export const EXPLORE_ZOOM: Record<ExploreRadius, number> = {
	"1km": 15.6,
	"3km": 14.4,
	"5km": 13.6,
	hawally: 13.8,
	city: 11.8,
};

const DISCOVERY_CHIPS = [
	{ id: "burger", q: "برجر", labelAr: "برجر", labelEn: "Burger" },
	{ id: "pizza", q: "بيتزا", labelAr: "بيتزا", labelEn: "Pizza" },
	{ id: "sushi", q: "سوشي", labelAr: "سوشي", labelEn: "Sushi" },
	{ id: "coffee", q: "قهوة", labelAr: "قهوة", labelEn: "Coffee" },
	{ id: "grocery", category: "grocery", labelAr: "بقالة", labelEn: "Grocery" },
	{ id: "around", radius: "hawally" as const, labelAr: "حولي", labelEn: "Around you" },
	{ id: "gaps", rail: "gaps" as const, labelAr: "أكبر فرق", labelEn: "Top gaps" },
	{ id: "cheap", rail: "cheapest" as const, labelAr: "الأرخص", labelEn: "Cheapest" },
	{ id: "delivery", q: "فرق التوصيل", labelAr: "فرق التوصيل", labelEn: "Delivery gap" },
] as const;

function ProviderCompareLine({
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
	const heading =
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
			? `${localizeDigitString(String(price), isRTL)} ${isRTL ? "ر.س" : "SAR"}`
			: "";
	return (
		<div
			className={`farq-map-aha-app farq-map-aha-app--${kind}`}
			data-testid={`intelligence-map-aha-${kind}`}
		>
			{provider ? (
				<ProviderLogoMark
					provider={provider}
					label={name}
					isRTL={isRTL}
					size={28}
					rounded="md"
					tintedFallback
				/>
			) : null}
			<div className="min-w-0">
				<p className="text-[10px] font-extrabold">{heading}</p>
				<p className="truncate text-[12px] font-black text-brand-900">
					{name && amount ? `${name} · ${amount}` : name || amount}
				</p>
			</div>
		</div>
	);
}

export default function FarqExploreChrome({
	isRTL,
	language,
	languageSwitching,
	onToggleLanguage,
	mapQuery,
	onMapQueryChange,
	onSearchSubmit,
	rail: _rail,
	onRail,
	categoryId,
	onApplyCategory,
	majorGapsOnly,
	onToggleMajorGaps,
	drawerOpen,
	onDrawerOpenChange,
	cities,
	city,
	onCityChange,
	categoryGroups,
	gisHoodsOn,
	onToggleGisHoods,
	layers,
	onToggleLayer,
	exploreRadius,
	onExploreRadius,
	aroundMax,
	topSavings,
	sheetSnap,
	onSheetSnap,
	placesFetching,
	scanHint,
	hasViewportPlaces,
	placesReady,
	chromeHidden,
	searchFocused,
	onSearchFocused,
	onLocate,
	locateBusy = false,
	onFocusPlace,
	showHereHint: _showHereHint,
	leftUserLocation = false,
	placeSelected,
	cheapestReady = false,
	nearReady = false,
	view,
	onView,
	sort,
	onSort,
	onNeedLocation,
	basemap,
	onBasemapChange,
	legendOpen,
	onLegendOpenChange,
}: {
	isRTL: boolean;
	language: string;
	languageSwitching: boolean;
	onToggleLanguage: () => void;
	mapQuery: string;
	onMapQueryChange: (q: string) => void;
	onSearchSubmit: (q: string) => void;
	rail: FilterRailId;
	onRail: (id: FilterRailId) => void;
	categoryId: string;
	onApplyCategory: (id: string) => void;
	majorGapsOnly: boolean;
	onToggleMajorGaps: () => void;
	drawerOpen: boolean;
	onDrawerOpenChange: (open: boolean) => void;
	cities: IntelligenceCityCoverage[];
	city: string;
	onCityChange: (city: string) => void;
	categoryGroups: IntelligenceCategoryGroup[];
	gisHoodsOn: boolean;
	onToggleGisHoods: () => void;
	layers: Record<MapLayerId, boolean>;
	onToggleLayer: (id: MapLayerId) => void;
	exploreRadius: ExploreRadius;
	onExploreRadius: (id: ExploreRadius) => void;
	aroundMax: ExploreSaving | null;
	topSavings: ExploreSaving[];
	sheetSnap: SheetSnap;
	onSheetSnap: (snap: SheetSnap) => void;
	placesFetching: boolean;
	scanHint: "searching" | "ready" | null;
	hasViewportPlaces: boolean;
	placesReady: boolean;
	chromeHidden: boolean;
	searchFocused: boolean;
	onSearchFocused: (focused: boolean) => void;
	onLocate: () => void;
	locateBusy?: boolean;
	onFocusPlace: (row: ExploreSaving) => void;
	showHereHint: boolean;
	leftUserLocation?: boolean;
	placeSelected: boolean;
	cheapestReady?: boolean;
	nearReady?: boolean;
	view: MapViewMode;
	onView: (view: MapViewMode) => void;
	sort: MapSort;
	onSort: (sort: MapSort) => void;
	onNeedLocation?: () => void;
	basemap: MapboxBasemap;
	onBasemapChange: (kind: MapboxBasemap) => void;
	legendOpen: boolean;
	onLegendOpenChange: (open: boolean) => void;
}) {
	const [drawerDragX, setDrawerDragX] = useState(0);
	const [mapOptionsOpen, setMapOptionsOpen] = useState(false);
	const drawerDragRef = useRef<{
		pointerId: number;
		startX: number;
	} | null>(null);
	const sheetDragRef = useRef<{
		pointerId: number;
		startX: number;
	} | null>(null);

	const applyDiscovery = (chip: (typeof DISCOVERY_CHIPS)[number]) => {
		if ("radius" in chip && chip.radius) {
			onExploreRadius(chip.radius);
			return;
		}
		if ("rail" in chip && chip.rail) {
			onRail(chip.rail);
			return;
		}
		if ("category" in chip && chip.category) {
			onApplyCategory(chip.category);
			return;
		}
		if ("q" in chip && chip.q) {
			onMapQueryChange(chip.q);
			onSearchSubmit(chip.q);
		}
	};

	const onDrawerPointerDown = (ev: ReactPointerEvent<HTMLElement>) => {
		ev.currentTarget.setPointerCapture(ev.pointerId);
		drawerDragRef.current = { pointerId: ev.pointerId, startX: ev.clientX };
		setDrawerDragX(0);
	};
	const onDrawerPointerMove = (ev: ReactPointerEvent<HTMLElement>) => {
		const drag = drawerDragRef.current;
		if (!drag || drag.pointerId !== ev.pointerId) return;
		const dx = ev.clientX - drag.startX;
		const closing = isRTL ? dx : -dx;
		setDrawerDragX(Math.max(0, closing));
	};
	const onDrawerPointerUp = (ev: ReactPointerEvent<HTMLElement>) => {
		const drag = drawerDragRef.current;
		drawerDragRef.current = null;
		if (!drag || drag.pointerId !== ev.pointerId) return;
		const dx = ev.clientX - drag.startX;
		const closing = isRTL ? dx : -dx;
		setDrawerDragX(0);
		if (closing > 64) onDrawerOpenChange(false);
	};

	const onSheetPointerDown = (ev: ReactPointerEvent<HTMLElement>) => {
		ev.currentTarget.setPointerCapture(ev.pointerId);
		sheetDragRef.current = {
			pointerId: ev.pointerId,
			startX: ev.clientX,
		};
	};
	const onSheetPointerMove = (ev: ReactPointerEvent<HTMLElement>) => {
		if (!sheetDragRef.current || sheetDragRef.current.pointerId !== ev.pointerId) {
			return;
		}
	};
	const onSheetPointerUp = (ev: ReactPointerEvent<HTMLElement>) => {
		const drag = sheetDragRef.current;
		sheetDragRef.current = null;
		if (!drag || drag.pointerId !== ev.pointerId) return;
		const dx = ev.clientX - drag.startX;
		const closing = isRTL ? dx : -dx;
		if (Math.abs(dx) < 12) {
			if (sheetSnap === "peek") onSheetSnap("expanded");
			else if (sheetSnap === "closed") onSheetSnap("peek");
			return;
		}
		if (closing > 48) {
			onSheetSnap("closed");
		}
	};

	const emptyViewport =
		placesReady &&
		!placesFetching &&
		!scanHint &&
		hasViewportPlaces === false &&
		topSavings.length === 0;
	const hideFloat = chromeHidden && !drawerOpen && !searchFocused && sheetSnap !== "expanded";

	return (
		<div
			className={`farq-explore-chrome lg:hidden ${hideFloat ? "is-hidden" : ""} ${placeSelected ? "is-place-selected" : ""}`}
			data-testid="intelligence-map-overlay"
			data-chrome-hidden={hideFloat ? "true" : undefined}
		>
			<div className="farq-explore-top">
				<div className="farq-map-float-bar">
					<button
						type="button"
						aria-expanded={drawerOpen}
						aria-controls="farq-map-drawer"
						aria-label={isRTL ? "استكشف" : "Explore"}
						onClick={() => onDrawerOpenChange(!drawerOpen)}
						data-testid="intelligence-map-drawer-toggle"
					>
						<Menu className="size-4" />
					</button>
					<FarqBrandMark
						variant="wordmark"
						className="farq-map-wordmark-compact"
					/>
				</div>

				<form
					className="farq-map-search-compact"
					onSubmit={(e) => {
						e.preventDefault();
						onSearchSubmit(mapQuery.trim());
					}}
				>
					<Search className="size-4 shrink-0 text-[#6b7c7c]" />
					<input
						value={mapQuery}
						onChange={(e) => onMapQueryChange(e.currentTarget.value)}
						onFocus={() => onSearchFocused(true)}
						onBlur={() => {
							window.setTimeout(() => onSearchFocused(false), 180);
						}}
						placeholder={
							isRTL ? "ماذا تريد أن تستكشف؟" : "What do you want to explore?"
						}
						className="h-10 min-w-0 flex-1 bg-transparent text-[14px] text-brand-900 placeholder:text-[#6b7c7c]"
						data-testid="intelligence-map-search"
						aria-label={isRTL ? "استكشاف على الخريطة" : "Explore the map"}
					/>
				</form>

				{searchFocused ? (
					<div>
						<div
							className="farq-map-chips farq-map-chips--discover"
							data-testid="intelligence-map-discover"
						>
							{DISCOVERY_CHIPS.map((chip) => (
								<button
									key={chip.id}
									type="button"
									className="farq-map-chip"
									onMouseDown={(e) => e.preventDefault()}
									onClick={() => applyDiscovery(chip)}
								>
									{isRTL ? chip.labelAr : chip.labelEn}
								</button>
							))}
						</div>
						<p className="px-1 pt-1 text-[10px] font-bold text-[#6b7c7c]">
							{isRTL
								? "بحث سريع — مو فلتر مطبخ موثّق"
								: "Quick search — not a validated cuisine filter"}
						</p>
					</div>
				) : (
					<FarqViewSortBar
						view={view}
						onView={onView}
						sort={sort}
						onSort={onSort}
						isRTL={isRTL}
						nearReady={nearReady}
						cheapReady={cheapestReady}
						onNeedLocation={onNeedLocation}
					/>
				)}
			</div>

			<div
				className={`farq-map-tools farq-map-tools--mobile ${
					leftUserLocation ? "is-return" : ""
				}`}
			>
				<button
					type="button"
					onClick={onLocate}
					className={`farq-map-locate-fab ${
						leftUserLocation ? "farq-map-locate-return" : ""
					} ${locateBusy ? "is-busy" : ""}`}
					data-testid="intelligence-map-locate"
					aria-busy={locateBusy}
					aria-label={
						locateBusy
							? isRTL
								? "نحدد موقعك…"
								: "Locating…"
							: leftUserLocation
								? isRTL
									? "العودة لموقعك"
									: "Return to your location"
								: isRTL
									? "موقعي"
									: "My location"
					}
				>
					<CircleDot className="size-4" />
					{locateBusy ? (
						<span>{isRTL ? "نحدد موقعك…" : "Locating…"}</span>
					) : leftUserLocation ? (
						<span>{isRTL ? "العودة لموقعك" : "Back to you"}</span>
					) : null}
				</button>
			</div>

			{view === "map" && !placeSelected && sheetSnap === "closed" ? (
				<button
					type="button"
					className="farq-map-panel-tab inline-flex"
					data-testid="intelligence-map-around-reopen"
					aria-label={isRTL ? "إظهار أكبر فرق" : "Show top gap"}
					onClick={() => onSheetSnap("peek")}
				>
					{isRTL ? (
						<ChevronLeft className="size-3.5" />
					) : (
						<ChevronRight className="size-3.5" />
					)}
					<span>{isRTL ? "أكبر فرق" : "Top gap"}</span>
				</button>
			) : null}

			{view === "map" && !placeSelected && sheetSnap !== "closed" ? (
				<div
					className={`farq-map-around farq-map-around--side farq-map-around--${sheetSnap}`}
					data-testid="intelligence-map-around"
					data-sheet-snap={sheetSnap}
				>
					<div
						className="farq-map-scan"
						data-testid="intelligence-map-scan"
						aria-live="polite"
					>
						{scanHint || placesFetching
							? isRTL
								? "نبحث عن أكبر الفروقات…"
								: "Looking for the biggest gaps…"
							: null}
					</div>
					<div className="farq-map-overlay-card overflow-hidden">
						<div
							className="farq-map-around-toolbar touch-none"
							data-testid="intelligence-map-around-handle"
							onPointerDown={onSheetPointerDown}
							onPointerMove={onSheetPointerMove}
							onPointerUp={onSheetPointerUp}
							onPointerCancel={onSheetPointerUp}
						>
							<p className="min-w-0 truncate text-[12px] font-extrabold text-brand-900">
								{isRTL ? "فلوسك تضيع هنا" : "Your money leaks here"}
							</p>
							<button
								type="button"
								className="farq-map-around-hide"
								aria-label={isRTL ? "إخفاء" : "Hide"}
								data-testid="intelligence-map-around-hide"
								onClick={() => onSheetSnap("closed")}
							>
								{isRTL ? (
									<ChevronRight className="size-4" />
								) : (
									<ChevronLeft className="size-4" />
								)}
							</button>
						</div>
						<div
							className="farq-map-around-peek"
							data-testid="intelligence-map-around-peek"
							aria-expanded={sheetSnap === "expanded"}
						>
							{sheetSnap === "expanded" ? (
								<button
									type="button"
									className="w-full min-w-0 truncate text-start text-[13px] font-extrabold text-brand-900"
									onClick={() => onSheetSnap("peek")}
								>
									{isRTL ? "فلوسك تضيع هنا" : "Your money leaks here"}
								</button>
							) : aroundMax ? (
								<div className="farq-map-aha" data-testid="intelligence-map-aha">
									<p className="farq-map-aha-kicker">
										{isRTL ? "🔥 أكبر فرق حولك" : "🔥 Biggest gap around you"}
									</p>
									<p className="farq-map-aha-gap">
										{localizeDigitString(
											String(Math.round(aroundMax.amount)),
											isRTL,
										)}{" "}
										{isRTL ? "ر.س فرق" : "SAR gap"}
									</p>
									<p className="farq-map-aha-waste">
										{isRTL
											? `لو طلبت هذا من المزوّد الغلط تدفع ${localizeDigitString(String(Math.round(aroundMax.amount)), true)} ر.س زيادة`
											: `Order from the wrong provider and you pay ${Math.round(aroundMax.amount)} SAR extra`}
									</p>
									<p className="farq-map-aha-place">
										{[aroundMax.productName, aroundMax.name]
											.filter(Boolean)
											.join(" · ") || (isRTL ? "مطعم" : "Restaurant")}
									</p>
									{(aroundMax.cheapestProvider ||
										aroundMax.expensiveProvider ||
										aroundMax.cheapestPrice != null ||
										aroundMax.expensivePrice != null) && (
										<div
											className="farq-map-aha-apps"
											data-testid="intelligence-map-aha-apps"
										>
											<ProviderCompareLine
												kind="cheap"
												provider={aroundMax.cheapestProvider}
												price={aroundMax.cheapestPrice}
												isRTL={isRTL}
											/>
											<ProviderCompareLine
												kind="expensive"
												provider={aroundMax.expensiveProvider}
												price={aroundMax.expensivePrice}
												isRTL={isRTL}
											/>
										</div>
									)}
									<button
										type="button"
										className="farq-map-aha-cta"
										data-testid="intelligence-map-aha-cta"
										onClick={() => onFocusPlace(aroundMax)}
									>
										{isRTL ? "قارن الآن ←" : "Compare now →"}
									</button>
								</div>
							) : (
								<p className="px-1 pb-2 text-[13px] font-extrabold text-brand-900">
									{isRTL ? "🔥 أكبر فرق حولك" : "🔥 Biggest gap around you"}
								</p>
							)}
						</div>
						{sheetSnap === "expanded" ? (
							sort === "cheap" && !cheapestReady ? (
								<div
									className="space-y-2 border-t border-[#e6eef0] px-3 py-4"
									data-testid="intelligence-map-cheapest-unavailable"
								>
									<p className="text-[14px] font-extrabold text-brand-900">
										{isRTL
											? "ما عندنا سعر أرخص مرصود للترتيب هنا"
											: "No observed cheapest price to rank here"}
									</p>
									<p className="text-[12px] font-bold text-[#6b7c7c]">
										{isRTL
											? "الأرخص يظهر فقط لما الرصد فيه cheapest_price."
											: "Cheapest ranking stays off until cheapest_price is observed."}
									</p>
								</div>
							) : emptyViewport ? (
								<div
									className="space-y-3 border-t border-[#e6eef0] px-3 py-4"
									data-testid="intelligence-map-empty"
								>
									<p className="text-[14px] font-extrabold text-brand-900">
										{isRTL
											? "ما رصدنا فرق يستحق حولك بعد"
											: "No worthwhile gap observed around you yet"}
									</p>
									<button
										type="button"
										className="farq-map-empty-cta"
										onClick={() => {
											const next =
												exploreRadius === "1km"
													? "3km"
													: exploreRadius === "3km"
														? "5km"
														: "5km";
											onExploreRadius(next);
										}}
									>
										{isRTL ? "وسّع نطاق الاستكشاف" : "Widen the search"}
									</button>
								</div>
							) : (
								<ul
									className="farq-map-around-list"
									data-testid="intelligence-map-top-savings"
								>
									{topSavings.map((row) => (
										<li key={row.placeId}>
											<FarqOpportunityCard
												row={row}
												isRTL={isRTL}
												onSelect={onFocusPlace}
											/>
										</li>
									))}
								</ul>
							)
						) : null}
					</div>
				</div>
			) : null}

			{drawerOpen ? (
				<>
					<button
						type="button"
						className="farq-map-drawer-backdrop"
						aria-label={isRTL ? "إغلاق القائمة" : "Close drawer"}
						onClick={() => onDrawerOpenChange(false)}
					/>
					<aside
						id="farq-map-drawer"
						className="farq-map-drawer"
						data-testid="intelligence-map-drawer"
						style={
							drawerDragX
								? {
										transform: `translateX(${isRTL ? drawerDragX : -drawerDragX}px)`,
									}
								: undefined
						}
						onPointerDown={onDrawerPointerDown}
						onPointerMove={onDrawerPointerMove}
						onPointerUp={onDrawerPointerUp}
						onPointerCancel={onDrawerPointerUp}
					>
						<div className="mb-3 flex items-center justify-between">
							<h2 className="text-[15px] font-extrabold text-brand-900">
								{isRTL ? "استكشف" : "Explore"}
							</h2>
							<button
								type="button"
								className="inline-flex size-11 items-center justify-center rounded-full text-brand-900"
								aria-label={isRTL ? "إغلاق" : "Close"}
								onClick={() => onDrawerOpenChange(false)}
							>
								<X className="size-4" />
							</button>
						</div>

						<section className="space-y-2">
							<p className="farq-map-drawer-kicker">
								{isRTL ? "استكشف" : "Explore"}
							</p>
							<div className="grid grid-cols-1 gap-1">
								{(
									[
										["gaps", isRTL ? "أكبر فرق" : "Biggest gaps", () => onSort("gap")],
										["near", isRTL ? "الأقرب" : "Nearest", () => onSort("near")],
										["cheap", isRTL ? "الأرخص" : "Cheapest", () => onSort("cheap")],
										["grocery", isRTL ? "بقالة" : "Grocery", () => onRail("grocery")],
										["around", isRTL ? "حولي" : "Around you", () => onExploreRadius("hawally")],
									] as const
								).map(([id, label, act]) => (
									<button
										key={id}
										type="button"
										className="farq-map-drawer-item"
										onClick={() => {
											act();
											onDrawerOpenChange(false);
										}}
									>
										{label}
									</button>
								))}
							</div>
						</section>

						<button
							type="button"
							className="farq-map-drawer-item mt-5"
							aria-expanded={mapOptionsOpen}
							data-testid="intelligence-map-options"
							onClick={() => setMapOptionsOpen((open) => !open)}
						>
							<span>{isRTL ? "⚙ خيارات متقدمة" : "⚙ Advanced options"}</span>
						</button>

						{mapOptionsOpen ? (
						<>
						<section className="mt-3 space-y-2">
							<button
								type="button"
								className="farq-map-drawer-item"
								onClick={onToggleLanguage}
								disabled={languageSwitching}
							>
								{language === "en" ? "العربية" : "English"}
							</button>
							<p className="farq-map-drawer-kicker">
								{isRTL ? "طبقات GIS — ثانوية" : "GIS layers — secondary"}
							</p>
							{(
								[
									["opportunities", isRTL ? "فرص الأسعار" : "Price opportunities", true],
									["restaurants", isRTL ? "المطاعم" : "Restaurants", true],
									["providers", isRTL ? "مزودي الخدمة" : "Providers", false],
									["prices", isRTL ? "الأسعار" : "Prices", true],
									["delivery", isRTL ? "فرق التوصيل" : "Delivery gap", false],
								] as const
							).map(([id, label, wired]) => (
								<button
									key={id}
									type="button"
									disabled={!wired}
									aria-pressed={wired ? layers[id] : false}
									aria-disabled={!wired}
									className={`farq-map-drawer-item ${
										wired && layers[id] ? "is-on" : ""
									} ${wired ? "" : "is-muted"}`}
									onClick={() => {
										if (wired) onToggleLayer(id);
									}}
								>
									<span>{label}</span>
									{wired ? null : (
										<span className="text-[10px] font-bold text-[#6b7c7c]">
											{isRTL ? "غير متاح" : "Unavailable"}
										</span>
									)}
								</button>
							))}
							<button
								type="button"
								aria-pressed={gisHoodsOn}
								data-testid="intelligence-map-gis-hoods"
								className={`farq-map-drawer-item ${gisHoodsOn ? "is-on" : ""}`}
								onClick={onToggleGisHoods}
							>
								{isRTL ? "أحياء" : "Neighborhoods"}
							</button>
							<button
								type="button"
								disabled
								aria-pressed={false}
								data-testid="intelligence-map-gis-streets"
								className="farq-map-drawer-item is-muted"
							>
								<span>{isRTL ? "شوارع" : "Streets"}</span>
							</button>
							<button
								type="button"
								disabled
								aria-pressed={false}
								data-testid="intelligence-map-gis-buildings"
								className="farq-map-drawer-item is-muted"
							>
								<span>{isRTL ? "مباني" : "Buildings"}</span>
							</button>
							<div className="flex overflow-hidden rounded-xl bg-[#e6eef0] p-0.5">
								<button
									type="button"
									className={`h-10 flex-1 rounded-lg text-[12px] font-bold ${
										basemap === "standard"
											? "bg-brand-900 text-mint-500"
											: "text-[#6b7c7c]"
									}`}
									onClick={() => onBasemapChange("standard")}
								>
									{isRTL ? "خريطة" : "Map"}
								</button>
								<button
									type="button"
									className={`h-10 flex-1 rounded-lg text-[12px] font-bold ${
										basemap === "satellite"
											? "bg-brand-900 text-mint-500"
											: "text-[#6b7c7c]"
									}`}
									onClick={() => onBasemapChange("satellite")}
								>
									{isRTL ? "قمر صناعي" : "Satellite"}
								</button>
							</div>
							<button
								type="button"
								aria-pressed={majorGapsOnly}
								className={`farq-map-drawer-item ${majorGapsOnly ? "is-on" : ""}`}
								onClick={onToggleMajorGaps}
							>
								{isRTL ? "فروقات ملحوظة فقط" : "Observed gaps only"}
							</button>
							<button
								type="button"
								className="farq-map-drawer-item"
								aria-expanded={legendOpen}
								aria-controls="farq-map-legend"
								data-testid="intelligence-map-legend-info"
								onClick={() => onLegendOpenChange(!legendOpen)}
							>
								<Info className="size-4" />
								{isRTL ? "دليل الخريطة" : "Map legend"}
							</button>
						</section>

						<section className="mt-5 space-y-2">
							<p className="farq-map-drawer-kicker">
								{isRTL ? "نطاق العرض" : "View range"}
							</p>
							<p className="text-[11px] font-bold text-[#6b7c7c]">
								{isRTL
									? "استكشاف قريب — يغيّر تقريب الخريطة فقط، مو نطاق توصيل"
									: "Nearby explore — camera zoom only, not a delivery radius"}
							</p>
							<div className="grid grid-cols-2 gap-1">
								{(
									[
										["hawally", isRTL ? "حولي" : "Around you"],
										["1km", isRTL ? "قريب · ١ كم" : "Near · 1 km"],
										["3km", isRTL ? "قريب · ٣ كم" : "Near · 3 km"],
										["5km", isRTL ? "قريب · ٥ كم" : "Near · 5 km"],
										["city", isRTL ? "المدينة" : "City"],
									] as const
								).map(([id, label]) => (
									<button
										key={id}
										type="button"
										aria-pressed={exploreRadius === id}
										className={`farq-map-drawer-item ${exploreRadius === id ? "is-on" : ""}`}
										onClick={() => onExploreRadius(id)}
									>
										{label}
									</button>
								))}
							</div>
							<label className="relative block">
								<select
									value={city}
									onChange={(e) => onCityChange(e.target.value)}
									className="h-11 w-full appearance-none rounded-xl bg-[#e6eef0] px-3 text-[13px] font-bold text-brand-900"
									aria-label={isRTL ? "المدينة" : "City"}
								>
									<option value="">
										{isRTL ? "كل المدن الجاهزة" : "All ready cities"}
									</option>
									{cities.map((c) => (
										<option key={c.city_en} value={c.city_en}>
											{localizeCity(c.city_ar || c.city_en, isRTL)}
										</option>
									))}
								</select>
							</label>
							{categoryGroups.length ? (
								<div className="grid grid-cols-1 gap-1">
									{categoryGroups.flatMap((g) =>
										g.categories.map((c: IntelligenceCategory) => (
											<button
												key={c.category_id}
												type="button"
												className={`farq-map-drawer-item ${
													categoryId === c.category_id ? "is-on" : ""
												}`}
												onClick={() =>
													onApplyCategory(
														categoryId === c.category_id ? "" : c.category_id,
													)
												}
											>
												{c.category_name_ar || c.category_name || c.category_id}
											</button>
										)),
									)}
								</div>
							) : null}
						</section>
						</>
						) : null}
					</aside>
				</>
			) : null}
		</div>
	);
}
