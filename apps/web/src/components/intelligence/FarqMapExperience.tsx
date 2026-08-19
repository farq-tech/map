import { LocateFixed, Menu, Search, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useLanguage } from "../../contexts/LanguageContext";
import { useLocation } from "../../contexts/LocationContext";
import { mapZoomMode, type MapZoomMode } from "../../lib/mapExploration";
import type { MapboxBasemap } from "../../lib/mapboxAccess";
import { IntelligenceService, toIntelCategoryId, type IntelligenceCategory, type IntelligenceMapPlaceDetail, type IntelligenceMapPlaces, type IntelligenceMeta } from "../../services/intelligenceService";
import type { MapSearch } from "../../routes/map";
import FarqMap from "./FarqMap";
import SelectedPlaceSheet from "./SelectedPlaceSheet";
import "../../styles/farq-mapbox.css";

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
	const [focusRequest, setFocusRequest] = useState<{ lat: number; lng: number; id: string } | null>(null);
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

	const top = opportunities[0] || null;
	const showUserLocation = locationPinKind === "gps" || locationPinKind === "manual";
	const applyCategory = (next: string) => { setCategory(next); setSelectedPlaceId(""); setQuery(""); requestKeyRef.current = ""; };
	const locate = () => {
		if (showUserLocation && userLocation) { setFocusRequest({ lat: userLocation.lat, lng: userLocation.lng, id: `user:${Date.now()}` }); return; }
		if (locationPinKind === "gps" || locationPinKind === "manual") requestLocation(); else openMapModal();
	};
	const selectOpportunity = (item: (typeof opportunities)[number]) => { setSelectedPlaceId(item.place.id); setFocusRequest({ lat: item.place.lat, lng: item.place.lng, id: `place:${item.id}` }); };
	const openMenu = useCallback((opts: { restaurantId: string; name?: string; image?: string | null }) => { if (!opts.restaurantId) return; void navigate({ to: "/merchant/$type/$id", params: { type: "restaurant", id: opts.restaurantId }, search: { ...(opts.name ? { name: opts.name } : {}), ...(opts.image ? { image: String(opts.image) } : {}) } }); }, [navigate]);


	return (
		<div className="relative h-[calc(100svh-var(--bottom-nav-h))] w-full overflow-hidden bg-surface lg:h-[calc(100dvh-56px)]" dir={isRTL ? "rtl" : "ltr"} data-testid="farq-map-experience" data-map-mode={mode}>
			<div className="absolute inset-0 z-0">
				<FarqMap places={places} neighborhoods={null} selectedPlaceId={selectedPlaceId || undefined} focusRequest={focusRequest} userLocation={userLocation} showUserLocation={showUserLocation} placeDetail={placeDetail} basemap={basemap} onBasemapChange={setBasemap} isRTL={isRTL} onSelectPlace={(id) => setSelectedPlaceId(id)} onSelectNeighborhood={() => undefined} onViewChange={onViewChange} hideAddressSearch sheetOpen={Boolean(selectedPlaceId)} mapMode={mode} />
			</div>

			<div className="pointer-events-none absolute inset-x-0 top-0 z-[600] p-3 lg:p-4">
				<div className="pointer-events-auto mx-auto max-w-5xl space-y-2">
					<div className="flex items-center gap-2 rounded-2xl bg-white/95 p-2 shadow-[0_8px_30px_rgba(4,52,52,.12)] backdrop-blur-md">
						<button type="button" className="grid size-11 shrink-0 place-items-center rounded-xl text-brand-900" onClick={() => setDrawerOpen((v) => !v)} aria-label={isRTL ? "استكشاف" : "Explore"}><Menu size={20} /></button>
						<form className="flex min-w-0 flex-1 items-center gap-2" onSubmit={(e) => { e.preventDefault(); requestKeyRef.current = ""; setQuery(query.trim()); }}>
							<Search size={17} className="shrink-0 text-[#6b7c7c]" />
							<input value={query} onChange={(e) => setQuery(e.target.value)} className="h-11 min-w-0 flex-1 bg-transparent text-[14px] font-medium text-brand-900 outline-none" placeholder={isRTL ? "ابحث عن مطعم أو مقهى…" : "Search a restaurant or café…"} />
						</form>
						<button type="button" className="grid size-11 shrink-0 place-items-center rounded-xl text-brand-900" onClick={locate} aria-label={isRTL ? "موقعي" : "My location"}><LocateFixed size={19} /></button>
					</div>
					{error ? <div className="rounded-full bg-white/95 px-4 py-2 text-[12px] font-bold text-brand-900 shadow-sm">{error}</div> : null}
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

			{selectedPlaceId ? <div className="pointer-events-none absolute inset-x-0 bottom-0 z-[800] lg:bottom-4 lg:start-4 lg:end-auto lg:w-[420px] lg:inset-x-auto"><div className="pointer-events-auto"><SelectedPlaceSheet variant="sheet" placeDetail={placeDetail} feature={places?.features.find((f) => String(f.properties.place_id) === selectedPlaceId)?.properties} selectedCategory={meta?.categories.find((c) => c.category_id === category) || null} selectedRestaurantId={placeDetail?.restaurant_id || places?.features.find((f) => String(f.properties.place_id) === selectedPlaceId)?.properties.restaurant_id || ""} isRTL={isRTL} onClose={() => setSelectedPlaceId("")} onOpenMenu={openMenu} /></div></div> : null}
		</div>
	);
}
