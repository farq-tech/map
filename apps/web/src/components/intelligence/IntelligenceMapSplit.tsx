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
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { localizeCity } from "../../lib/cityNames";
import {
	differenceFromPinProps,
	pinFetchCapForZoom,
} from "../../lib/farqMapPins";
import { pinGapAmount } from "../../lib/farqPriceTiles";
import { DISTRICT_FILL_STEPS, districtBounds, type DistrictLens } from "../../lib/farqDistrictTiles";
import FarqDistrictPicker from "./FarqDistrictPicker";
import { matchesQuery } from "../../lib/farqTextSearch";
import { readLayerFreshness } from "../../lib/farqFreshness";
import { track } from "../../lib/farqAnalytics";
import { PROVIDER_MAP_COLOR } from "../../lib/platformLogos";
import {
	topOpportunities,
	withObservedDistances,
	type OpportunityRow,
} from "../../lib/farqOpportunities";
import {
	shouldOfferSearchHere,
	type MapViewChangeMeta,
} from "../../lib/farqMapViewport";
import { localizeDigitString } from "../../lib/formatPrice";
import { viewportStats } from "../../lib/farqViewportStats";
import { getProviderLabel } from "../../lib/platformLogos";
import { sheetHeightPx } from "./FarqBottomSheet";
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
	type CityOpportunities,
	type CityAreas,
	type CityDistricts,
} from "../../services/intelligenceService";
import EmptyState from "../EmptyState";
import FarqBrandMark from "../FarqBrandMark";
import { ProviderLogoMark } from "../ProviderLogoMark";
import { Button } from "../ui/Button";
import type { MapSearch, MapSort, MapViewMode } from "../../routes/map";
import { encodeCameraBbox, parseCameraBbox, resolveMapSort, resolveMapView } from "../../routes/map";
import FarqAnswerCard, { rowToOpportunity } from "./FarqAnswerCard";
import { askCopilot, looksLikeQuestion, readSessionId, type CopilotAction, type CopilotResponse, type CopilotRow } from "../../lib/farqAsk";
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

/** Rows the list shows at once; the map draws every visible opportunity regardless. */
const LIST_CAP = 30;

/** Cities served by the whole-city read model; everything else still fetches by viewport. */
const CITY_READ_MODEL = new Set(["riyadh"]);

function cityKeyOf(city: string): string {
	return String(city || "").trim().toLowerCase();
}

function bboxFromCsv(csv: string): [number, number, number, number] | null {
	const p = String(csv || "").split(",").map(Number);
	if (p.length !== 4 || p.some((n) => !Number.isFinite(n))) return null;
	return [Math.min(p[0], p[2]), Math.min(p[1], p[3]), Math.max(p[0], p[2]), Math.max(p[1], p[3])];
}

function inBbox(lng: number, lat: number, b: [number, number, number, number]): boolean {
	return lng >= b[0] && lng <= b[2] && lat >= b[1] && lat <= b[3];
}

/**
 * Search the cached city without a network round trip — and in the Arabic
 * people actually type: برجر finds برغر, قهوه finds قهوة, ٥ finds 5. The
 * matcher is shared with the copilot's normaliser, so the same word means the
 * same thing whether it was typed here or asked as a sentence.
 */
function filterCityByQuery(
	city: CityOpportunities,
	query: string | undefined,
): IntelligenceMapPlaces {
	const needle = String(query || "").trim();
	const features = needle
		? city.features.filter((f) => {
				const p = f.properties;
				return matchesQuery([p.name, p.name_en, p.product_name], needle);
			})
		: city.features;
	return {
		type: "FeatureCollection",
		count: features.length,
		matched: features.length,
		layer: "comparison",
		features: features as unknown as IntelligenceMapPlaces["features"],
		note_ar: city.generated_at
			? `بيانات المقارنة محدثة بتاريخ ${city.generated_at.slice(0, 10)}`
			: undefined,
	};
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
		kind?: "select" | "locate" | "cluster" | "bounds";
		bounds?: [number, number, number, number] | null;
	} | null>(null);
	const [leftUserLocation, setLeftUserLocation] = useState(false);
	const [basemap, setBasemap] = useState<MapboxBasemap>("standard");
	const [majorGapsOnly, setMajorGapsOnly] = useState(true);
	const [legendOpen, setLegendOpen] = useState(false);
	/* What the district colour answers: "how many فرص" or "which app wins". */
	const [districtLens, setDistrictLens] = useState<DistrictLens>("gap");
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
	/* Whole-city read model: loaded once per city, filtered and ranked on the client. */
	const [cityPlaces, setCityPlaces] = useState<CityOpportunities | null>(null);
	const [cityAreas, setCityAreas] = useState<CityAreas | null>(null);
	/* The city's أحياء; `?neighborhood=` is one of their ids and scopes list, headline and map alike. */
	const [cityDistricts, setCityDistricts] = useState<CityDistricts | null>(null);
	const districtFocusRef = useRef<string>("");
	const cityStatusRef = useRef<"idle" | "loading" | "ready" | "failed">("idle");
	const [viewBbox, setViewBbox] = useState<[number, number, number, number] | null>(null);
	/* Copilot: the exchange shown above the list, and what its last action pinned. */
	const [ask, setAsk] = useState<{ question: string; response: CopilotResponse | null; busy: boolean; error: string | null } | null>(null);
	const [pinnedIds, setPinnedIds] = useState<Set<string> | null>(null);
	const [minGapFilter, setMinGapFilter] = useState<number | null>(null);
	const askAbortRef = useRef<AbortController | null>(null);
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
					b: "b" in next ? next.b : prev.b,
					z: "z" in next ? next.z : prev.z,
				}),
			});
		},
		[navigate, pathname],
	);

	/* The camera goes into the URL with replaceState after the map settles, so
	 * a shared link reopens the same scene without flooding history on every pan. */
	const cameraUrlTimerRef = useRef(0);
	const writeCameraToUrl = useCallback(
		(bbox: [number, number, number, number], zoom: number) => {
			window.clearTimeout(cameraUrlTimerRef.current);
			cameraUrlTimerRef.current = window.setTimeout(() => {
				const b = encodeCameraBbox(bbox);
				const z = Math.round(zoom * 100) / 100;
				void navigate({
					to: pathname === "/" ? "/" : "/map",
					replace: true,
					search: (prev: MapSearch) => (prev.b === b && prev.z === z ? prev : { ...prev, b, z }),
				});
			}, 400);
		},
		[navigate, pathname],
	);
	useEffect(() => () => window.clearTimeout(cameraUrlTimerRef.current), []);

	/* Where the map should open: the link's camera if it has one, else the city default. Read once. */
	const [initialCamera] = useState<{ center: [number, number]; zoom: number } | null>(() => {
		const b = parseCameraBbox(search.b);
		return b && typeof search.z === "number"
			? { center: [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2], zoom: search.z }
			: null;
	});

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

	useEffect(() => {
		const key = cityKeyOf(city || "riyadh");
		if (!CITY_READ_MODEL.has(key)) {
			cityStatusRef.current = "idle";
			setCityPlaces(null);
			setCityDistricts(null);
			return;
		}
		const controller = new AbortController();
		cityStatusRef.current = "loading";
		void IntelligenceService.cityAreas({ city: key, signal: controller.signal })
			.then((body) => { if (!controller.signal.aborted) setCityAreas(body); })
			.catch(() => { if (!controller.signal.aborted) setCityAreas(null); });
		/* A city without boundaries is a 404 → null → the H3 field stays; nothing is drawn from a guess. */
		void IntelligenceService.cityDistricts({ city: key, signal: controller.signal })
			.then((body) => { if (!controller.signal.aborted) setCityDistricts(body?.features?.length ? body : null); })
			.catch(() => { if (!controller.signal.aborted) setCityDistricts(null); });
		void IntelligenceService.cityOpportunities({ city: key, signal: controller.signal })
			.then((body) => {
				if (controller.signal.aborted) return;
				cityStatusRef.current = "ready";
				setCityPlaces(body);
				setPlacesFetching(false);
				setSearchHere(false);
			})
			.catch(() => {
				if (controller.signal.aborted) return;
				cityStatusRef.current = "failed";
				setCityPlaces(null);
				/* fall back to the viewport fetch for whatever the camera shows now */
				const v = viewRef.current;
				if (v && !fetchedViewRef.current) fetchPlacesRef.current?.(v.bbox, v.zoom);
			});
		return () => controller.abort();
	}, [city, retryTick]);

	const fetchPlacesRef = useRef<((bbox: string, zoom: number) => void) | null>(null);

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
	fetchPlacesRef.current = fetchPlaces;

	const onViewChange = useCallback(
		(bbox: string, zoom: number, meta?: MapViewChangeMeta) => {
			const next = { bbox, zoom };
			viewRef.current = next;
			const parsed = bboxFromCsv(bbox);
			setViewBbox(parsed);
			if (parsed) writeCameraToUrl(parsed, zoom);
			/* With the city in memory, moving the camera is a filter, not a request. */
			if (cityStatusRef.current === "loading" || cityStatusRef.current === "ready") {
				intentionalFetchRef.current = false;
				setSearchHere(false);
				return;
			}
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
		[fetchPlaces, writeCameraToUrl],
	);

	const searchThisView = useCallback(() => {
		const v = viewRef.current;
		if (v) fetchPlaces(v.bbox, v.zoom);
	}, [fetchPlaces]);


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
		if (drawerOpen || searchFocused || sheetSnap !== "peek") {
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
	const selectedDistrict = useMemo(
		() =>
			neighborhoodId && cityDistricts
				? cityDistricts.features.find((f) => f.properties.district_id === neighborhoodId) || null
				: null,
		[cityDistricts, neighborhoodId],
	);
	const districtName = selectedDistrict
		? isRTL
			? selectedDistrict.properties.name_ar
			: selectedDistrict.properties.name_en
		: "";
	/* The حي scopes the shared result set only where places carry a geometric district_id (the city read model). */
	const districtScope = cityPlaces && neighborhoodId ? neighborhoodId : "";
	const nearLabel = districtName ? (isRTL ? `في ${districtName}` : `in ${districtName}`) : isRTL ? "حولك" : "around you";

	const focusDistrict = useCallback((feature: CityDistricts["features"][number]) => {
		const bounds = districtBounds(feature);
		if (!bounds) return;
		districtFocusRef.current = feature.properties.district_id;
		setFocusRequest({
			lat: (bounds[1] + bounds[3]) / 2,
			lng: (bounds[0] + bounds[2]) / 2,
			id: `district:${feature.properties.district_id}`,
			kind: "bounds",
			bounds,
		});
	}, []);
	/* One path for a tap on the field, a link, and a copilot answer that names a حي. */
	const selectDistrict = useCallback(
		(id: string) => {
			const did = String(id || "").trim();
			if (!did) return;
			setLivePlaceId("");
			setComparePanelHidden(false);
			setSheetSnap("half");
			setDrawerOpen(false);
			patchSearch({ neighborhood: did, place: undefined });
			const feature = cityDistricts?.features.find((f) => f.properties.district_id === did);
			if (feature) focusDistrict(feature);
			track("district_select", { district_id: did });
		},
		[cityDistricts, focusDistrict, patchSearch],
	);
	const clearDistrict = useCallback(() => {
		districtFocusRef.current = "";
		patchSearch({ neighborhood: undefined });
		track("district_clear");
	}, [patchSearch]);
	/* A link or an answer can name a حي before anyone taps it: frame it once, never yank the camera back later. */
	useEffect(() => {
		if (!neighborhoodId) {
			districtFocusRef.current = "";
			return;
		}
		if (!selectedDistrict || districtFocusRef.current === neighborhoodId) return;
		focusDistrict(selectedDistrict);
	}, [neighborhoodId, selectedDistrict, focusDistrict]);
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

	/**
	 * A category is answered from the read model's per-category gaps, not by
	 * searching for the word "برجر" in item names — a restaurant whose burger
	 * differs by 18 SAR belongs under "برجر" even when its largest gap that day
	 * was a dessert. Categories the read model does not carry fall back to the
	 * old text search rather than silently returning nothing.
	 */
	const categoryIsGapped = useMemo(
		() =>
			Boolean(
				categoryId &&
					cityPlaces?.features.some(
						(f) => (f.properties.category_gaps || {})[categoryId] != null,
					),
			),
		[cityPlaces, categoryId],
	);
	const activeCategoryLabel = useMemo(() => {
		const cat = meta?.categories.find((c) => c.category_id === categoryId) || null;
		return (
			(isRTL ? cat?.category_name_ar || cat?.category_name : cat?.category_name) ||
			categoryId ||
			null
		);
	}, [meta, categoryId, isRTL]);
	const cityQuery = useMemo(() => {
		if (categoryIsGapped) return q || undefined;
		const cat = meta?.categories.find((c) => c.category_id === categoryId) || null;
		return categorySearchQuery(categoryId, cat, q);
	}, [meta, categoryId, q, categoryIsGapped]);

	/* One source of places: the cached city when we have it, the viewport fetch otherwise. */
	const sourcePlaces = useMemo(
		() => (cityPlaces ? filterCityByQuery(cityPlaces, cityQuery) : places),
		[cityPlaces, cityQuery, places],
	);

	const selectedPlaceFeature = sourcePlaces?.features.find(
		(f) => String(f.properties.place_id) === String(livePlaceId),
	);
	const selectedRestaurantId =
		placeDetail?.restaurant_id ||
		placeDetail?.menu?.id ||
		selectedPlaceFeature?.properties.restaurant_id ||
		selectedPlaceFeature?.properties.menu?.id ||
		(/^\d+$/.test(livePlaceId) ? livePlaceId : "");

	const showUserDot = locationPinKind === "gps" || locationPinKind === "manual";
	placesRef.current = sourcePlaces;

	const visiblePlaces = useMemo(() => {
		if (!sourcePlaces) return sourcePlaces;
		const gapsOnly = true;
		return {
			...sourcePlaces,
			features: sourcePlaces.features.filter((f) => {
				const isCluster = f.properties.feature_type === "cluster";
				const amount = pinGapAmount(f.properties);
				const hasGap = isCluster
					? Number(f.properties.difference_count || 0) > 0
					: Boolean(f.properties.has_difference) || amount != null;
				if (!layers.opportunities && hasGap) return false;
				if (pinnedIds && !pinnedIds.has(String(f.properties.place_id || ""))) return false;
				if (districtScope && String(f.properties.district_id || "") !== districtScope) return false;
				if (categoryIsGapped && (f.properties.category_gaps || {})[categoryId] == null) return false;
				if (minGapFilter != null && (amount == null || amount < minGapFilter)) return false;
				if (gapsOnly) return hasGap;
				return true;
			}),
		};
	}, [sourcePlaces, layers.opportunities, pinnedIds, minGapFilter, districtScope, categoryIsGapped, categoryId]);

	/* The list and the headline describe what the camera shows, not the whole city. */
	const viewportSavings = useMemo(() => {
		const rows: OpportunityRow[] = [];
		/* A selected حي is the scope; the camera no longer clips what it lists. */
		const clip = cityPlaces && !districtScope ? viewBbox : null;
		for (const f of visiblePlaces?.features || []) {
			if (f.properties.feature_type === "cluster") continue;
			const placeId = String(f.properties.place_id || "").trim();
			if (!placeId) continue;
			/**
			 * A category narrows *which restaurants* are shown — it does not change
			 * the number on the card. Ranking by the category's gap while the card
			 * still printed the representative item's name and its two prices made
			 * 62.5% of filtered rows contradict themselves on one line ("٢٧ ر.س فرق"
			 * over "٩٩ → ١٢٧"). Until the category's own item travels with its gap,
			 * the honest card is the one whose number, dish and prices agree.
			 */
			const amount = pinGapAmount(f.properties);
			if (amount == null) continue;
			const coords = f.geometry?.coordinates;
			if (!Array.isArray(coords) || coords.length < 2) continue;
			const lng = Number(coords[0]);
			const lat = Number(coords[1]);
			if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
			if (clip && !inBbox(lng, lat, clip)) continue;
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
				brandKey: f.properties.brand_key || null,
				demoteReason: f.properties.demote_reason || null,
				comparisons: Number(f.properties.comparisons) || 0,
				/* Only when the card's own dish is not the one the category asked for. */
				categoryGap:
					categoryIsGapped && (f.properties.category_gaps || {})[categoryId] !== amount
						? ((f.properties.category_gaps || {})[categoryId] ?? null)
						: null,
				categoryLabel: categoryIsGapped ? activeCategoryLabel : null,
			});
		}
		const located =
			showUserDot && userLocation
				? withObservedDistances(rows, userLocation.lat, userLocation.lng)
				: rows;
		return located;
	}, [visiblePlaces, showUserDot, userLocation, cityPlaces, viewBbox, districtScope, categoryIsGapped, categoryId, activeCategoryLabel]);

	const cheapestReady = useMemo(
		() => viewportSavings.some((row) => row.cheapestPrice != null),
		[viewportSavings],
	);
	const nearReady = Boolean(showUserDot && userLocation);

	const opportunityList = useMemo(
		() => topOpportunities(viewportSavings, sort, LIST_CAP),
		[viewportSavings, sort],
	);

	const topSavings = opportunityList;

	const displayPlaces = useMemo(() => {
		if (!visiblePlaces) return visiblePlaces;
		/* The GPU draws every opportunity and clusters them itself; the cap was a DOM limit. */
		if (cityPlaces) return visiblePlaces;
		const ids = new Set(topSavings.map((row) => row.placeId));
		if (livePlaceId) ids.add(livePlaceId);
		return {
			...visiblePlaces,
			count: topSavings.length,
			features: visiblePlaces.features.filter((f) =>
				ids.has(String(f.properties.place_id || "")),
			),
		};
	}, [visiblePlaces, topSavings, livePlaceId, cityPlaces]);

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

	/* One honest line for what the camera shows — the sheet's head on the phone. */
	const stats = useMemo(
		() => viewportStats((visiblePlaces?.features || []) as Parameters<typeof viewportStats>[0], cityPlaces && !districtScope ? viewBbox : null),
		[visiblePlaces, cityPlaces, viewBbox, districtScope],
	);
	const freshness = useMemo(
		() => readLayerFreshness(cityPlaces?.generated_at, isRTL),
		[cityPlaces, isRTL],
	);
	/* Only apps that actually won a حي appear in the lens legend — the palette
	 * never advertises an app the data has not put on the map. */
	const appLensProviders = useMemo(() => {
		const seen = new Map<string, number>();
		for (const f of cityDistricts?.features || []) {
			const app = f.properties.cheapest_app;
			if (!app || !f.properties.enough_for_app_verdict) continue;
			seen.set(app, (seen.get(app) || 0) + 1);
		}
		return [...seen.entries()].sort((a, b) => b[1] - a[1]).map(([app]) => app);
	}, [cityDistricts]);
	const headline = useMemo(() => {
		const n = (v: number) => localizeDigitString(String(v), isRTL);
		/* With a حي selected the line describes the حي, not the camera. */
		const hood = districtScope && selectedDistrict ? districtName : "";
		const here = hood ? (isRTL ? `في ${hood}` : `in ${hood}`) : isRTL ? "حولك" : "here";
		const primary =
			stats.count > 0
				? hood
					? isRTL
						? `${hood}: ${n(stats.count)} فرصة · أكبرها ${n(stats.maxGap || 0)} ر.س`
						: `${hood}: ${stats.count} opportunities · biggest ${stats.maxGap} SAR`
					: isRTL
						? `${n(stats.count)} فرصة في هذا النطاق · أكبرها ${n(stats.maxGap || 0)} ر.س`
						: `${stats.count} opportunities here · biggest ${stats.maxGap} SAR`
				: hood
					? isRTL
						? `لا فرص مرصودة في ${hood}`
						: `No observed opportunities in ${hood}`
					: isRTL
						? "لا فرص مرصودة في هذا النطاق"
						: "No observed opportunities in this area";
		const verdict = stats.verdict;
		const secondary = verdict
			? isRTL
				? `${getProviderLabel(verdict.provider, { isRTL: true }) || verdict.provider} أرخص في ${n(verdict.wins)} من ${n(verdict.comparisons)} مقارنة ${here}`
				: `${getProviderLabel(verdict.provider, { isRTL: false }) || verdict.provider} cheapest in ${verdict.wins} of ${verdict.comparisons} comparisons ${here}`
			: stats.count > 0
				? null
				: hood
					? isRTL
						? "اختر حياً آخر أو أزل التحديد"
						: "Pick another district or clear it"
					: isRTL
						? "حرّك الخريطة أو وسّع النطاق"
						: "Move the map or widen the area";
		return (
			<>
				<strong>
					{primary}
					{hood ? (
						<button
							type="button"
							className="farq-headline-clear"
							aria-label={isRTL ? `إلغاء تحديد ${hood}` : `Clear ${hood}`}
							data-testid="intelligence-map-district-clear"
							/* The sheet header captures pointerdown to drag-resize; without
							   stopping it here, clearing a حي also snapped the sheet open. */
							onPointerDown={(e) => e.stopPropagation()}
							onClick={(e) => {
								e.stopPropagation();
								clearDistrict();
							}}
						>
							×
						</button>
					) : null}
				</strong>
				{secondary ? <span>{secondary}</span> : null}
				{/* How old these prices are — always on screen, never a hover. */}
				{freshness ? (
					<span
						className={`farq-freshness ${freshness.stale ? "is-stale" : ""}`}
						data-testid="intelligence-map-freshness"
						title={cityPlaces?.generated_at || undefined}
					>
						{freshness.label}
					</span>
				) : null}
			</>
		);
	}, [stats, cityPlaces, isRTL, districtScope, selectedDistrict, districtName, clearDistrict, freshness]);
	const sheetInset = sheetHeightPx(
		sheetSnap,
		typeof window !== "undefined" ? window.innerHeight : 800,
	);

	const locateUser = useCallback(() => {
		pendingLocateRef.current = true;
		track("locate_click");
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
		/* Touching the map is a vote for the map: the sheet drops to peek, the selection stays. */
		if (phase === "start" && sheetSnap !== "peek") setSheetSnap("peek");
		if (drawerOpen || searchFocused || sheetSnap !== "peek") return;
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
			setSheetSnap("half");
			setFocusRequest({
				lat: row.lat,
				lng: row.lng,
				id: `place:${row.placeId}`,
				kind: "select",
			});
			/* A place inside a selected حي keeps the حي: the person is exploring it, not leaving it. */
			patchSearch({ place: row.placeId });
			setComparePanelHidden(false);
			setDrawerOpen(false);
			track("place_select", { source: "list" });
		},
		[patchSearch],
	);

	const clearAsk = useCallback(() => {
		askAbortRef.current?.abort();
		setAsk(null);
		setPinnedIds(null);
		setMinGapFilter(null);
	}, []);

	/* The copilot proposes; the app executes — only with ids and bounds it was given. */
	const applyCopilotAction = useCallback(
		(action: CopilotAction, rows: CopilotRow[], opts: { skipFit?: boolean } = {}) => {
			const byId = new Map(rows.map((r) => [r.place_id, r]));
			const fit = (bbox?: [number, number, number, number] | null) => {
				if (!bbox || opts.skipFit) return;
				setFocusRequest({ lat: (bbox[1] + bbox[3]) / 2, lng: (bbox[0] + bbox[2]) / 2, id: `bounds:${bbox.join(",")}`, kind: "bounds", bounds: bbox });
			};
			switch (action.type) {
				case "FOCUS_PLACE": {
					const row = action.place_id ? byId.get(action.place_id) : null;
					if (row) focusAroundPlace(rowToOpportunity(row));
					return;
				}
				case "SHOW_RESULTS": {
					const ids = (action.place_ids || []).filter((id) => byId.has(id));
					if (!ids.length) return;
					setPinnedIds(new Set(ids));
					setLivePlaceId("");
					fit(action.bbox);
					return;
				}
				case "FIT_BOUNDS":
					fit(action.bbox);
					return;
				case "SET_FILTER":
					if (typeof action.min_gap === "number") setMinGapFilter(action.min_gap);
					fit(action.bbox);
					return;
				case "SET_CATEGORY":
				case "SET_SEARCH":
					if (action.q) {
						setMapQuery(action.q);
						patchSearch({ q: action.q, place: undefined });
					}
					fit(action.bbox);
					return;
				case "RETURN_TO_USER":
					locateUser();
					return;
				default:
					return;
			}
		},
		[focusAroundPlace, locateUser, patchSearch],
	);

	const askFarq = useCallback(
		(text: string) => {
			const message = String(text || "").trim();
			if (!message) return;
			askAbortRef.current?.abort();
			const controller = new AbortController();
			askAbortRef.current = controller;
			setPinnedIds(null);
			setMinGapFilter(null);
			setAsk({ question: message, response: null, busy: true, error: null });
			setSheetSnap("half");
			/* The question itself never leaves the browser — only that one was asked. */
			track("copilot_ask", { has_query: true });
			const located = (locationPinKind === "gps" || locationPinKind === "manual") && userLocation;
			void askCopilot({
				message,
				sessionId: readSessionId(),
				language: isRTL ? "ar" : "en",
				context: {
					bbox: viewRef.current?.bbox,
					zoom: viewRef.current?.zoom,
					selected_place_id: livePlaceId || undefined,
					user_lat: located ? userLocation.lat : undefined,
					user_lng: located ? userLocation.lng : undefined,
					city: "riyadh",
				},
				signal: controller.signal,
			})
				.then((response) => {
					if (controller.signal.aborted) return;
					setAsk({ question: message, response, busy: false, error: null });
					/* An answer scoped to a حي selects that حي — the same path a tap uses — and its
					 * polygon, not the rows' bbox, frames the camera. A FOCUS_PLACE still flies in. */
					track("copilot_action", {
						intent: response.intent,
						action: response.action?.type,
						result_count: response.results?.length ?? 0,
					});
					const districtId = String(response.scope?.district_id || "").trim();
					const known = districtId && cityDistricts?.features.some((f) => f.properties.district_id === districtId);
					if (known) {
						selectDistrict(districtId);
						applyCopilotAction(response.action, response.results, { skipFit: true });
					} else {
						applyCopilotAction(response.action, response.results);
					}
				})
				.catch(() => {
					if (controller.signal.aborted) return;
					setAsk({
						question: message,
						response: null,
						busy: false,
						error: isRTL ? "تعذّر الوصول لمساعد فرق الآن. الخريطة والبحث يعملان." : "Farq's assistant is unavailable right now. The map and search still work.",
					});
				});
		},
		[applyCopilotAction, cityDistricts, isRTL, livePlaceId, locationPinKind, selectDistrict, userLocation],
	);

	const applyView = useCallback(
		(next: MapViewMode) => {
			patchSearch({ view: next });
			track(next === "map" ? "map_open" : "list_open");
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
			track("sort_change", { sort: next });
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
		patchSearch({ place: undefined });
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
			data-sheet-snap={sheetSnap}
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
					onSearchSubmit={(q) => {
						clearAsk();
						patchSearch({ q: q || undefined, place: undefined });
						/* Whether someone searched, never what they typed. */
						track("search_submit", { has_query: Boolean(q), source: "sheet" });
					}}
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
					headline={headline}
					ask={ask}
					onAsk={askFarq}
					onCloseAsk={clearAsk}
					selectedPanel={
						livePlaceId ? (
							<SelectedPlaceSheet
								variant="panel"
								placeDetail={placeDetail}
								feature={selectedPlaceFeature?.properties}
								selectedCategory={selectedCategory}
								selectedRestaurantId={selectedRestaurantId}
								isRTL={isRTL}
								onClose={closePlace}
								onHide={() => setSheetSnap("peek")}
								onOpenMenu={openRestaurantMenu}
								opportunityIndex={selectedTopIndex}
								opportunityCount={opportunityList.length}
								onPrevOpportunity={() => stepOpportunity(-1)}
								onNextOpportunity={() => stepOpportunity(1)}
							/>
						) : null
					}
					sheetSnap={sheetSnap}
					onSheetSnap={setSheetSnap}
					placesFetching={placesFetching}
					scanHint={scanHint}
					hasViewportPlaces={hasViewportPlaces}
					placesReady={sourcePlaces != null}
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
					basemap={basemap}
					onBasemapChange={setBasemap}
					legendOpen={legendOpen}
					onLegendOpenChange={setLegendOpen}
					districts={cityDistricts}
					selectedDistrictId={neighborhoodId}
					onSelectDistrict={selectDistrict}
					onClearDistrict={clearDistrict}
					districtLens={districtLens}
					onDistrictLensChange={(lens) => {
						setDistrictLens(lens);
						track("lens_change", { lens });
					}}
					appLensProviders={appLensProviders}
				/>

				{readyMeta ? <div className="absolute inset-x-3 top-3 z-[500] hidden flex-col gap-3 rounded-2xl bg-white p-4 shadow-[0_8px_8px_rgba(0,0,0,0.1)] lg:flex lg:flex-row lg:flex-wrap lg:items-center lg:justify-between lg:gap-x-4 lg:gap-y-2 lg:py-3">
					{/* Wraps instead of overlapping: at 1024–1440 the fixed-width controls
					    used to slide on top of each other, and «اختر حي» — a white pill with
					    a shadow — landed squarely over «خريطة / قائمة». */}
					<div className="flex min-w-0 flex-1 basis-[22rem] items-center gap-4">
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
							<MapPin className="size-3.5 shrink-0 text-[#5c6d6d]" />
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
							<ChevronDown className="pointer-events-none absolute end-0 size-3 text-[#5c6d6d]" />
						</label>
						<FarqDistrictPicker
							districts={cityDistricts}
							selectedId={neighborhoodId}
							isRTL={isRTL}
							onSelect={selectDistrict}
							onClear={clearDistrict}
							variant="toolbar"
							className="hidden lg:block"
						/>
						<span className="hidden h-6 w-px bg-[#e6eef0] lg:block" aria-hidden />
						<form
							className="flex min-w-0 flex-1 items-center gap-2"
							onSubmit={(e) => {
								e.preventDefault();
								const text = mapQuery.trim();
								if (looksLikeQuestion(text)) askFarq(text);
								else {
									clearAsk();
									patchSearch({ q: text || undefined, place: undefined });
									track("search_submit", { has_query: Boolean(text), source: "toolbar" });
								}
							}}
						>
							<Search className="size-4 shrink-0 text-[#5c6d6d]" />
							<input
								value={mapQuery}
								onChange={(e) => setMapQuery(e.target.value)}
								placeholder={
									isRTL
										? "ابحث أو اسأل فرق: وين أكبر فرق حولي؟"
										: "Search or ask Farq: biggest gap near me?"
								}
								className="h-7 min-w-0 flex-1 bg-transparent text-[14px] text-brand-900 placeholder:text-[#5c6d6d] lg:max-w-[14rem]"
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
						<label className="flex items-center gap-2 text-[12px] text-[#5c6d6d]">
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
										: "text-[#5c6d6d]"
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
										: "text-[#5c6d6d]"
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
								Boolean(sourcePlaces) &&
								!placesFetching &&
								topSavings.length === 0
							}
							countLabel={
								topSavings.length
									? isRTL
										? `أفضل ${localizeDigitString(String(topSavings.length), true)} فرص ${nearLabel}`
										: `Top ${topSavings.length} opportunities ${nearLabel}`
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
							areas={cityAreas}
							districts={cityDistricts}
							districtLens={districtLens}
							bottomInset={sheetInset}
							initialCamera={initialCamera}
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
								setSheetSnap("half");
								lastFocusedPlaceRef.current = id;
								setComparePanelHidden(false);
								patchSearch({ place: id });
							}}
							onSelectNeighborhood={selectDistrict}
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
					{(loading || !readyMeta || placesFetching) && !visiblePlaces ? (
						<div className="farq-map-skeleton" aria-hidden data-testid="intelligence-map-skeleton" />
					) : null}
				</div>


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
						onClick={() => {
							setLegendOpen((v) => {
								if (!v) track("legend_open", { lens: districtLens });
								return !v;
							});
						}}
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
							<p className="mb-2 text-start text-[13px] font-bold text-brand-900">
								{isRTL ? "دليل الخريطة" : "Map legend"}
							</p>
							<p className="farq-legend-kicker">{isRTL ? "لون الحي يعني" : "District colour means"}</p>
							{/* The legend explains the colour, so it is also where you change what
							    the colour answers. Both lenses read the same server numbers. */}
							<div className="farq-legend-lens" role="group" aria-label={isRTL ? "معنى اللون" : "Colour meaning"}>
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
										className={districtLens === id ? "is-on" : ""}
										data-testid={`intelligence-map-lens-${id}`}
										onClick={() => {
											setDistrictLens(id);
											track("lens_change", { lens: id });
										}}
									>
										{label}
									</button>
								))}
							</div>
							{districtLens === "gap" ? (
								<>
									<div className="farq-legend-scale" aria-hidden>
										{[{ min: 0, opacity: 0 }, ...DISTRICT_FILL_STEPS].map((s) => (
											<span key={s.min} className="farq-legend-swatch" style={{ "--o": s.opacity } as CSSProperties} />
										))}
									</div>
									<div className="farq-legend-scale-labels" aria-hidden>
										{[0, ...DISTRICT_FILL_STEPS.map((s) => s.min)].map((m, i) => (
											<span key={m}>{i === 0 ? localizeDigitString("0", isRTL) : `${localizeDigitString(String(m), isRTL)}+`}</span>
										))}
									</div>
									<p className="farq-legend-note">
										{isRTL
											? "اللون: عدد الفرص المرصودة في الحي · الرقم على الحي: أكبر فرق فيه"
											: "Tint: observed opportunities in the district · number on it: its biggest gap"}
									</p>
								</>
							) : (
								<>
									<ul className="farq-legend-apps">
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
										{appLensProviders.length === 0 ? (
											<li className="farq-legend-apps-empty">
												{isRTL ? "لا يوجد حي بمقارنات كافية بعد" : "No district has enough comparisons yet"}
											</li>
										) : null}
									</ul>
									{/* The two states that are not a win, each with its own mark — a third
									    of the city is one of them, and neither used to be in the key. */}
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
											? `يُسمّى تطبيق فائز فقط من ${localizeDigitString("8", true)} مقارنات فأكثر وبفارق ${localizeDigitString("5", true)}٪ على الأقل — وكثافة اللون بحجم الفارق.`
											: "An app is named only from 8 comparisons up and a lead of at least 5 points — the stronger the lead, the stronger the colour."}
									</p>
								</>
							)}
							<ul className="space-y-2 text-[#5c6d6d]">
								<li className="flex items-center gap-2">
									<span className="farq-legend-selected" aria-hidden />
									<span>
										{isRTL
											? "الحي المحدد — إطار حوله، والقائمة والعنوان يصفانه هو فقط"
											: "Selected district — outlined, and the list and headline describe it alone"}
									</span>
								</li>
								<li className="flex items-center gap-2">
									<span className="farq-legend-3d-cluster" aria-hidden />
									<span>
										{isRTL
											? "تجمّع فرص: الرقم الكبير أكبر فرق داخله، الصغير عددها"
											: "Cluster: big number = biggest gap inside, small = how many"}
									</span>
								</li>
								<li className="flex items-center gap-2">
									<span className="farq-legend-disc" aria-hidden>36</span>
									<span>
										{isRTL
											? "فرصة واحدة — حجم القرص بحجم الفرق: ٣٦+ · ١٥–٣٥ · ٥–١٤ · أقل من ٥ ر.س"
											: "One opportunity — disc size by gap: 36+ · 15–35 · 5–14 · under 5 SAR"}
									</span>
								</li>
								<li className="flex items-center gap-2">
									<span className="farq-legend-bubble" aria-hidden>
										<FarqBrandMark variant="circle" size={10} />
										<span className="farq-legend-win">
											{isRTL ? "+١٨" : "+18"}
										</span>
									</span>
									<span>
										{isRTL
											? "عند التقريب: شعار التطبيق الأرخص وفرقه المرصود"
											: "Zoomed in: the cheapest app's logo and its observed gap"}
									</span>
								</li>
							</ul>
							<p className="mt-2 text-[10px] font-bold text-brand-900">
								{isRTL ? "كل رقم من مقارنة مرصودة — لا شيء مُخترع" : "Every number is an observed comparison — nothing invented"}
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
							{selectedDistrict
								? `${isRTL ? "حي" : "District"} · ${districtName}`
								: selectedHood
									? `${isRTL ? "تفاصيل الحي" : "Neighborhood detail"} · ${selectedHood.properties.neighborhood_ar || selectedHood.properties.neighborhood_en}`
									: isRTL
										? "تفاصيل الفرق"
										: "Farq difference"}
						</h2>
						<div className="flex shrink-0 items-center gap-1">
							<button
								type="button"
								className="rounded-full p-1 text-[#5c6d6d] hover:bg-[#e6eef0]"
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
									className="rounded-full p-1 text-[#5c6d6d] hover:bg-[#e6eef0]"
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
					{!neighborhoodId || selectedDistrict ? (
						<div className="space-y-4">
						{/* The one true sentence about what the camera is showing. It was
						    computed for both viewports but only ever rendered inside the
						    phone's sheet header, so the desktop — the investor screen —
						    got a tagline instead of the numbers. */}
						<div className="farq-sheet-headline farq-panel-headline">{headline}</div>
						{ask ? (
							<FarqAnswerCard
								question={ask.question}
								response={ask.response}
								busy={ask.busy}
								error={ask.error}
								isRTL={isRTL}
								onAsk={askFarq}
								onSelect={focusAroundPlace}
								onClose={clearAsk}
							/>
						) : null}
						{/* In list view the main column already is this list; rendering it in
						    the panel too printed the same 30 cards twice, side by side. */}
						{topSavings.length && view !== "list" ? (
							<div data-testid="intelligence-map-top-savings">
								<div className="mb-2 flex items-baseline justify-between gap-2">
									<h3 className="text-[13px] font-bold text-brand-900">
										{isRTL
											? `أفضل ${localizeDigitString(String(topSavings.length), true)} فرص ${nearLabel}`
											: `Top ${topSavings.length} opportunities ${nearLabel}`}
									</h3>
								</div>
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
						) : sourcePlaces != null && !placesFetching ? (
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
					<p className="mt-2 text-[11px] text-[#5c6d6d]">
						{isRTL
							? "يفتح المقارنة الكاملة على فرق."
							: "Opens the full comparison on Farq."}
					</p>
				</div>
					</>
				)}
			</aside>
		</div>
	);
}
