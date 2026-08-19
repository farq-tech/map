import { LocateFixed, Menu, Search, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { useLiveLocation } from "../../hooks/useLiveLocation";
import { mapZoomMode, type MapZoomMode } from "../../lib/mapExploration";
import type { MapboxBasemap } from "../../lib/mapboxAccess";
import { IntelligenceService, toIntelCategoryId, type IntelligenceCategory, type IntelligenceMapPlaceDetail, type IntelligenceMapPlaces, type IntelligenceMeta } from "../../services/intelligenceService";
import type { MapSearch } from "../../routes/map";
import FarqMap from "./FarqMap";
import SelectedPlaceSheet from "./SelectedPlaceSheet";
import "../../styles/farq-mapbox.css";

/** Close enough for ranking a handful of pins against one tapped cluster. */
function distanceTo(lat: number, lng: number, toLat: number, toLng: number): number {
	const dLat = lat - toLat;
	const dLng = (lng - toLng) * Math.cos((toLat * Math.PI) / 180);
	return dLat * dLat + dLng * dLng;
}

/** How close the camera goes when a restaurant is picked out of the list. */
const PICK_ZOOM = 16.4;
/** Street level, where a live dot is worth following. */
const LIVE_ZOOM = 16;
/** Restaurants offered for one tapped cluster. */
const CLUSTER_LIST_LIMIT = 15;

/** Feature coordinates arrive untyped from the API — read them, never assume them. */
function lngLat(coordinates: unknown): [number, number] | null {
	if (!Array.isArray(coordinates) || coordinates.length < 2) return null;
	const lng = Number(coordinates[0]); const lat = Number(coordinates[1]);
	return Number.isFinite(lng) && Number.isFinite(lat) ? [lng, lat] : null;
}

function modeLabel(mode: MapZoomMode, isRTL: boolean) {
	if (isRTL) return mode === "discover" ? "اكتشف الفرص" : mode === "opportunity" ? "أكبر فروقات الأسعار" : mode === "restaurant" ? "مطاعم وفرص قريبة" : "المقارنة";
	return mode === "discover" ? "Discover opportunities" : mode === "opportunity" ? "Top price gaps" : mode === "restaurant" ? "Nearby restaurants" : "Comparison";
}

export default function FarqMapExperience({ search }: { search: MapSearch }) {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const { userLocation, locationPinKind, requestLocation, openMapModal } = useLocation();
	const navigate = useNavigate();
	const [meta, setMeta] = useState<IntelligenceMeta | null>(null);
	const [places, setPlaces] = useState<IntelligenceMapPlaces | null>(null);
	const [placeDetail, setPlaceDetail] = useState<IntelligenceMapPlaceDetail | null>(null);
	const [selectedPlaceId, setSelectedPlaceId] = useState(search.place || "");
	const [query, setQuery] = useState(search.q || "");
	const [category, setCategory] = useState(toIntelCategoryId(search.category) || "burgers");
	const [mode, setMode] = useState<MapZoomMode>("discover");
	const [loading, setLoading] = useState(true);
	const [fetching, setFetching] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [drawerOpen, setDrawerOpen] = useState(false);
	const [basemap, setBasemap] = useState<MapboxBasemap>("standard");
	const [focusRequest, setFocusRequest] = useState<{ lat: number; lng: number; id: string; zoom?: number } | null>(null);
	const [clusterPick, setClusterPick] = useState<{ lat: number; lng: number; count: number; id: string } | null>(null);
	const live = useLiveLocation();
	/* Following is the camera promise; the watch is the data. They come apart the
	 * moment the user drags the map, and the dot stays live either way. */
	const [following, setFollowing] = useState(false);
	const pendingLiveZoomRef = useRef(false);
	const requestKeyRef = useRef("");
	const abortRef = useRef<AbortController | null>(null);

	useEffect(() => setSelectedPlaceId(search.place || ""), [search.place]);
	useEffect(() => setQuery(search.q || ""), [search.q]);
	useEffect(() => { if (search.category) setCategory(toIntelCategoryId(search.category)); }, [search.category]);

	useEffect(() => {
		const controller = new AbortController();
		void IntelligenceService.meta(controller.signal).then(setMeta).catch(() => setError(isRTL ? "تعذر تحميل الخريطة." : "Could not load the map.")).finally(() => setLoading(false));
		return () => controller.abort();
	}, [isRTL]);

	const loadViewport = useCallback((bbox: string, zoom: number) => {
		const nextMode = mapZoomMode(zoom);
		setMode(nextMode);
		const key = `${bbox}|${zoom.toFixed(2)}|${category}|${query}`;
		if (requestKeyRef.current === key) return;
		requestKeyRef.current = key;
		abortRef.current?.abort();
		const controller = new AbortController();
		abortRef.current = controller;
		setFetching(true);
		void IntelligenceService.mapPlaces({ bbox, zoom, q: query || undefined, category: category || undefined, layer: "comparison", limit: 400, signal: controller.signal })
			.then((body) => { if (!controller.signal.aborted) setPlaces(body); })
			.catch(() => { if (!controller.signal.aborted) setError(isRTL ? "تعذر تحديث الفرص." : "Could not refresh opportunities."); })
			.finally(() => { if (!controller.signal.aborted) setFetching(false); });
	}, [category, query, isRTL]);

	const onViewChange = useCallback((bbox: string, zoom: number) => loadViewport(bbox, zoom), [loadViewport]);

	useEffect(() => {
		if (!selectedPlaceId) { setPlaceDetail(null); return; }
		const controller = new AbortController();
		void IntelligenceService.mapPlace(selectedPlaceId, controller.signal).then(setPlaceDetail).catch(() => setPlaceDetail(null));
		return () => controller.abort();
	}, [selectedPlaceId]);

	const categories = useMemo(() => {
		const all = meta?.categories || [];
		const preferred = ["burgers", "pizza", "shawarma", "coffee", "grocery"];
		return [...preferred.map((id) => all.find((c) => c.category_id === id)).filter(Boolean) as IntelligenceCategory[], ...all.filter((c) => !preferred.includes(c.category_id))].slice(0, 8);
	}, [meta]);

	const opportunities = useMemo(() => {
		const fromPresentation = places?.presentation?.opportunities || [];
		if (fromPresentation.length) return [...fromPresentation].sort((a, b) => b.opportunity_score - a.opportunity_score);
		return (places?.features || []).flatMap((f) => { if (f.properties.feature_type !== "place") return []; const point = lngLat(f.geometry.coordinates); if (!point) return []; return [{ id: String(f.properties.place_id || ""), type: "opportunity" as const, place: { id: String(f.properties.place_id || ""), restaurant_id: f.properties.restaurant_id || null, name: f.properties.name || null, lat: point[1], lng: point[0], image_url: f.properties.image_url || null }, category: null, product: f.properties.difference?.product_name ? { name: f.properties.difference.product_name } : null, price: { cheapest: f.properties.difference?.cheapest_price ?? null, expensive: f.properties.difference?.expensive_price ?? null, difference: f.properties.difference?.difference_amount ?? null, percentage: null, currency: "SAR" as const }, providers: { count: f.properties.provider_count ?? null }, evidence: { observed: Boolean(f.properties.difference) }, opportunity_score: Number(f.properties.difference?.difference_amount || 0) }]; });
	}, [places]);

	/* The restaurants behind a tapped cluster: nearest first, then biggest gap
	 * first, so the list answers "where is the money here" straight away. */
	const clusterList = useMemo(() => {
		if (!clusterPick) return [];
		return [...opportunities]
			.sort((a, b) => distanceTo(a.place.lat, a.place.lng, clusterPick.lat, clusterPick.lng) - distanceTo(b.place.lat, b.place.lng, clusterPick.lat, clusterPick.lng))
			.slice(0, CLUSTER_LIST_LIMIT)
			.sort((a, b) => (b.price.difference ?? 0) - (a.price.difference ?? 0));
	}, [clusterPick, opportunities]);

	const top = opportunities[0] || null;
	const showUserLocation = locationPinKind === "gps" || locationPinKind === "manual";
	const applyCategory = (next: string) => { setCategory(next); setSelectedPlaceId(""); setQuery(""); requestKeyRef.current = ""; };
	const locate = () => {
		if (live.status === "denied" || live.status === "unsupported") { openMapModal(); return; }
		if (following) { setFollowing(false); live.stop(); return; }
		pendingLiveZoomRef.current = true;
		setFollowing(true);
		live.start();
		/* Keep the older context fix warm for search, without waiting on it. */
		if (locationPinKind !== "gps") requestLocation();
	};
	const selectOpportunity = (item: (typeof opportunities)[number], opts?: { zoom?: number }) => { setClusterPick(null); setSelectedPlaceId(item.place.id); setFocusRequest({ lat: item.place.lat, lng: item.place.lng, id: `place:${item.id}:${opts?.zoom ?? "near"}`, zoom: opts?.zoom }); };
	/* Every fresh fix re-centres while following; the first one also closes in. */
	useEffect(() => {
		if (!following || !live.position) return;
		const zoom = pendingLiveZoomRef.current ? LIVE_ZOOM : undefined;
		pendingLiveZoomRef.current = false;
		setFocusRequest({ lat: live.position.lat, lng: live.position.lng, id: `live:${live.position.lat},${live.position.lng},${zoom ?? ""}`, zoom });
	}, [following, live.position]);

	const openMenu = useCallback((opts: { restaurantId: string; name?: string; image?: string | null }) => { if (!opts.restaurantId) return; void navigate({ to: "/merchant/$type/$id", params: { type: "restaurant", id: opts.restaurantId }, search: { ...(opts.name ? { name: opts.name } : {}), ...(opts.image ? { image: String(opts.image) } : {}) } }); }, [navigate]);


	return (
		<div className="relative h-[calc(100svh-var(--bottom-nav-h))] w-full overflow-hidden bg-surface lg:h-[calc(100dvh-56px)]" dir={isRTL ? "rtl" : "ltr"} data-testid="farq-map-experience" data-map-mode={mode}>
			<div className="absolute inset-0 z-0">
				<FarqMap places={places} neighborhoods={null} selectedPlaceId={selectedPlaceId || undefined} focusRequest={focusRequest} userLocation={live.position ?? userLocation} showUserLocation={Boolean(live.position) || showUserLocation} onUserPan={() => setFollowing(false)} placeDetail={placeDetail} basemap={basemap} onBasemapChange={setBasemap} isRTL={isRTL} onSelectPlace={(id) => { setClusterPick(null); setSelectedPlaceId(id); }} onSelectCluster={(info) => { setSelectedPlaceId(""); setClusterPick({ ...info, id: `cluster:${info.lng.toFixed(4)},${info.lat.toFixed(4)}` }); }} onSelectNeighborhood={() => undefined} onViewChange={onViewChange} hideAddressSearch sheetOpen={Boolean(selectedPlaceId)} mapMode={mode} />
			</div>

			<div className="pointer-events-none absolute inset-x-0 top-0 z-[600] p-3 lg:p-4">
				<div className="pointer-events-auto mx-auto max-w-5xl space-y-2">
					<div className="flex items-center gap-2 rounded-2xl bg-white/95 p-2 shadow-[0_8px_30px_rgba(4,52,52,.12)] backdrop-blur-md">
						<button type="button" className="grid size-11 shrink-0 place-items-center rounded-xl text-brand-900" onClick={() => setDrawerOpen((v) => !v)} aria-label={isRTL ? "استكشاف" : "Explore"}><Menu size={20} /></button>
						<form className="flex min-w-0 flex-1 items-center gap-2" onSubmit={(e) => { e.preventDefault(); requestKeyRef.current = ""; setQuery(query.trim()); }}>
							<Search size={17} className="shrink-0 text-[#6b7c7c]" />
							<input value={query} onChange={(e) => setQuery(e.target.value)} className="h-11 min-w-0 flex-1 bg-transparent text-[14px] font-medium text-brand-900 outline-none" placeholder={isRTL ? "ابحث عن مطعم أو مقهى…" : "Search a restaurant or café…"} />
						</form>
						<button type="button" aria-pressed={following} className={`grid size-11 shrink-0 place-items-center rounded-xl transition-colors ${following ? "bg-mint-500 text-brand-900" : live.status === "live" ? "text-mint-700" : "text-brand-900"}`} onClick={locate} aria-label={isRTL ? (following ? "إيقاف التتبّع" : "موقعي المباشر") : following ? "Stop following" : "My live location"} data-testid="farq-locate-button" data-live={live.status}><LocateFixed size={19} className={live.status === "locating" ? "animate-pulse" : undefined} /></button>
					</div>
					{error ? <div className="rounded-full bg-white/95 px-4 py-2 text-[12px] font-bold text-brand-900 shadow-sm">{error}</div> : null}
					{live.status === "denied" ? <div className="rounded-full bg-white/95 px-4 py-2 text-[12px] font-bold text-brand-900 shadow-sm">{isRTL ? "الموقع مرفوض — فعّله من إعدادات المتصفح أو اختر موقعك يدوياً." : "Location is blocked — enable it in your browser settings, or pick your spot manually."}</div> : null}
					<div className="flex gap-2 overflow-x-auto pb-1 [scrollbar-width:none]">
						<button type="button" onClick={() => { if (top) selectOpportunity(top); }} className="h-10 shrink-0 rounded-full bg-brand-900 px-4 text-[13px] font-black text-mint-500">{top ? `🔥 ${isRTL ? "أكبر فرق" : "Top gap"} ${Math.round(top.price.difference || 0)} ${isRTL ? "ر.س" : "SAR"}` : modeLabel(mode, isRTL)}</button>
						{categories.map((c) => <button key={c.category_id} type="button" onClick={() => applyCategory(c.category_id)} className={`h-10 shrink-0 rounded-full px-4 text-[13px] font-bold ${category === c.category_id ? "bg-mint-500 text-brand-900" : "bg-white/95 text-brand-900 shadow-sm"}`}>{c.category_name_ar || c.category_name || c.category_id}</button>)}
					</div>
				</div>
			</div>

			<div className="pointer-events-none absolute inset-x-0 bottom-0 z-[500] p-3 pb-[calc(env(safe-area-inset-bottom)+12px)] lg:p-4">
				<div className="mx-auto max-w-5xl">
					<div className="flex items-center justify-between gap-3">
						<div className="rounded-full bg-white/92 px-4 py-2 text-[12px] font-bold text-brand-900 shadow-lg backdrop-blur-md">{fetching || loading ? (isRTL ? "نحدّث الفرص…" : "Refreshing opportunities…") : modeLabel(mode, isRTL)}</div>
						{top && !selectedPlaceId ? <button type="button" onClick={() => selectOpportunity(top)} className="pointer-events-auto rounded-2xl bg-brand-900 px-4 py-3 text-start text-white shadow-xl"><span className="block text-[11px] font-medium text-mint-500">{isRTL ? "أكبر فرق حولك" : "Biggest gap here"}</span><strong className="text-[16px]">{top.place.name || (isRTL ? "مطعم" : "Restaurant")} · {Math.round(top.price.difference || 0)} {isRTL ? "ر.س" : "SAR"}</strong></button> : null}
					</div>
				</div>
			</div>

			{drawerOpen ? <div className="absolute inset-0 z-[700] bg-black/20" onClick={() => setDrawerOpen(false)}><aside className="pointer-events-auto h-full w-[min(86vw,360px)] bg-white p-5 shadow-2xl" onClick={(e) => e.stopPropagation()}>
				<div className="mb-5 flex items-center justify-between"><strong className="text-lg text-brand-900">{isRTL ? "استكشاف" : "Explore"}</strong><button type="button" onClick={() => setDrawerOpen(false)}><X size={20} /></button></div>
				<div className="space-y-2"><button type="button" className="w-full rounded-xl bg-brand-900 p-3 text-start font-bold text-mint-500" onClick={() => { if (top) selectOpportunity(top); setDrawerOpen(false); }}>🔥 {isRTL ? "أكبر فرق" : "Biggest gap"}</button>{categories.map((c) => <button key={c.category_id} type="button" className="w-full rounded-xl bg-[#f3f7f7] p-3 text-start font-bold text-brand-900" onClick={() => { applyCategory(c.category_id); setDrawerOpen(false); }}>{c.category_name_ar || c.category_name || c.category_id}</button>)}<div className="my-3 border-t border-[#e6eef0]" /><button type="button" className="w-full rounded-xl bg-[#f3f7f7] p-3 text-start font-bold text-brand-900" onClick={() => { setBasemap(basemap === "standard" ? "satellite" : "standard"); setDrawerOpen(false); }}>{basemap === "standard" ? (isRTL ? "قمر صناعي" : "Satellite") : (isRTL ? "خريطة" : "Map")}</button></div>
			</aside></div> : null}

			{clusterPick && !selectedPlaceId ? (
				<div className="pointer-events-none absolute inset-x-0 bottom-0 z-[750] p-3 pb-[calc(env(safe-area-inset-bottom)+12px)] lg:bottom-4 lg:start-4 lg:end-auto lg:w-[420px] lg:inset-x-auto lg:p-0">
					<div className="pointer-events-auto mx-auto max-w-5xl overflow-hidden rounded-3xl bg-white shadow-[0_18px_50px_rgba(4,52,52,.22)]" data-testid="farq-cluster-sheet">
						<div className="flex items-center justify-between gap-3 px-4 pt-4">
							<div>
								<span className="block text-[11px] font-bold text-[#6b7c7c]">{isRTL ? "مطاعم هذه المنطقة" : "Restaurants here"}</span>
								<strong className="text-[16px] text-brand-900">{isRTL ? `${clusterPick.count} فرصة` : `${clusterPick.count} opportunities`}</strong>
							</div>
							<button type="button" className="grid size-9 place-items-center rounded-full bg-[#f3f7f7] text-brand-900" onClick={() => setClusterPick(null)} aria-label={isRTL ? "إغلاق" : "Close"}><X size={18} /></button>
						</div>
						<div className="mt-3 max-h-[46svh] overflow-y-auto overscroll-contain px-3 pb-3">
							{clusterList.length === 0 ? (
								<p className="px-1 py-6 text-center text-[13px] font-medium text-ink-muted">{fetching ? (isRTL ? "نحمّل مطاعم المنطقة…" : "Loading restaurants here…") : (isRTL ? "قرّب أكثر لعرض المطاعم." : "Zoom in to see the restaurants.")}</p>
							) : (
								<ul className="space-y-1.5">
									{clusterList.map((item) => (
										<li key={item.id}>
											<button type="button" onClick={() => selectOpportunity(item, { zoom: PICK_ZOOM })} className="flex w-full items-center gap-3 rounded-2xl bg-[#f3f7f7] p-3 text-start transition-colors hover:bg-[#e6eef0]">
												<span className="min-w-0 flex-1">
													<strong className="block truncate text-[14px] text-brand-900">{item.place.name || (isRTL ? "مطعم" : "Restaurant")}</strong>
													<span className="text-[11px] font-medium text-[#6b7c7c]">{item.providers.count ? (isRTL ? `${item.providers.count} تطبيقات` : `${item.providers.count} apps`) : isRTL ? "مقارنة" : "Comparison"}</span>
												</span>
												{item.price.difference != null ? (
													<span className="shrink-0 rounded-full bg-brand-900 px-3 py-1.5 text-[12px] font-black text-mint-500">{Math.round(item.price.difference)} {isRTL ? "ر.س" : "SAR"}</span>
												) : null}
											</button>
										</li>
									))}
								</ul>
							)}
						</div>
					</div>
				</div>
			) : null}

			{selectedPlaceId ? <div className="pointer-events-none absolute inset-x-0 bottom-0 z-[800] lg:bottom-4 lg:start-4 lg:end-auto lg:w-[420px] lg:inset-x-auto"><div className="pointer-events-auto"><SelectedPlaceSheet variant="sheet" placeDetail={placeDetail} feature={places?.features.find((f) => String(f.properties.place_id) === selectedPlaceId)?.properties} selectedCategory={meta?.categories.find((c) => c.category_id === category) || null} selectedRestaurantId={placeDetail?.restaurant_id || places?.features.find((f) => String(f.properties.place_id) === selectedPlaceId)?.properties.restaurant_id || ""} isRTL={isRTL} onClose={() => setSelectedPlaceId("")} onOpenMenu={openMenu} /></div></div> : null}
		</div>
	);
}
