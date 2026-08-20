/**
 * Figma map-desktop-split (2:620) — Mapbox GL + Farq difference panel.
 * Pins come from comparison.discovery_cards via /api/intelligence/map/places
 * (layer=comparison: product-ready restaurants with real lat/lng).
 * Pin tap opens a premium sheet/panel; CTA «افتح الأرخص» goes to
 * /merchant/restaurant/:id (same as a home card).
 * Neighborhoods are fetched for the side panel; optional GIS outlines (Golden NCP)
 * can be stroked from the drawer — never a choropleth mosaic.
 * Never invents lat/lon; never remints Golden place_id.
 */
import { Link, useNavigate, useRouterState } from "@tanstack/react-router";
import {
	ChevronDown,
	ChevronLeft,
	ChevronRight,
	Info,
	MapPin,
	Navigation,
	Search,
	X,
} from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { localizeCity } from "../../lib/cityNames";
import {
	differenceFromPinProps,
	pinFetchCapForZoom,
} from "../../lib/farqMapPins";
import { pinGapAmount } from "../../lib/farqPriceTiles";
import {
	TOP_OPPORTUNITIES,
	topOpportunities,
	withObservedDistances,
	type OpportunityRow,
} from "../../lib/farqOpportunities";
import {
	shouldOfferSearchHere,
	type MapViewChangeMeta,
} from "../../lib/farqMapViewport";
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
import type { MapSearch, MapSort, MapViewMode } from "../../routes/map";
import { resolveMapSort, resolveMapView } from "../../routes/map";
import MapAskChat from "./MapAskChat";
import FarqExploreChrome, {
	EXPLORE_ZOOM,
	type ExploreRadius,
	type FilterRailId,
	type MapLayerId,
	type SheetSnap,
} from "./FarqExploreChrome";
import FarqViewSortBar from "./FarqViewSortBar";
import FarqOpportunityList, { FarqOpportunityCard } from "./FarqOpportunityList";
import SelectedPlaceSheet from "./SelectedPlaceSheet";
import "../../styles/farq-mapbox.css";

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
		locationError,
		isLocating,
		requestLocation,
		dismissError,
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
	const fetchedViewRef = useRef<{ bbox: string; zoom: number } | null>(null);
	const intentionalFetchRef = useRef(false);
	const placesAbortRef = useRef<AbortController | null>(null);
	const placesRef = useRef<IntelligenceMapPlaces | null>(null);
	const lastFocusedPlaceRef = useRef<string>("");
	const pendingLocateRef = useRef(false);
	const [livePlaceId, setLivePlaceId] = useState(search.place || "");
	const [searchHere, setSearchHere] = useState(false);
	const [focusRequest, setFocusRequest] = useState<{
		lat: number;
		lng: number;
		id: string;
		zoom?: number;
		kind?: "select" | "locate" | "cluster";
	} | null>(null);
	const [leftUserLocation, setLeftUserLocation] = useState(false);
	const [basemap, setBasemap] = useState<MapboxBasemap>("standard");
	const [majorGapsOnly, setMajorGapsOnly] = useState(true);
	const [legendOpen, setLegendOpen] = useState(false);
	const [retryTick, setRetryTick] = useState(0);
	const [drawerOpen, setDrawerOpen] = useState(false);
	const [gisHoodsOn, setGisHoodsOn] = useState(false);
	const [overlayHoods, setOverlayHoods] =
		useState<IntelligenceMapNeighborhoods | null>(null);
	const [exploreRadius, setExploreRadius] = useState<ExploreRadius>("hawally");
	const pendingRadiusRef = useRef<ExploreRadius | null>(null);
	const [rail, setRail] = useState<FilterRailId>("restaurants");
	const [sheetSnap, setSheetSnap] = useState<SheetSnap>("peek");
	const [comparePanelHidden, setComparePanelHidden] = useState(false);
	const [searchFocused, setSearchFocused] = useState(false);
	const chromeHideTimerRef = useRef(0);
	const splitRef = useRef<HTMLDivElement | null>(null);
	const [layers, setLayers] = useState<Record<MapLayerId, boolean>>({
		opportunities: true,
		restaurants: false,
		providers: false,
		prices: true,
		delivery: false,
	});
	const [scanHint, setScanHint] = useState<"searching" | "ready" | null>(null);
	const [placesFetching, setPlacesFetching] = useState(false);
	const filterKeyRef = useRef("");
	const scanTimerRef = useRef(0);

	const categoryId = toIntelCategoryId(search.category) || "";
	const neighborhoodId = search.neighborhood || "";
	const city = search.city || "";
	const placeId = search.place || "";
	const q = search.q || "";
	const pathname = useRouterState({ select: (s) => s.location.pathname });
	const view = resolveMapView(search, pathname);
	const sort = resolveMapSort(search);

	const patchSearch = useCallback(
		(next: Partial<MapSearch>) => {
			void navigate({
				to: pathname === "/" ? "/" : "/map",
				search: (prev: MapSearch) => ({
					neighborhood:
						"neighborhood" in next ? next.neighborhood : prev.neighborhood,
					category: "category" in next ? next.category : prev.category,
					city: "city" in next ? next.city : prev.city,
					q: "q" in next ? next.q : prev.q,
					place: "place" in next ? next.place : prev.place,
					view: "view" in next ? next.view : prev.view,
					sort: "sort" in next ? next.sort : prev.sort,
				}),
			});
		},
		[navigate, pathname],
	);

	useEffect(() => {
		setMapQuery(search.q || "");
	}, [search.q]);

	useEffect(() => {
		setLivePlaceId(placeId);
	}, [placeId]);

	useEffect(() => {
		let cancelled = false;
		const controller = new AbortController();
		setLoading(true);
		setError(null);
		void IntelligenceService.meta(controller.signal)
			.then((m) => {
				if (cancelled) return;
				setMeta(m);
				if (!search.city) {
					patchSearch({ city: "Riyadh" });
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
		if (!placesRef.current) setPlacesFetching(true);
		fetchedViewRef.current = { bbox, zoom };
		setSearchHere(false);
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
			limit: pinFetchCapForZoom(zoom),
			fields: "pin",
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
		(bbox: string, zoom: number, meta?: MapViewChangeMeta) => {
			const next = { bbox, zoom };
			viewRef.current = next;
			if (!fetchedViewRef.current) {
				fetchPlaces(bbox, zoom);
				return;
			}
			if (intentionalFetchRef.current) {
				intentionalFetchRef.current = false;
				fetchPlaces(bbox, zoom);
				return;
			}
			const offer = shouldOfferSearchHere({
				userGesture: Boolean(meta?.userGesture),
				hasFetched: true,
				fetched: fetchedViewRef.current,
				current: next,
			});
			setSearchHere((cur) => (cur === offer ? cur : offer));
		},
		[fetchPlaces],
	);

	const searchThisView = useCallback(() => {
		const v = viewRef.current;
		if (v) fetchPlaces(v.bbox, v.zoom);
	}, [fetchPlaces]);

	const getViewportBbox = useCallback(() => viewRef.current?.bbox || "", []);

	useEffect(() => {
		const key = `${categoryId}|${q}`;
		if (filterKeyRef.current && filterKeyRef.current !== key) {
			setPlaces(null);
			setSheetSnap("peek");
			setScanHint("searching");
		}
		filterKeyRef.current = key;
	}, [categoryId, q]);

	useEffect(() => {
		const v = viewRef.current;
		if (v) fetchPlaces(v.bbox, v.zoom);
	}, [fetchPlaces]);

	useEffect(() => {
		if (drawerOpen || searchFocused || sheetSnap === "expanded") {
			splitRef.current?.removeAttribute("data-chrome-hidden");
		}
	}, [drawerOpen, searchFocused, sheetSnap]);

	useEffect(() => {
		return () => {
			window.clearTimeout(scanTimerRef.current);
			window.clearTimeout(chromeHideTimerRef.current);
		};
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
		if (!gisHoodsOn) return;
		const controller = new AbortController();
		void IntelligenceService.mapNeighborhoods({
			city: city || "Riyadh",
			signal: controller.signal,
		})
			.then(setOverlayHoods)
			.catch(() => setOverlayHoods(null));
		return () => controller.abort();
	}, [gisHoodsOn, city]);

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
		lastFocusedPlaceRef.current = placeId;
		/* Pin click must not wait for this network + camera. List focus sets focusRequest itself. */
	}, [placeDetail, placeId]);

	useEffect(() => {
		if (!pendingLocateRef.current || !userLocation) return;
		if (locationPinKind !== "gps" && locationPinKind !== "manual") return;
		pendingLocateRef.current = false;
		const radius = pendingRadiusRef.current;
		pendingRadiusRef.current = null;
		intentionalFetchRef.current = true;
		setFocusRequest({
			lat: userLocation.lat,
			lng: userLocation.lng,
			id: `locate:${Date.now()}`,
			kind: "locate",
			...(radius ? { zoom: EXPLORE_ZOOM[radius] } : {}),
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
		(f) => String(f.properties.place_id) === String(livePlaceId),
	);
	const selectedRestaurantId =
		placeDetail?.restaurant_id ||
		placeDetail?.menu?.id ||
		selectedPlaceFeature?.properties.restaurant_id ||
		selectedPlaceFeature?.properties.menu?.id ||
		(/^\d+$/.test(livePlaceId) ? livePlaceId : "");

	const showUserDot = locationPinKind === "gps" || locationPinKind === "manual";
	placesRef.current = places;

	const visiblePlaces = useMemo(() => {
		if (!places) return places;
		const gapsOnly = true;
		return {
			...places,
			features: places.features.filter((f) => {
				const isCluster = f.properties.feature_type === "cluster";
				const amount = pinGapAmount(f.properties);
				const hasGap = isCluster
					? Number(f.properties.difference_count || 0) > 0
					: Boolean(f.properties.has_difference) || amount != null;
				if (!layers.opportunities && hasGap) return false;
				if (gapsOnly) return hasGap;
				return true;
			}),
		};
	}, [places, layers.opportunities]);

	const viewportSavings = useMemo(() => {
		const rows: OpportunityRow[] = [];
		for (const f of visiblePlaces?.features || []) {
			if (f.properties.feature_type === "cluster") continue;
			const placeId = String(f.properties.place_id || "").trim();
			if (!placeId) continue;
			const amount = pinGapAmount(f.properties);
			if (amount == null) continue;
			const coords = f.geometry?.coordinates;
			if (!Array.isArray(coords) || coords.length < 2) continue;
			const lng = Number(coords[0]);
			const lat = Number(coords[1]);
			if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
			const diff = differenceFromPinProps(f.properties);
			const cheap = Number(
				f.properties.cheapest_price ??
					(diff && "cheapest_price" in diff ? diff.cheapest_price : NaN),
			);
			const expensive = Number(
				f.properties.expensive_price ??
					(diff && "expensive_price" in diff ? diff.expensive_price : NaN),
			);
			const product =
				String(
					f.properties.product_name ||
						(diff && "product_name" in diff ? diff.product_name : "") ||
						"",
				).trim() || null;
			rows.push({
				placeId,
				name: String(f.properties.name || "").trim(),
				amount,
				lat,
				lng,
				cheapestPrice: Number.isFinite(cheap) ? cheap : null,
				expensivePrice: Number.isFinite(expensive) ? expensive : null,
				productName: product,
				cheapestProvider:
					String(
						f.properties.cheapest_provider_id ||
							diff?.cheapest_provider_id ||
							"",
					).trim() || null,
				expensiveProvider:
					String(
						f.properties.expensive_provider_id ||
							(diff && "expensive_provider_id" in diff
								? diff.expensive_provider_id
								: "") ||
							"",
					).trim() || null,
			});
		}
		const located =
			showUserDot && userLocation
				? withObservedDistances(rows, userLocation.lat, userLocation.lng)
				: rows;
		return located;
	}, [visiblePlaces, showUserDot, userLocation]);

	const cheapestReady = useMemo(
		() => viewportSavings.some((row) => row.cheapestPrice != null),
		[viewportSavings],
	);
	const nearReady = Boolean(showUserDot && userLocation);

	const opportunityList = useMemo(
		() => topOpportunities(viewportSavings, sort, TOP_OPPORTUNITIES),
		[viewportSavings, sort],
	);

	const topSavings = opportunityList;

	const displayPlaces = useMemo(() => {
		if (!visiblePlaces) return visiblePlaces;
		const ids = new Set(topSavings.map((row) => row.placeId));
		if (livePlaceId) ids.add(livePlaceId);
		return {
			...visiblePlaces,
			count: topSavings.length,
			features: visiblePlaces.features.filter((f) =>
				ids.has(String(f.properties.place_id || "")),
			),
		};
	}, [visiblePlaces, topSavings, livePlaceId]);

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

	const aroundMax = topSavings[0] || null;

	const locateUser = useCallback(() => {
		pendingLocateRef.current = true;
		dismissError();
		/* Always getCurrentPosition in this click turn (iOS Safari). */
		requestLocation();
		if (locationPinKind === "gps" && userLocation) {
			intentionalFetchRef.current = true;
			setFocusRequest({
				lat: userLocation.lat,
				lng: userLocation.lng,
				id: `locate:${Date.now()}`,
				kind: "locate",
			});
			setLeftUserLocation(false);
		}
	}, [dismissError, locationPinKind, requestLocation, userLocation]);

	const applyCategory = useCallback(
		(nextId: string) => {
			setPlaces(null);
			setScanHint("searching");
			setDrawerOpen(false);
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

	const applyRail = useCallback(
		(next: FilterRailId) => {
			setRail(next);
			if (next === "gaps") {
				setMajorGapsOnly(true);
				patchSearch({ sort: "gap" });
				return;
			}
			if (next === "cheapest") {
				setMajorGapsOnly(false);
				patchSearch({ sort: "cheap" });
				return;
			}
			setMajorGapsOnly(false);
			if (next === "grocery") {
				applyCategory("grocery");
				return;
			}
			if (next === "restaurants") {
				applyCategory("");
			}
		},
		[applyCategory, patchSearch],
	);

	const toggleLayer = useCallback((id: MapLayerId) => {
		setLayers((cur) => ({ ...cur, [id]: !cur[id] }));
	}, []);

	const onMapInteraction = useCallback((phase: "start" | "end") => {
		if (drawerOpen || searchFocused || sheetSnap === "expanded") return;
		const root = splitRef.current;
		window.clearTimeout(chromeHideTimerRef.current);
		if (phase === "start") {
			root?.setAttribute("data-chrome-hidden", "true");
			return;
		}
		chromeHideTimerRef.current = window.setTimeout(() => {
			root?.removeAttribute("data-chrome-hidden");
		}, 900);
	}, [drawerOpen, searchFocused, sheetSnap]);

	const focusAroundPlace = useCallback(
		(row: { placeId: string; lat: number; lng: number }) => {
			lastFocusedPlaceRef.current = row.placeId;
			setLivePlaceId(row.placeId);
			setFocusRequest({
				lat: row.lat,
				lng: row.lng,
				id: `place:${row.placeId}`,
				kind: "select",
			});
			patchSearch({
				place: row.placeId,
				neighborhood: undefined,
			});
			setSheetSnap("peek");
			setComparePanelHidden(false);
			setDrawerOpen(false);
		},
		[patchSearch],
	);

	const applyView = useCallback(
		(next: MapViewMode) => {
			patchSearch({ view: next });
			if (next !== "map") return;
			const row = topSavings.find((item) => item.placeId === livePlaceId);
			if (!row) return;
			setFocusRequest({
				lat: row.lat,
				lng: row.lng,
				id: `place:${row.placeId}`,
				kind: "select",
			});
		},
		[patchSearch, topSavings, livePlaceId],
	);

	const applySort = useCallback(
		(next: MapSort) => {
			if (next === "near" && !nearReady) locateUser();
			patchSearch({ sort: next });
			if (next === "gap") setMajorGapsOnly(true);
			if (next === "cheap" || next === "near") setRail(next === "cheap" ? "cheapest" : "gaps");
		},
		[locateUser, nearReady, patchSearch],
	);

	const applyExploreRadius = useCallback(
		(next: ExploreRadius) => {
			setExploreRadius(next);
			if (
				userLocation &&
				(locationPinKind === "gps" || locationPinKind === "manual")
			) {
				intentionalFetchRef.current = true;
				setFocusRequest({
					lat: userLocation.lat,
					lng: userLocation.lng,
					id: `radius:${next}:${Date.now()}`,
					kind: "locate",
					zoom: EXPLORE_ZOOM[next],
				});
				return;
			}
			pendingRadiusRef.current = next;
			locateUser();
		},
		[userLocation, locationPinKind, locateUser],
	);

	const selectedTopIndex = opportunityList.findIndex((row) => row.placeId === livePlaceId);

	const closePlace = useCallback(() => {
		setLivePlaceId("");
		patchSearch({ neighborhood: undefined, place: undefined });
	}, [patchSearch]);
	const stepOpportunity = useCallback(
		(dir: -1 | 1) => {
			if (selectedTopIndex < 0) return;
			const next = opportunityList[selectedTopIndex + dir];
			if (next) focusAroundPlace(next);
		},
		[selectedTopIndex, opportunityList, focusAroundPlace],
	);

	if (error && !meta) {
		return (
			<div className="farq-map-split farq-map-split--message px-4 py-10" data-testid="intelligence-map-error">
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

	const readyMeta = meta;
	const hasViewportPlaces = Boolean(visiblePlaces?.features?.length);

	return (
		<div
			ref={splitRef}
			dir={isRTL ? "rtl" : "ltr"}
			className={`farq-map-split lg:flex lg:min-h-[calc(100dvh-56px)] ${
				isRTL ? "lg:flex-row-reverse" : "lg:flex-row"
			}`}
			data-testid="intelligence-map-split"
			data-view={view}
			data-sheet-open={livePlaceId && !comparePanelHidden ? "true" : undefined}
			data-sheet-snap={livePlaceId ? undefined : sheetSnap}
			data-panel-collapsed={comparePanelHidden ? "true" : undefined}
			data-legend-open={legendOpen ? "true" : undefined}
			data-drawer-open={drawerOpen ? "true" : undefined}
			data-hide-prices={layers.prices ? undefined : "true"}
		>
			<div className="farq-map-stage">
				<FarqExploreChrome
					isRTL={isRTL}
					language={language}
					languageSwitching={languageSwitching}
					onToggleLanguage={toggleLanguage}
					mapQuery={mapQuery}
					onMapQueryChange={setMapQuery}
					onSearchSubmit={(q) =>
						patchSearch({ q: q || undefined, place: undefined })
					}
					rail={rail}
					onRail={applyRail}
					categoryId={categoryId}
					onApplyCategory={applyCategory}
					majorGapsOnly={majorGapsOnly}
					onToggleMajorGaps={() => setMajorGapsOnly((v) => !v)}
					drawerOpen={drawerOpen}
					onDrawerOpenChange={setDrawerOpen}
					cities={readyMeta?.geo_readiness?.ncp_ready_cities || []}
					city={city}
					onCityChange={(next) =>
						patchSearch({
							city: next || undefined,
							neighborhood: undefined,
						})
					}
					categoryGroups={categoryGroups}
					gisHoodsOn={gisHoodsOn}
					onToggleGisHoods={() => setGisHoodsOn((v) => !v)}
					layers={layers}
					onToggleLayer={toggleLayer}
					exploreRadius={exploreRadius}
					onExploreRadius={applyExploreRadius}
					aroundMax={aroundMax}
					topSavings={topSavings}
					sheetSnap={sheetSnap}
					onSheetSnap={setSheetSnap}
					placesFetching={placesFetching}
					scanHint={scanHint}
					hasViewportPlaces={hasViewportPlaces}
					placesReady={places != null}
					chromeHidden={false}
					searchFocused={searchFocused}
					onSearchFocused={setSearchFocused}
					onLocate={locateUser}
					locateBusy={isLocating}
					onFocusPlace={focusAroundPlace}
					showHereHint={showUserDot}
					leftUserLocation={leftUserLocation}
					placeSelected={Boolean(livePlaceId)}
					cheapestReady={cheapestReady}
					nearReady={nearReady}
					view={view}
					onView={applyView}
					sort={sort}
					onSort={applySort}
					onNeedLocation={locateUser}
					basemap={basemap}
					onBasemapChange={setBasemap}
					legendOpen={legendOpen}
					onLegendOpenChange={setLegendOpen}
				/>

				{readyMeta ? <div className="absolute inset-x-3 top-3 z-[500] hidden flex-col gap-3 rounded-2xl bg-white p-4 shadow-[0_8px_8px_rgba(0,0,0,0.1)] lg:flex lg:flex-row lg:items-center lg:justify-between lg:gap-4 lg:py-3">
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
									{(readyMeta.geo_readiness?.ncp_ready_cities || []).map((c) => (
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
								{(readyMeta.geo_readiness?.ncp_ready_cities || []).map((c) => (
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
										? "ابحث عن وجبة أو فرصة…"
										: "Search a dish or opportunity…"
								}
								className="h-7 min-w-0 flex-1 bg-transparent text-[14px] text-brand-900 placeholder:text-[#6b7c7c] lg:max-w-[14rem]"
								data-testid="intelligence-map-search"
								aria-label={isRTL ? "بحث على الخريطة" : "Search the map"}
							/>
						</form>
					</div>
					<FarqViewSortBar
						view={view}
						onView={applyView}
						sort={sort}
						onSort={applySort}
						isRTL={isRTL}
						nearReady={nearReady}
						cheapReady={cheapestReady}
						onNeedLocation={locateUser}
					/>
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
									<option value="">
										{isRTL ? "كل المطاعم" : "All restaurants"}
									</option>
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
							className="inline-flex min-h-11 items-center gap-1 rounded-lg border border-[#e6eef0] px-2 text-[12px] font-bold text-brand-900"
							data-testid="intelligence-map-locate-desktop"
							aria-busy={isLocating}
						>
							<Navigation className="size-3.5" />
							{isLocating
								? isRTL
									? "نحدد موقعك…"
									: "Locating…"
								: isRTL
									? "موقعي"
									: "My location"}
						</button>
					</div>
				</div> : null}



				<div className="farq-map-canvas" data-testid="intelligence-map-canvas-wrap">
					{view === "list" ? (
						<FarqOpportunityList
							rows={topSavings}
							isRTL={isRTL}
							selectedPlaceId={livePlaceId}
							onSelect={focusAroundPlace}
							empty={
								Boolean(places) &&
								!placesFetching &&
								topSavings.length === 0
							}
							countLabel={
								topSavings.length
									? isRTL
										? `أفضل ${localizeDigitString(String(topSavings.length), true)} فرص حولك`
										: `Top ${topSavings.length} opportunities around you`
									: undefined
							}
						/>
					) : null}
					<div
						className={view === "list" ? "farq-map-canvas-keep" : undefined}
						aria-hidden={view === "list" ? true : undefined}
					>
					<Suspense
						fallback={
							<div className="flex h-full items-center justify-center text-ink-muted">
								{isRTL ? "نحمّل الخريطة…" : "Loading map…"}
							</div>
						}
					>
						<FarqMap
							places={displayPlaces}
							neighborhoods={hoods}
							gisNeighborhoods={gisHoodsOn ? overlayHoods : null}
							selectedPlaceId={livePlaceId}
							selectedNeighborhoodId={neighborhoodId}
							focusRequest={focusRequest}
							userLocation={userLocation}
							showUserLocation={showUserDot}
							placeDetail={placeDetail}
							basemap={basemap}
							onBasemapChange={setBasemap}
							isRTL={isRTL}
							onSelectPlace={(id) => {
								setLivePlaceId(id);
								lastFocusedPlaceRef.current = id;
								setComparePanelHidden(false);
								patchSearch({ place: id, neighborhood: undefined });
							}}
							onSelectNeighborhood={(id) =>
								patchSearch({ neighborhood: id, place: undefined })
							}
							onViewChange={onViewChange}
							sheetOpen={Boolean(livePlaceId) && !comparePanelHidden}
							onMapInteraction={onMapInteraction}
							onLeftUserLocation={setLeftUserLocation}
						/>
					</Suspense>
					</div>
					{locationError ? (
						<div
							role="alert"
							aria-live="polite"
							className="farq-map-locate-error"
							data-testid="intelligence-map-locate-error"
						>
							<p>{locationError}</p>
							<button
								type="button"
								onClick={dismissError}
								aria-label={isRTL ? "إغلاق" : "Dismiss"}
							>
								<X className="size-3.5" />
							</button>
						</div>
					) : null}
					{searchHere && !livePlaceId && view === "map" ? (
						<button
							type="button"
							className="farq-search-here"
							data-testid="intelligence-map-search-here"
							onClick={searchThisView}
						>
							{isRTL ? "ابحث في هذه المنطقة" : "Search this area"}
						</button>
					) : null}
					{view === "map" ? (
					<MapAskChat
						isRTL={isRTL}
						language={language}
						getViewportBbox={getViewportBbox}
						selectedPlaceName={
							placeDetail?.name ||
							selectedPlaceFeature?.properties.name ||
							""
						}
						userLat={
							(locationPinKind === "gps" || locationPinKind === "manual") &&
							userLocation
								? userLocation.lat
								: undefined
						}
						userLng={
							(locationPinKind === "gps" || locationPinKind === "manual") &&
							userLocation
								? userLocation.lng
								: undefined
						}
					/>
					) : null}
					{(loading || !readyMeta || placesFetching) && !visiblePlaces ? (
						<div className="farq-map-skeleton" aria-hidden data-testid="intelligence-map-skeleton" />
					) : null}
				</div>

				{livePlaceId && !comparePanelHidden ? (
					<div
						className="farq-map-place-host lg:hidden"
						data-testid="intelligence-map-place-backdrop"
						onPointerDown={(e) => e.stopPropagation()}
						onPointerMove={(e) => e.stopPropagation()}
					>
						<SelectedPlaceSheet
							variant="panel"
							placeDetail={placeDetail}
							feature={selectedPlaceFeature?.properties}
							selectedCategory={selectedCategory}
							selectedRestaurantId={selectedRestaurantId}
							isRTL={isRTL}
							onClose={closePlace}
							onHide={() => setComparePanelHidden(true)}
							onOpenMenu={openRestaurantMenu}
							opportunityIndex={selectedTopIndex}
							opportunityCount={opportunityList.length}
							onPrevOpportunity={() => stepOpportunity(-1)}
							onNextOpportunity={() => stepOpportunity(1)}
						/>
					</div>
				) : null}

				{comparePanelHidden ? (
					<button
						type="button"
						className={`farq-map-panel-tab inline-flex ${livePlaceId ? "" : "hidden lg:inline-flex"}`}
						data-testid="intelligence-map-panel-tab"
						aria-label={isRTL ? "إظهار المقارنة" : "Show comparison"}
						onClick={() => setComparePanelHidden(false)}
					>
						{isRTL ? (
							<ChevronLeft className="size-3.5" />
						) : (
							<ChevronRight className="size-3.5" />
						)}
						<span>{isRTL ? "الفرق" : "Gap"}</span>
					</button>
				) : null}

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
				className={`farq-map-compare-aside hidden w-full flex-col overflow-hidden border-s border-[#e6eef0] bg-white lg:w-[27rem] lg:shrink-0 lg:rounded-none ${
					comparePanelHidden ? "" : "lg:flex"
				} ${livePlaceId ? "farq-place-panel-host" : ""}`}
			>
				{livePlaceId ? (
					<SelectedPlaceSheet
						variant="panel"
						placeDetail={placeDetail}
						feature={selectedPlaceFeature?.properties}
						selectedCategory={selectedCategory}
						selectedRestaurantId={selectedRestaurantId}
						isRTL={isRTL}
						onClose={closePlace}
						onHide={() => setComparePanelHidden(true)}
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
						<div className="flex shrink-0 items-center gap-1">
							<button
								type="button"
								className="rounded-full p-1 text-[#6b7c7c] hover:bg-[#e6eef0]"
								aria-label={isRTL ? "إخفاء" : "Hide"}
								data-testid="intelligence-map-panel-hide"
								onClick={() => setComparePanelHidden(true)}
							>
								{isRTL ? (
									<ChevronRight className="h-4 w-4" />
								) : (
									<ChevronLeft className="h-4 w-4" />
								)}
							</button>
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
					</div>
				<div className="flex-1 space-y-4 overflow-y-auto">
					<div className="space-y-4 p-5">
					{!neighborhoodId ? (
						<div className="space-y-4">
						<p className="text-[13px] text-[#6b7c7c]">
							{isRTL
								? "وين أقدر أوفّر فلوسي الآن؟ القائمة والخارطة نفس الفرص — أكبر فرق حولك، بدون اختراع سعر أو إحداثيات."
								: "Where can you save money now? List and map are the same opportunities — biggest observed gaps, never invented prices or coordinates."}
						</p>
						{topSavings.length ? (
							<div data-testid="intelligence-map-top-savings">
								<h3 className="mb-2 text-[13px] font-bold text-brand-900">
									{isRTL
										? `أفضل ${localizeDigitString(String(topSavings.length), true)} فرص حولك`
										: `Top ${topSavings.length} opportunities around you`}
								</h3>
								<ul className="space-y-1.5">
									{topSavings.map((row) => (
										<li key={row.placeId}>
											<FarqOpportunityCard
												row={row}
												isRTL={isRTL}
												selected={row.placeId === livePlaceId}
												onSelect={focusAroundPlace}
											/>
										</li>
									))}
								</ul>
							</div>
						) : places != null && !placesFetching ? (
							<p className="text-[14px] font-extrabold text-brand-900">
								{isRTL
									? "ما رصدنا فرق يستحق حولك بعد"
									: "No worthwhile gap observed around you yet"}
							</p>
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
