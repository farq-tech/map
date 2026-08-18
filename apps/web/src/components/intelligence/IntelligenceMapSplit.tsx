/**
 * Figma map-desktop-split (2:620) — Mapbox GL + Farq difference panel.
 * Pins come from comparison.discovery_cards via /api/intelligence/map/places
 * (layer=comparison: product-ready restaurants with real lat/lng).
 * Pin tap opens a premium sheet/panel; CTA «افتح الأرخص» goes to
 * /merchant/restaurant/:id (same as a home card).
 * Neighborhoods are fetched for the side panel only — not painted as a mosaic.
 * Never invents lat/lon; never remints Golden place_id.
 */
import { Link, useNavigate } from "@tanstack/react-router";
import { ChevronDown, Info, MapPin, Navigation, Search, X } from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { localizeCity } from "../../lib/cityNames";
import { observedDifferenceAmount } from "../../lib/farqMapPins";
import { localizeDigitString } from "../../lib/formatPrice";
import type { MapboxBasemap } from "../../lib/mapboxAccess";
import { providerTintClass } from "../../lib/providerTint";
import {
	IntelligenceService,
	toIntelCategoryId,
	type IntelligenceCategory,
	type IntelligenceCategoryGroup,
	type IntelligenceDetail,
	type IntelligenceMapNeighborhoods,
	type IntelligenceMapPlaceDetail,
	type IntelligenceMapPlaces,
	type IntelligenceMeta,
} from "../../services/intelligenceService";
import EmptyState from "../EmptyState";
import FarqBrandMark from "../FarqBrandMark";
import { ProviderLogoMark } from "../ProviderLogoMark";
import { Button } from "../ui/Button";
import type { MapSearch } from "../../routes/map";
import SelectedPlaceSheet from "./SelectedPlaceSheet";
import "../../styles/farq-mapbox.css";

const MOBILE_FOOD_CHIPS = ["burgers", "pizza", "shawarma"] as const;

function categorySearchQuery(
	categoryId: string,
	selected: IntelligenceCategory | null,
	userQ: string,
): string | undefined {
	if (userQ) return userQ;
	if (!categoryId || categoryId === "food" || categoryId === "grocery") {
		return undefined;
	}
	return selected?.category_name_ar || selected?.category_name || undefined;
}

const FarqMap = lazy(() => import("./FarqMap"));

function fmtScore(v: number | string | null | undefined): string {
	if (v == null || v === "") return "—";
	const n = Number(v);
	return Number.isFinite(n) ? n.toFixed(0) : "—";
}

export default function IntelligenceMapSplit({
	search,
}: {
	search: MapSearch;
}) {
	const { language, toggleLanguage, languageSwitching } = useLanguage();
	const isRTL = language === "ar";
	const navigate = useNavigate();
	const {
		userLocation,
		locationPinKind,
		openMapModal,
		requestLocation,
	} = useLocation();
	const [meta, setMeta] = useState<IntelligenceMeta | null>(null);
	const [places, setPlaces] = useState<IntelligenceMapPlaces | null>(null);
	const [hoods, setHoods] = useState<IntelligenceMapNeighborhoods | null>(null);
	const [detail, setDetail] = useState<IntelligenceDetail | null>(null);
	const [placeDetail, setPlaceDetail] = useState<IntelligenceMapPlaceDetail | null>(
		null,
	);
	const [error, setError] = useState<string | null>(null);
	const [loading, setLoading] = useState(true);
	const [mapQuery, setMapQuery] = useState(search.q || "");
	const viewRef = useRef<{ bbox: string; zoom: number } | null>(null);
	const viewTimerRef = useRef<number>(0);
	const placesAbortRef = useRef<AbortController | null>(null);
	const lastFocusedPlaceRef = useRef<string>("");
	const pendingLocateRef = useRef(false);
	const [focusRequest, setFocusRequest] = useState<{
		lat: number;
		lng: number;
		id: string;
	} | null>(null);
	const [basemap, setBasemap] = useState<MapboxBasemap>("standard");
	const [majorGapsOnly, setMajorGapsOnly] = useState(false);
	const [legendOpen, setLegendOpen] = useState(false);
	const [retryTick, setRetryTick] = useState(0);
	const [moreOpen, setMoreOpen] = useState(false);
	const [aroundOpen, setAroundOpen] = useState(false);
	const [chromeOpen, setChromeOpen] = useState(true);
	const [scanHint, setScanHint] = useState<"searching" | "ready" | null>(null);
	const [placesFetching, setPlacesFetching] = useState(false);
	const filterKeyRef = useRef("");
	const scanTimerRef = useRef(0);

	const categoryId = toIntelCategoryId(search.category) || "";
	const neighborhoodId = search.neighborhood || "";
	const city = search.city || "";
	const placeId = search.place || "";
	const q = search.q || "";

	const patchSearch = useCallback(
		(next: Partial<MapSearch>) => {
			void navigate({
				to: "/map",
				search: (prev: MapSearch) => ({
					neighborhood:
						"neighborhood" in next ? next.neighborhood : prev.neighborhood,
					category: "category" in next ? next.category : prev.category,
					city: "city" in next ? next.city : prev.city,
					q: "q" in next ? next.q : prev.q,
					place: "place" in next ? next.place : prev.place,
				}),
			});
		},
		[navigate],
	);

	useEffect(() => {
		setMapQuery(search.q || "");
	}, [search.q]);

	useEffect(() => {
		let cancelled = false;
		const controller = new AbortController();
		setLoading(true);
		setError(null);
		void IntelligenceService.meta(controller.signal)
			.then((m) => {
				if (cancelled) return;
				setMeta(m);
				if (!search.category && m.categories.length) {
					const grocery = m.categories.find((c) => c.category_id === "grocery");
					const food = m.categories.find((c) => c.category_id === "burgers");
					patchSearch({
						category: (food || grocery || m.categories[0]).category_id,
						city: search.city || "Riyadh",
					});
				}
			})
			.catch(() => {
				if (!cancelled) {
					setError(
						isRTL
							? "تعذر تحميل الخريطة."
							: "Could not load the map.",
					);
				}
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
			controller.abort();
		};
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [retryTick]);

	const fetchPlaces = useCallback((bbox: string, zoom: number) => {
		placesAbortRef.current?.abort();
		const controller = new AbortController();
		placesAbortRef.current = controller;
		const cat =
			meta?.categories.find((c) => c.category_id === categoryId) || null;
		const query = categorySearchQuery(categoryId, cat, q);
		setPlacesFetching(true);
		setScanHint((cur) => (cur === "searching" ? "searching" : "ready"));
		window.clearTimeout(scanTimerRef.current);
		scanTimerRef.current = window.setTimeout(() => {
			setScanHint((cur) => (cur === "ready" ? null : cur));
		}, 700);
		void IntelligenceService.mapPlaces({
			bbox,
			zoom,
			q: query,
			category: categoryId || undefined,
			layer: "comparison",
			limit: 400,
			signal: controller.signal,
		})
			.then((body) => {
				if (controller.signal.aborted) return;
				setPlaces(body);
				setPlacesFetching(false);
				setScanHint(null);
			})
			.catch(() => {
				if (controller.signal.aborted) return;
				setPlaces(null);
				setPlacesFetching(false);
				setScanHint(null);
			});
	}, [q, categoryId, meta]);

	const onViewChange = useCallback(
		(bbox: string, zoom: number) => {
			const prev = viewRef.current;
			if (prev && prev.bbox === bbox && prev.zoom === zoom) return;
			viewRef.current = { bbox, zoom };
			window.clearTimeout(viewTimerRef.current);
			viewTimerRef.current = window.setTimeout(() => {
				fetchPlaces(bbox, zoom);
			}, 200);
		},
		[fetchPlaces],
	);

	useEffect(() => {
		const key = `${categoryId}|${q}`;
		if (filterKeyRef.current && filterKeyRef.current !== key) {
			setPlaces(null);
			setAroundOpen(false);
			setScanHint("searching");
		}
		filterKeyRef.current = key;
	}, [categoryId, q]);

	useEffect(() => {
		const v = viewRef.current;
		if (v) fetchPlaces(v.bbox, v.zoom);
	}, [fetchPlaces]);

	useEffect(() => {
		return () => window.clearTimeout(scanTimerRef.current);
	}, []);

	useEffect(() => {
		if (!categoryId) {
			setHoods(null);
			return;
		}
		const controller = new AbortController();
		void IntelligenceService.mapNeighborhoods({
			category: categoryId,
			city: city || "Riyadh",
			signal: controller.signal,
		})
			.then(setHoods)
			.catch(() => setHoods(null));
		return () => controller.abort();
	}, [categoryId, city]);

	useEffect(() => {
		if (!neighborhoodId || !categoryId) {
			setDetail(null);
			return;
		}
		const controller = new AbortController();
		void IntelligenceService.detail(neighborhoodId, categoryId, controller.signal)
			.then(setDetail)
			.catch(() => setDetail(null));
		return () => controller.abort();
	}, [neighborhoodId, categoryId]);

	useEffect(() => {
		if (!placeId) {
			setPlaceDetail(null);
			lastFocusedPlaceRef.current = "";
			return;
		}
		const controller = new AbortController();
		void IntelligenceService.mapPlace(placeId, controller.signal)
			.then(setPlaceDetail)
			.catch(() => setPlaceDetail(null));
		return () => controller.abort();
	}, [placeId]);

	useEffect(() => {
		if (!placeDetail || !placeId) return;
		if (placeDetail.place_id !== placeId) return;
		if (lastFocusedPlaceRef.current === placeId) return;
		lastFocusedPlaceRef.current = placeId;
		setFocusRequest({
			lat: placeDetail.lat,
			lng: placeDetail.lng,
			id: `place:${placeId}`,
		});
	}, [placeDetail, placeId]);

	useEffect(() => {
		if (!pendingLocateRef.current || !userLocation) return;
		if (locationPinKind !== "gps" && locationPinKind !== "manual") return;
		pendingLocateRef.current = false;
		setFocusRequest({
			lat: userLocation.lat,
			lng: userLocation.lng,
			id: `locate:${Date.now()}`,
		});
	}, [userLocation, locationPinKind]);

	const categoryGroups: IntelligenceCategoryGroup[] = useMemo(() => {
		if (!meta) return [];
		if (meta.category_groups?.length) return meta.category_groups;
		return [
			{
				sector_id: "all",
				sector_name_ar: isRTL ? "التصنيفات" : "Categories",
				sector_name_en: "Categories",
				category_count: meta.categories.length,
				categories: meta.categories,
			},
		];
	}, [meta, isRTL]);

	const selectedHood = hoods?.features.find(
		(f) => String(f.properties.neighborhood_id) === String(neighborhoodId),
	);
	const winner = detail?.winner;
	const promote = Boolean(winner?.promote_in_consumer_ui);
	const groceryCta = categoryId === "grocery" || categoryId === "shopping";
	const compareTo = groceryCta ? "/grocery" : "/";
	const compareSearch = groceryCta
		? { q: placeDetail?.name || q || undefined }
		: {
				category:
					detail?.farq_signal?.consumer?.category ||
					(categoryId === "burgers" ? "burger" : categoryId),
				q: placeDetail?.compare?.q || placeDetail?.name || detail?.farq_signal?.consumer?.q || q,
				vertical: "restaurant" as const,
			};

	const openRestaurantMenu = useCallback(
		(opts: {
			restaurantId: string;
			name?: string;
			image?: string | null;
		}) => {
			const restaurantId = String(opts.restaurantId || "").trim();
			if (!restaurantId) return;
			void navigate({
				to: "/merchant/$type/$id",
				params: { type: "restaurant", id: restaurantId },
				search: {
					...(opts.name ? { name: opts.name } : {}),
					...(opts.image ? { image: String(opts.image) } : {}),
				},
			});
		},
		[navigate],
	);

	const selectedPlaceFeature = places?.features.find(
		(f) => String(f.properties.place_id) === String(placeId),
	);
	const selectedRestaurantId =
		placeDetail?.restaurant_id ||
		placeDetail?.menu?.id ||
		selectedPlaceFeature?.properties.restaurant_id ||
		selectedPlaceFeature?.properties.menu?.id ||
		(/^\d+$/.test(placeId) ? placeId : "");

	const showUserDot = locationPinKind === "gps" || locationPinKind === "manual";

	const visiblePlaces = useMemo(() => {
		if (!places || !majorGapsOnly) return places;
		return {
			...places,
			features: places.features.filter((f) => {
				if (f.properties.feature_type === "cluster") {
					return Number(f.properties.difference_count || 0) > 0;
				}
				if (f.properties.has_difference) return true;
				const amount = Number(f.properties.difference?.difference_amount);
				return Number.isFinite(amount) && amount > 0;
			}),
		};
	}, [places, majorGapsOnly]);

	const topSavings = useMemo(() => {
		const rows: {
			placeId: string;
			name: string;
			amount: number;
			lat: number;
			lng: number;
		}[] = [];
		for (const f of visiblePlaces?.features || []) {
			if (f.properties.feature_type === "cluster") continue;
			const placeId = String(f.properties.place_id || "").trim();
			if (!placeId) continue;
			const amount = observedDifferenceAmount(f.properties.difference);
			if (amount == null) continue;
			const coords = f.geometry?.coordinates;
			if (!Array.isArray(coords) || coords.length < 2) continue;
			const lng = Number(coords[0]);
			const lat = Number(coords[1]);
			if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
			rows.push({
				placeId,
				name: String(f.properties.name || "").trim(),
				amount,
				lat,
				lng,
			});
		}
		return rows.sort((a, b) => b.amount - a.amount).slice(0, 12);
	}, [visiblePlaces]);

	const selectedCityLabel = useMemo(() => {
		const match = (meta?.geo_readiness?.ncp_ready_cities || []).find(
			(c) => c.city_en === city,
		);
		if (match) return localizeCity(match.city_ar || match.city_en, isRTL);
		return city
			? localizeCity(city, isRTL)
			: isRTL
				? "كل المدن"
				: "All cities";
	}, [meta, city, isRTL]);

	const selectedCategory = useMemo(
		() =>
			meta?.categories.find((c) => c.category_id === categoryId) || null,
		[meta, categoryId],
	);

	const foodChips = useMemo(() => {
		const cats = meta?.categories || [];
		const pinned = MOBILE_FOOD_CHIPS.map((id) =>
			cats.find((c) => c.category_id === id),
		).filter(Boolean) as IntelligenceCategory[];
		const rest = cats.filter(
			(c) =>
				!MOBILE_FOOD_CHIPS.includes(
					c.category_id as (typeof MOBILE_FOOD_CHIPS)[number],
				) &&
				c.category_id !== "food" &&
				c.category_id !== "grocery" &&
				c.category_id !== "shopping",
		);
		return { pinned, rest };
	}, [meta]);

	const aroundMax = topSavings[0] || null;

	const locateUser = useCallback(() => {
		if (
			(locationPinKind === "gps" || locationPinKind === "manual") &&
			userLocation
		) {
			setFocusRequest({
				lat: userLocation.lat,
				lng: userLocation.lng,
				id: `locate:${Date.now()}`,
			});
			return;
		}
		pendingLocateRef.current = true;
		if (locationPinKind === "gps" || locationPinKind === "manual") {
			requestLocation();
			return;
		}
		openMapModal();
	}, [locationPinKind, userLocation, requestLocation, openMapModal]);

	const applyCategory = useCallback(
		(nextId: string) => {
			setPlaces(null);
			setScanHint("searching");
			setMoreOpen(false);
			lastFocusedPlaceRef.current = "";
			patchSearch({
				category: nextId || undefined,
				place: undefined,
				q: undefined,
			});
			setMapQuery("");
		},
		[patchSearch],
	);

	const focusAroundPlace = useCallback(
		(row: { placeId: string; lat: number; lng: number }) => {
			lastFocusedPlaceRef.current = row.placeId;
			setFocusRequest({
				lat: row.lat,
				lng: row.lng,
				id: `place:${row.placeId}`,
			});
			patchSearch({
				place: row.placeId,
				neighborhood: undefined,
			});
			setAroundOpen(false);
		},
		[patchSearch],
	);

	if (error) {
		return (
			<div className="bg-surface px-4 py-10" data-testid="intelligence-map-error">
				<EmptyState
					illustration={<FarqBrandMark variant="wordmark" />}
					title="We couldn't load the live map"
					titleAr="ما قدرنا نحمّل الخريطة حياً"
					body="Please check your internet connection and try again to see price gaps."
					bodyAr="يرجى التحقق من اتصال الإنترنت وإعادة المحاولة لرصد الفروقات"
					action={{
						label: "Try again",
						labelAr: "إعادة المحاولة",
						onClick: () => {
							setError(null);
							setLoading(true);
							setRetryTick((n) => n + 1);
						},
					}}
					actionVariant="dark"
				/>
			</div>
		);
	}

	if (loading || !meta) {
		return (
			<div className="bg-surface px-4 py-10 text-center text-ink-muted" aria-busy>
				{isRTL ? "نحمّل الخريطة…" : "Loading map…"}
			</div>
		);
	}

	return (
		<div
			dir={isRTL ? "rtl" : "ltr"}
			className="farq-map-split flex h-[calc(100svh-var(--bottom-nav-h))] flex-col bg-surface lg:h-auto lg:min-h-[calc(100dvh-56px)] lg:flex-row"
			data-testid="intelligence-map-split"
			data-sheet-open={placeId ? "true" : undefined}
			data-legend-open={legendOpen ? "true" : undefined}
		>
			<div className="relative min-h-0 flex-1 bg-neutral-100 lg:min-h-0">
				{/* Mobile overlay — compact floating rows, not one giant card */}
				<div
					className="farq-map-overlay farq-map-overlay--mobile lg:hidden"
					data-testid="intelligence-map-overlay"
				>
					<div className="farq-map-overlay-row farq-map-overlay-card px-3 py-2">
						<FarqBrandMark variant="lockup" size={26} />
						<button
							type="button"
							onClick={toggleLanguage}
							disabled={languageSwitching}
							className="ms-auto inline-flex h-11 min-w-11 items-center justify-center rounded-full px-3 text-[13px] font-bold text-brand-900"
							aria-label={
								language === "en" ? "تبديل إلى العربية" : "Switch to English"
							}
						>
							{language === "en" ? "عربي" : "EN"}
						</button>
						<button
							type="button"
							className="inline-flex size-11 items-center justify-center rounded-full text-brand-900"
							aria-expanded={chromeOpen}
							aria-label={isRTL ? "إخفاء البحث" : "Toggle search"}
							onClick={() => setChromeOpen((v) => !v)}
						>
							{chromeOpen ? <X className="size-4" /> : <Search className="size-4" />}
						</button>
					</div>
					{chromeOpen ? (
						<>
							<form
								className="farq-map-overlay-card flex h-11 w-full items-center gap-2 px-3"
								onSubmit={(e) => {
									e.preventDefault();
									patchSearch({
										q: mapQuery.trim() || undefined,
										place: undefined,
									});
								}}
							>
								<Search className="size-4 shrink-0 text-[#6b7c7c]" />
								<input
									value={mapQuery}
									onChange={(e) => setMapQuery(e.target.value)}
									placeholder={
										isRTL
											? "ابحث عن مطعم أو مقهى…"
											: "Search a restaurant or café…"
									}
									className="h-11 min-w-0 flex-1 bg-transparent text-[14px] text-brand-900 placeholder:text-[#6b7c7c]"
									data-testid="intelligence-map-search"
									aria-label={isRTL ? "بحث على الخريطة" : "Search the map"}
								/>
							</form>
							<div
								className="farq-map-chips"
								data-testid="intelligence-map-chips"
							>
								<button
									type="button"
									aria-pressed={majorGapsOnly}
									data-testid="intelligence-map-major-gaps"
									className={`inline-flex h-11 shrink-0 items-center rounded-full px-4 text-[13px] font-bold ${
										majorGapsOnly
											? "bg-mint-500 text-brand-900"
											: "bg-white text-brand-900"
									}`}
									onClick={() => setMajorGapsOnly((v) => !v)}
								>
									{isRTL ? "🔥 أكبر فرق" : "🔥 Top gaps"}
								</button>
								{foodChips.pinned.map((c) => (
									<button
										key={c.category_id}
										type="button"
										aria-pressed={categoryId === c.category_id}
										className={`inline-flex h-11 shrink-0 items-center rounded-full px-4 text-[13px] font-bold ${
											categoryId === c.category_id
												? "bg-mint-500 text-brand-900"
												: "bg-white text-brand-900"
										}`}
										onClick={() => applyCategory(c.category_id)}
									>
										{c.category_name_ar || c.category_name}
									</button>
								))}
								<button
									type="button"
									aria-pressed={moreOpen}
									className={`inline-flex h-11 shrink-0 items-center rounded-full px-4 text-[13px] font-bold ${
										moreOpen
											? "bg-mint-500 text-brand-900"
											: "bg-white text-brand-900"
									}`}
									onClick={() => setMoreOpen((v) => !v)}
								>
									{isRTL ? "المزيد" : "More"}
								</button>
							</div>
							{moreOpen ? (
								<div className="farq-map-overlay-card max-h-40 overflow-y-auto p-2">
									{foodChips.rest.map((c) => (
										<button
											key={c.category_id}
											type="button"
											className="flex h-11 w-full items-center px-3 text-start text-[14px] font-bold text-brand-900"
											onClick={() => applyCategory(c.category_id)}
										>
											{c.category_name_ar || c.category_name}
										</button>
									))}
								</div>
							) : null}
						</>
					) : null}
				</div>

				<div className="absolute inset-x-3 top-3 z-[500] hidden flex-col gap-3 rounded-2xl bg-white p-4 shadow-[0_8px_8px_rgba(0,0,0,0.1)] lg:flex lg:flex-row lg:items-center lg:justify-between lg:gap-4 lg:py-3">
					<div className="flex min-w-0 items-center gap-4">
						<div className="flex shrink-0 items-center gap-1.5">
							<FarqBrandMark variant="lockup" size={29} />
							<label className="relative lg:hidden">
								<span className="text-[14px] font-black text-brand-900">
									{selectedCityLabel}
								</span>
								<select
									value={city}
									onChange={(e) =>
										patchSearch({
											city: e.target.value || undefined,
											neighborhood: undefined,
										})
									}
									className="absolute inset-0 cursor-pointer opacity-0"
									aria-label={isRTL ? "المدينة" : "City"}
								>
									<option value="">
										{isRTL ? "كل المدن الجاهزة" : "All ready cities"}
									</option>
									{(meta.geo_readiness?.ncp_ready_cities || []).map((c) => (
										<option key={c.city_en} value={c.city_en}>
											{localizeCity(c.city_ar || c.city_en, isRTL)}
										</option>
									))}
								</select>
							</label>
						</div>
						<span className="hidden h-6 w-px bg-[#e6eef0] lg:block" aria-hidden />
						<label className="relative hidden items-center gap-1 lg:flex">
							<MapPin className="size-3.5 shrink-0 text-[#6b7c7c]" />
							<select
								value={city}
								onChange={(e) =>
									patchSearch({
										city: e.target.value || undefined,
										neighborhood: undefined,
									})
								}
								className="appearance-none bg-transparent pe-5 text-[14px] font-bold text-brand-900"
								aria-label={isRTL ? "المدينة" : "City"}
							>
								<option value="">
									{isRTL ? "كل المدن الجاهزة" : "All ready cities"}
								</option>
								{(meta.geo_readiness?.ncp_ready_cities || []).map((c) => (
									<option key={c.city_en} value={c.city_en}>
										{localizeCity(c.city_ar || c.city_en, isRTL)}
									</option>
								))}
							</select>
							<ChevronDown className="pointer-events-none absolute end-0 size-3 text-[#6b7c7c]" />
						</label>
						<span className="hidden h-6 w-px bg-[#e6eef0] lg:block" aria-hidden />
						<form
							className="flex min-w-0 flex-1 items-center gap-2"
							onSubmit={(e) => {
								e.preventDefault();
								patchSearch({ q: mapQuery.trim() || undefined, place: undefined });
							}}
						>
							<Search className="size-4 shrink-0 text-[#6b7c7c]" />
							<input
								value={mapQuery}
								onChange={(e) => setMapQuery(e.target.value)}
								placeholder={
									isRTL
										? "ابحث عن مطعم أو مقهى…"
										: "Search a restaurant or café…"
								}
								className="h-7 min-w-0 flex-1 bg-transparent text-[14px] text-brand-900 placeholder:text-[#6b7c7c] lg:max-w-[14rem]"
								data-testid="intelligence-map-search"
								aria-label={isRTL ? "بحث على الخريطة" : "Search the map"}
							/>
						</form>
					</div>
					<div className="flex flex-wrap items-center justify-between gap-3 border-t border-[#e6eef0] pt-2.5 lg:border-0 lg:pt-0">
						<div className="flex items-center gap-1">
							<label className="relative">
								<select
									value={categoryId}
									onChange={(e) =>
										patchSearch({ category: e.target.value || undefined })
									}
									className="h-7 appearance-none rounded-full bg-[#e6eef0] px-3 pe-7 text-[12px] font-bold text-brand-900 lg:rounded-[20px]"
									aria-label={isRTL ? "الفئة" : "Category"}
									data-testid="intelligence-map-category"
								>
									{categoryGroups.flatMap((g) =>
										g.categories.map((c) => (
											<option key={c.category_id} value={c.category_id}>
												{c.category_name_ar || c.category_name || c.category_id}
											</option>
										)),
									)}
								</select>
								<ChevronDown className="pointer-events-none absolute end-2 top-1/2 size-3 -translate-y-1/2 text-brand-900" />
							</label>
						</div>
						<label className="flex items-center gap-2 text-[12px] text-[#6b7c7c]">
							<span className="hidden lg:inline">
								{isRTL ? "فروقات ملحوظة فقط" : "Observed gaps only"}
							</span>
							<span className="lg:hidden">
								{isRTL ? "ملحوظة فقط" : "Gaps only"}
							</span>
							<button
								type="button"
								role="switch"
								aria-checked={majorGapsOnly}
								onClick={() => setMajorGapsOnly((v) => !v)}
								className={`relative h-[18px] w-8 rounded-full transition-colors ${
									majorGapsOnly ? "bg-mint-500" : "bg-[#e6eef0]"
								}`}
								data-testid="intelligence-map-major-gaps"
							>
								<span
									className={`absolute top-0.5 size-3.5 rounded-full bg-brand-900 transition-[inset-inline-start] ${
										majorGapsOnly ? "inset-inline-start-[14px]" : "inset-inline-start-0.5"
									}`}
								/>
							</button>
						</label>
						<span className="hidden h-6 w-px bg-[#e6eef0] lg:block" aria-hidden />
						<div className="hidden overflow-hidden rounded-lg bg-[#e6eef0] p-0.5 lg:flex">
							<button
								type="button"
								data-testid="farq-map-style-satellite"
								className={`rounded-md px-2.5 py-1 text-[11px] font-bold ${
									basemap === "satellite"
										? "bg-brand-900 text-mint-500"
										: "text-[#6b7c7c]"
								}`}
								onClick={() => setBasemap("satellite")}
							>
								{isRTL ? "قمر صناعي" : "Satellite"}
							</button>
							<button
								type="button"
								data-testid="farq-map-style-standard"
								className={`rounded-md px-2.5 py-1 text-[11px] font-bold ${
									basemap === "standard"
										? "bg-brand-900 text-mint-500"
										: "text-[#6b7c7c]"
								}`}
								onClick={() => setBasemap("standard")}
							>
								{isRTL ? "خريطة" : "Map"}
							</button>
						</div>
						<button
							type="button"
							onClick={locateUser}
							className="inline-flex h-8 items-center gap-1 rounded-lg border border-[#e6eef0] px-2 text-[12px] font-bold text-brand-900"
							data-testid="intelligence-map-locate-desktop"
						>
							<Navigation className="size-3.5" />
							{isRTL ? "موقعي" : "My location"}
						</button>
					</div>
				</div>

				<div className="h-full min-h-[50vh]" data-testid="intelligence-map-canvas-wrap">
					<Suspense
						fallback={
							<div className="flex h-full items-center justify-center text-ink-muted">
								{isRTL ? "نحمّل الخريطة…" : "Loading map…"}
							</div>
						}
					>
						<FarqMap
							places={visiblePlaces}
							neighborhoods={hoods}
							selectedPlaceId={placeId}
							selectedNeighborhoodId={neighborhoodId}
							focusRequest={focusRequest}
							userLocation={userLocation}
							showUserLocation={showUserDot}
							placeDetail={placeDetail}
							basemap={basemap}
							onBasemapChange={setBasemap}
							isRTL={isRTL}
							onSelectPlace={(id) =>
								patchSearch({ place: id, neighborhood: undefined })
							}
							onSelectNeighborhood={(id) =>
								patchSearch({ neighborhood: id, place: undefined })
							}
							onViewChange={onViewChange}
							sheetOpen={Boolean(placeId)}
						/>
					</Suspense>
				</div>

				{placeId ? (
					<div
						className="farq-map-place-host absolute inset-x-0 bottom-0 z-[520] lg:hidden"
						data-testid="intelligence-map-place-backdrop"
					>
						<SelectedPlaceSheet
							variant="sheet"
							placeDetail={placeDetail}
							feature={selectedPlaceFeature?.properties}
							selectedCategory={selectedCategory}
							selectedRestaurantId={selectedRestaurantId}
							isRTL={isRTL}
							onClose={() =>
								patchSearch({ neighborhood: undefined, place: undefined })
							}
							onOpenMenu={openRestaurantMenu}
						/>
					</div>
				) : null}

				{!placeId ? (
					<div
						className="farq-map-around lg:hidden"
						data-testid="intelligence-map-around"
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
							<button
								type="button"
								className="flex min-h-11 w-full items-center justify-between gap-3 px-3 py-2"
								data-testid="intelligence-map-around-peek"
								onClick={() => {
									if (aroundMax) {
										focusAroundPlace(aroundMax);
										return;
									}
									setAroundOpen((v) => !v);
								}}
							>
								<span className="text-[13px] font-bold text-brand-900">
									{isRTL ? "أكبر فرق حولك" : "Biggest gap around you"}
								</span>
								<span className="shrink-0 text-[13px] font-black text-brand-900">
									{aroundMax
										? `+${localizeDigitString(String(Math.round(aroundMax.amount)), isRTL)} ${isRTL ? "ر.س" : "SAR"}`
										: "—"}
								</span>
							</button>
							<button
								type="button"
								className="flex h-11 w-full items-center justify-center border-t border-[#e6eef0] text-[12px] font-bold text-[#6b7c7c]"
								aria-expanded={aroundOpen}
								onClick={() => setAroundOpen((v) => !v)}
							>
								{isRTL
									? aroundOpen
										? "إخفاء القائمة"
										: "عرض القائمة"
									: aroundOpen
										? "Hide list"
										: "Show list"}
							</button>
							{aroundOpen ? (
								<ul
									className="max-h-48 space-y-1 overflow-y-auto border-t border-[#e6eef0] p-2"
									data-testid="intelligence-map-top-savings"
								>
									{topSavings.slice(0, 8).map((row) => (
										<li key={row.placeId}>
											<button
												type="button"
												className="flex min-h-11 w-full items-center justify-between gap-3 rounded-xl bg-[#e6eef0] px-3 py-2 text-start"
												data-testid="intelligence-map-top-saving"
												onClick={() => focusAroundPlace(row)}
											>
												<span className="min-w-0 truncate text-[13px] font-bold text-brand-900">
													{row.name || (isRTL ? "مطعم" : "Restaurant")}
												</span>
												<span className="shrink-0 text-[13px] font-black text-brand-900">
													+
													{localizeDigitString(
														String(Math.round(row.amount)),
														isRTL,
													)}{" "}
													{isRTL ? "ر.س" : "SAR"}
												</span>
											</button>
										</li>
									))}
								</ul>
							) : null}
						</div>
					</div>
				) : null}

				<div className="farq-map-tools farq-map-tools--mobile lg:hidden">
					<button
						type="button"
						onClick={locateUser}
						className="farq-map-tools-btn"
						data-testid="intelligence-map-locate"
						aria-label={isRTL ? "موقعي" : "My location"}
					>
						<Navigation className="size-4" />
					</button>
					<button
						type="button"
						className="farq-map-tools-btn farq-legend-info"
						aria-expanded={legendOpen}
						aria-controls="farq-map-legend"
						data-testid="intelligence-map-legend-info"
						onClick={() => setLegendOpen((v) => !v)}
						aria-label={isRTL ? "دليل الخريطة" : "Map legend"}
					>
						<Info className="size-4" />
					</button>
				</div>

				<div className="pointer-events-auto absolute bottom-3 start-3 z-[400] hidden lg:block">
					<button
						type="button"
						className="farq-legend-info"
						aria-expanded={legendOpen}
						aria-controls="farq-map-legend"
						onClick={() => setLegendOpen((v) => !v)}
						aria-label={isRTL ? "دليل الخريطة" : "Map legend"}
					>
						<Info className="size-4" />
					</button>
				</div>
				{legendOpen ? (
					<div className="pointer-events-auto absolute bottom-24 start-3 z-[450] lg:bottom-14">
						<div
							id="farq-map-legend"
							className="farq-legend-popover text-[12px]"
							data-testid="intelligence-map-legend"
						>
							<p className="mb-2 text-right text-[13px] font-bold text-brand-900">
								{isRTL ? "دليل طبقة المقارنة" : "Comparison layer legend"}
							</p>
							<ul className="space-y-2 text-[#6b7c7c]">
								<li className="flex items-center gap-2">
									<span className="farq-legend-bubble" aria-hidden>
										<FarqBrandMark variant="circle" size={10} />
										<span className="farq-legend-win">
											{isRTL ? "+١٨" : "+18"}
										</span>
									</span>
									<span>
										{isRTL
											? "هالة فرق السعر المرصود"
											: "Observed price-difference aura"}
									</span>
								</li>
								<li className="flex items-center gap-2">
									<span className="farq-legend-dot" aria-hidden />
									<span>
										{isRTL
											? "مطعم بدون فرق مرصود"
											: "Restaurant without an observed gap"}
									</span>
								</li>
								<li className="flex items-center gap-2">
									<span className="farq-legend-3d-cluster" aria-hidden />
									<span>
										{isRTL
											? "تجمّع فرص (قم بالتقريب للهالات)"
											: "Opportunity clusters (zoom in to see auras)"}
									</span>
								</li>
							</ul>
							<p className="mt-2 text-[10px] font-bold text-brand-900">
								{isRTL ? "«حجم الدبوس = حجم الفرق»" : "«Pin size = gap size»"}
							</p>
						</div>
					</div>
				) : null}
			</div>

			<aside
				className={`hidden w-full flex-col overflow-hidden border-s border-[#e6eef0] bg-white lg:flex lg:w-[27rem] lg:shrink-0 lg:rounded-none ${
					placeId ? "farq-place-panel-host" : ""
				}`}
			>
				{placeId ? (
					<SelectedPlaceSheet
						variant="panel"
						placeDetail={placeDetail}
						feature={selectedPlaceFeature?.properties}
						selectedCategory={selectedCategory}
						selectedRestaurantId={selectedRestaurantId}
						isRTL={isRTL}
						onClose={() =>
							patchSearch({ neighborhood: undefined, place: undefined })
						}
						onOpenMenu={openRestaurantMenu}
					/>
				) : (
					<>
					<div className="flex items-center justify-between border-b border-[#e6eef0] px-5 py-4">
						<h2 className="min-w-0 truncate text-[16px] font-bold text-brand-900">
							{selectedHood
								? `${isRTL ? "تفاصيل الحي" : "Neighborhood detail"} · ${selectedHood.properties.neighborhood_ar || selectedHood.properties.neighborhood_en}`
								: isRTL
									? "تفاصيل الفرق"
									: "Farq difference"}
						</h2>
						{neighborhoodId ? (
							<button
								type="button"
								className="rounded-full p-1 text-[#6b7c7c] hover:bg-[#e6eef0]"
								aria-label={isRTL ? "إغلاق" : "Close"}
								onClick={() =>
									patchSearch({ neighborhood: undefined, place: undefined })
								}
							>
								<X className="h-4 w-4" />
							</button>
						) : null}
					</div>
				<div className="flex-1 space-y-4 overflow-y-auto">
					<div className="space-y-4 p-5">
					{!neighborhoodId ? (
						<div className="space-y-4">
						<p className="text-[13px] text-[#6b7c7c]">
							{isRTL
								? "اضغط فقاعة فرق لفتح لحظة الفرق — الوجبة، الفرق المرصود، ثم التطبيقات. إذا ما فيه فرق مرصود لن نخترع رقماً ولن نخترع إحداثيات."
								: "Tap a price-difference bubble to open the Farq moment — meal, observed gap, then apps. We never invent a فرق amount or coordinates."}
						</p>
						{topSavings.length ? (
							<div data-testid="intelligence-map-top-savings">
								<h3 className="mb-2 text-[13px] font-bold text-brand-900">
									{isRTL ? "أكبر الفروقات هنا" : "Biggest gaps here"}
								</h3>
								<ul className="space-y-1.5">
									{topSavings.map((row) => (
										<li key={row.placeId}>
											<button
												type="button"
												className="flex w-full items-center justify-between gap-3 rounded-xl bg-[#e6eef0] px-3 py-2 text-start"
												data-testid="intelligence-map-top-saving"
												onClick={() => {
													lastFocusedPlaceRef.current = row.placeId;
													setFocusRequest({
														lat: row.lat,
														lng: row.lng,
														id: `place:${row.placeId}`,
													});
													patchSearch({
														place: row.placeId,
														neighborhood: undefined,
													});
												}}
											>
												<span className="min-w-0 truncate text-[13px] font-bold text-brand-900">
													{row.name ||
														(isRTL ? "مطعم" : "Restaurant")}
												</span>
												<span className="shrink-0 text-[13px] font-black text-brand-900">
													+
													{localizeDigitString(
														String(Math.round(row.amount)),
														isRTL,
													)}{" "}
													{isRTL ? "ر.س" : "SAR"}
												</span>
											</button>
										</li>
									))}
								</ul>
							</div>
						) : null}
						</div>
					) : winner && !promote ? (
						<div
							className="rounded-2xl bg-surface-2 p-4"
							data-testid="intelligence-map-caution"
						>
							<p className="font-bold text-ink">
								{winner.consumer_message_ar ||
									(isRTL
										? "بيانات غير كافية — لا يمكن تحديد الفائز"
										: "Insufficient data — no champion")}
							</p>
						</div>
					) : winner && promote ? (
						<div className="rounded-2xl bg-brand-900 p-5 text-white">
							<p className="text-[12px] text-mint-500">
								{isRTL ? "ثقة كافية للعرض" : "Promoted in consumer UI"}
							</p>
							<p className="mt-2 text-4xl font-extrabold tabular-nums">
								{localizeDigitString(fmtScore(winner.overall_score), isRTL)}
							</p>
							<p className="mt-1 text-[13px] text-white/70">
								{isRTL ? "نقاط الجدارة الكلية" : "Overall merit"}
							</p>
							<div className="mt-4 flex items-center gap-2">
								<ProviderLogoMark
									provider={winner.provider_id}
									label={winner.provider_name_ar}
									isRTL={isRTL}
									size={32}
									rounded="md"
									tintedFallback
								/>
								<div>
									<p className="font-bold">
										{winner.provider_name_ar || winner.provider_id}
									</p>
									<p className="text-[12px] text-white/70">
										{winner.consumer_message_ar}
									</p>
								</div>
							</div>
						</div>
					) : (
						<p className="text-[13px] text-ink-muted">
							{isRTL ? "لا تفاصيل لهذه الخلية." : "No detail for this cell."}
						</p>
					)}

					{promote && winner?.podium ? (
						<div>
							<h3 className="mb-2 text-[13px] font-bold text-ink">
								{isRTL ? "ترتيب منصات التوصيل" : "Platform ranking"}
							</h3>
							{[
								[winner.podium.rank_1, winner.podium.rank_1_name_ar, winner.podium.rank_1_score],
								[winner.podium.rank_2, winner.podium.rank_2_name_ar, winner.podium.rank_2_score],
								[winner.podium.rank_3, winner.podium.rank_3_name_ar, winner.podium.rank_3_score],
							].map(([id, name, score]) =>
								id ? (
									<div key={String(id)} className="mb-2 flex items-center gap-2">
										<ProviderLogoMark
											provider={id}
											label={name == null ? undefined : String(name)}
											isRTL={isRTL}
											size={16}
											tintedFallback
										/>
										<span
											className={`h-2 flex-1 rounded-full ${providerTintClass(String(id))}`}
											style={{
												maxWidth: `${Math.min(100, Number(score) || 0)}%`,
											}}
										/>
										<span className="w-28 truncate text-[12px]">
											{String(name || id)} · {localizeDigitString(fmtScore(score), isRTL)}
										</span>
									</div>
								) : null,
							)}
						</div>
					) : null}
					</div>
				</div>
				<div className="border-t border-[#e6eef0] bg-[#f9fafb] p-4">
					{groceryCta ? (
						<Button
							asChild
							variant="primary"
							className="w-full text-mint-500"
						>
							<Link
								to={compareTo}
								search={compareSearch}
								data-testid="intelligence-map-compare"
							>
								{isRTL
									? "شف الفرق وقارن الأسعار في فرق"
									: "See the gap and compare on Farq"}
							</Link>
						</Button>
					) : (
						<Button
							asChild
							variant="primary"
							className="w-full text-mint-500"
						>
							<Link
								to="/"
								search={compareSearch}
								data-testid="intelligence-map-compare"
							>
								{isRTL
									? "شف الفرق وقارن الأسعار في فرق"
									: "See the gap and compare on Farq"}
							</Link>
						</Button>
					)}
					<p className="mt-2 text-[11px] text-[#6b7c7c]">
						{isRTL
							? "يفتح مقارنة فرق الحالية — بدون سكّ place_id."
							: "Opens the live Farq compare flow — no new place_id."}
					</p>
				</div>
					</>
				)}
			</aside>
		</div>
	);
}
