/**
 * Isolated mobile presentation layer for the Farq Price Opportunity Map.
 * Floats over the full-screen Mapbox canvas — never a layout slot under the map.
 * Desktop chrome stays in IntelligenceMapSplit.
 */
import {
	CircleDot,
	Info,
	Menu,
	Search,
	X,
} from "lucide-react";
import {
	useRef,
	useState,
	type CSSProperties,
	type PointerEvent as ReactPointerEvent,
	type ReactNode,
} from "react";
import { localizeCity } from "../../lib/cityNames";
import type { OpportunityRow } from "../../lib/farqOpportunities";
import type { MapSort, MapViewMode } from "../../routes/map";
import type {
	CityDistricts,
	IntelligenceCategory,
	IntelligenceCategoryGroup,
	IntelligenceCityCoverage,
} from "../../services/intelligenceService";
import { PROVIDER_MAP_COLOR, getProviderLabel } from "../../lib/platformLogos";
import FarqWordmark from "../FarqWordmark";
import FarqDistrictPicker from "./FarqDistrictPicker";
import FarqLensSwitch from "./FarqLensSwitch";
import type { DistrictLens } from "../../lib/farqDistrictTiles";
import FarqViewSortBar from "./FarqViewSortBar";
import { FarqOpportunityCard } from "./FarqOpportunityList";
import FarqBottomSheet, { type SheetSnap as BottomSnap } from "./FarqBottomSheet";
import FarqAnswerCard from "./FarqAnswerCard";
import { looksLikeQuestion, type CopilotResponse } from "../../lib/farqAsk";

export type ExploreRadius = "hawally" | "1km" | "3km" | "5km" | "city";
export type FilterRailId = "gaps" | "restaurants" | "grocery" | "cheapest";
export type SheetSnap = BottomSnap;
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
	aroundMax: _aroundMax,
	topSavings,
	sheetSnap,
	onSheetSnap,
	placesFetching,
	scanHint,
	hasViewportPlaces,
	placesReady,
	headline,
	selectedPanel = null,
	ask,
	onAsk,
	onCloseAsk,
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
	legendOpen,
	onLegendOpenChange,
	districts = null,
	selectedDistrictId = "",
	onSelectDistrict,
	onClearDistrict,
	districtLens = "gap",
	onDistrictLensChange,
	appLensProviders = [],
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
	/** One line that is true for what the camera shows — the sheet's head. */
	headline: ReactNode;
	/** The selected place's panel; when present it replaces the list inside the sheet. */
	selectedPanel?: ReactNode;
	/** The copilot exchange in flight or answered; shown above the list. */
	ask: { question: string; response: CopilotResponse | null; busy: boolean; error: string | null } | null;
	onAsk: (text: string) => void;
	onCloseAsk: () => void;
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
	legendOpen: boolean;
	onLegendOpenChange: (open: boolean) => void;
	/** The city's أحياء for the picker under the search; null when the city has no boundaries. */
	districts?: CityDistricts | null;
	selectedDistrictId?: string;
	onSelectDistrict: (districtId: string) => void;
	onClearDistrict: () => void;
	/** What the district colour answers. The ⓘ legend is desktop-only, so the
	 *  switch has to live here too or the phone cannot reach it at all. */
	districtLens?: DistrictLens;
	onDistrictLensChange?: (lens: DistrictLens) => void;
	/** Apps that actually win a حي — the phone's only key for the app lens. */
	appLensProviders?: string[];
}) {
	const [drawerDragX, setDrawerDragX] = useState(0);
	const [mapOptionsOpen, setMapOptionsOpen] = useState(false);
	const drawerDragRef = useRef<{
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

	const emptyViewport =
		placesReady &&
		!placesFetching &&
		!scanHint &&
		hasViewportPlaces === false &&
		topSavings.length === 0;
	const hideFloat = chromeHidden && !drawerOpen && !searchFocused && sheetSnap === "peek";

	return (
		<div
			className={`farq-explore-chrome lg:hidden ${hideFloat ? "is-hidden" : ""} ${placeSelected ? "is-place-selected" : ""}`}
			data-testid="intelligence-map-overlay"
			data-snap={sheetSnap}
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
					<FarqWordmark height={22} />
				</div>

				<form
					className="farq-map-search-compact"
					onSubmit={(e) => {
						e.preventDefault();
						const text = mapQuery.trim();
						if (looksLikeQuestion(text)) onAsk(text);
						else onSearchSubmit(text);
					}}
				>
					<Search className="size-4 shrink-0 text-[#5c6d6d]" />
					<input
						value={mapQuery}
						onChange={(e) => onMapQueryChange(e.currentTarget.value)}
						onFocus={() => onSearchFocused(true)}
						onBlur={() => {
							window.setTimeout(() => onSearchFocused(false), 180);
						}}
						placeholder={
							isRTL ? "ابحث أو اسأل فرق: وين أكبر فرق حولي؟" : "Search or ask Farq: biggest gap near me?"
						}
						className="h-10 min-w-0 flex-1 bg-transparent text-[14px] text-brand-900 placeholder:text-[#5c6d6d]"
						data-testid="intelligence-map-search"
						aria-label={isRTL ? "استكشاف على الخريطة" : "Explore the map"}
					/>
				</form>

				<div className="farq-map-district-row">
					<FarqDistrictPicker
						districts={districts}
						selectedId={selectedDistrictId}
						isRTL={isRTL}
						onSelect={onSelectDistrict}
						onClear={onClearDistrict}
						variant="chip"
					/>
					{onDistrictLensChange ? (
						<FarqLensSwitch
							lens={districtLens}
							onChange={onDistrictLensChange}
							isRTL={isRTL}
							disabled={!districts}
						/>
					) : null}
				</div>

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
						<p className="px-1 pt-1 text-[10px] font-bold text-[#5c6d6d]">
							{isRTL
								? "بحث سريع — مو فلتر مطبخ موثّق"
								: "Quick search — not a validated cuisine filter"}
						</p>
					</div>
				) : null}
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

			<FarqBottomSheet
				snap={sheetSnap}
				onSnap={onSheetSnap}
				isRTL={isRTL}
				header={headline}
				rail={
					<FarqViewSortBar
						hideViewToggle
						view={view}
						onView={onView}
						sort={sort}
						onSort={onSort}
						isRTL={isRTL}
						nearReady={nearReady}
						cheapReady={cheapestReady}
					/>
				}
			>
				{ask ? (
					<FarqAnswerCard
						question={ask.question}
						response={ask.response}
						busy={ask.busy}
						error={ask.error}
						isRTL={isRTL}
						onAsk={onAsk}
						onSelect={onFocusPlace}
						onClose={onCloseAsk}
					/>
				) : null}
				{placeSelected && selectedPanel ? (
					selectedPanel
				) : sort === "cheap" && !cheapestReady ? (
					<div
						className="space-y-2 px-2 py-4"
						data-testid="intelligence-map-cheapest-unavailable"
					>
						<p className="text-[14px] font-extrabold text-brand-900">
							{isRTL
								? "ما عندنا سعر أرخص مرصود للترتيب هنا"
								: "No observed cheapest price to rank here"}
						</p>
						<p className="text-[12px] font-bold text-[#5c6d6d]">
							{isRTL
								? "الأرخص يظهر فقط لما الرصد فيه سعر أرخص."
								: "Cheapest ranking stays off until a cheapest price is observed."}
						</p>
					</div>
				) : emptyViewport ? (
					<div className="space-y-3 px-2 py-4" data-testid="intelligence-map-empty">
						<p className="text-[14px] font-extrabold text-brand-900">
							{isRTL
								? "ما رصدنا فرق يستحق في هذا النطاق بعد"
								: "No worthwhile gap observed in this area yet"}
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
											: "city";
								onExploreRadius(next);
							}}
						>
							{isRTL ? "وسّع النطاق" : "Widen the area"}
						</button>
					</div>
				) : (
					<ul className="farq-sheet-list" data-testid="intelligence-map-top-savings">
						{topSavings.map((row) => (
							<li key={row.placeId}>
								<FarqOpportunityCard row={row} isRTL={isRTL} onSelect={onFocusPlace} />
							</li>
						))}
					</ul>
				)}
			</FarqBottomSheet>

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
										["value", isRTL ? "الأعلى نسبة" : "Best %", () => onSort("value")],
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

						{/* How to read the map is not an advanced option — it decides what the
						    whole city zoom is saying, so it sits with Explore, one tap in. */}
						{onDistrictLensChange ? (
							<section className="mt-5 space-y-2">
								<p className="farq-map-drawer-kicker">
									{isRTL ? "لون الحي يعني" : "District colour means"}
								</p>
								<div className="flex overflow-hidden rounded-xl bg-[#e6eef0] p-0.5">
									{(
										[
											["gap", isRTL ? "عدد الفرص" : "Opportunities"],
											["app", isRTL ? "التطبيق الأرخص" : "Cheapest app"],
										] as const
									).map(([id, label]) => (
										<button
											key={id}
											type="button"
											aria-pressed={districtLens === id}
											data-testid={`intelligence-map-lens-${id}`}
											className={`h-10 flex-1 rounded-lg text-[12px] font-bold ${
												districtLens === id ? "bg-brand-900 text-mint-500" : "text-[#5c6d6d]"
											}`}
											onClick={() => onDistrictLensChange(id)}
										>
											{label}
										</button>
									))}
								</div>
								{/* Desktop reads the key in the ⓘ legend, which the phone never
								    shows — without this the phone got a colour map of Riyadh
								    with nothing on screen saying what the colours mean. */}
								{districtLens === "app" ? (
									<>
										<ul className="farq-legend-apps mt-1">
											{appLensProviders.map((provider) => (
												<li key={provider}>
													<span
														className="farq-legend-app-swatch"
														style={{ "--app": PROVIDER_MAP_COLOR[provider] || "#94a3b8" } as CSSProperties}
														aria-hidden
													/>
													<span>{getProviderLabel(provider, { isRTL }) || provider}</span>
												</li>
											))}
										</ul>
										<ul className="farq-legend-apps farq-legend-apps--states">
											<li>
												<span className="farq-legend-app-swatch is-close" aria-hidden />
												<span>{isRTL ? "متقارب — لا فائز واضح" : "Too close to call"}</span>
											</li>
											<li>
												<span className="farq-legend-app-swatch is-empty" aria-hidden />
												<span>{isRTL ? "مقارنات غير كافية" : "Not enough comparisons"}</span>
											</li>
										</ul>
										<p className="farq-legend-note">
											{isRTL
												? "يُسمّى تطبيق فائز فقط من ٨ مقارنات فأكثر وبفارق ٥٪ على الأقل."
												: "An app is named only from 8 comparisons up and a lead of at least 5 points."}
										</p>
									</>
								) : null}
							</section>
						) : null}

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
										<span className="text-[10px] font-bold text-[#5c6d6d]">
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
							<p className="text-[11px] font-bold text-[#5c6d6d]">
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
