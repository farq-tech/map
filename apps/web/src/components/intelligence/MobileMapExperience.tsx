import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useLocation } from "../../contexts/LocationContext";
import { fetchApi } from "../../lib/api";
import { mapZoomMode, type MapExplorationPresentation, type MapOpportunity } from "../../lib/mapExploration";
import { trackFarqMap } from "../../lib/mapTelemetry";
import MapExplorationChrome, { ExplorationDrawer, ExplorationSheet } from "./MapExplorationChrome";
import "../../styles/farq-mobile-map.css";

export default function MobileMapExperience({ category, q }: { category?: string; q?: string }) {
	const navigate = useNavigate(); const { requestLocation } = useLocation();
	const [activeCategory, setActiveCategory] = useState(category || ""); const [openDrawer, setOpenDrawer] = useState(false);
	const [selected, setSelected] = useState<MapOpportunity | null>(null); const [opportunities, setOpportunities] = useState<MapOpportunity[]>([]);
	const [index, setIndex] = useState(0); const [mode, setMode] = useState(mapZoomMode(11));
	useEffect(() => setActiveCategory(category || ""), [category]);
	useEffect(() => {
		const controller = new AbortController(); const qs = new URLSearchParams({ zoom: "11", limit: "80" });
		if (activeCategory && activeCategory !== "food") qs.set("category", activeCategory); if (q) qs.set("q", q);
		trackFarqMap("map_open", { category: activeCategory || "all" });
		void fetchApi<MapExplorationPresentation>(`/api/intelligence/map/opportunities?${qs}`, { signal: controller.signal }, { timeoutMs: 15_000 }).then((env) => {
			if (controller.signal.aborted) return; setOpportunities(env.data.opportunities || []); setMode(mapZoomMode(env.data.viewport.zoom || 11)); trackFarqMap("map_ready", { count: env.data.opportunities?.length || 0 });
		}).catch(() => undefined); return () => controller.abort();
	}, [activeCategory, q]);
	const ordered = useMemo(() => [...opportunities].sort((a, b) => b.opportunity_score - a.opportunity_score), [opportunities]);
	function selectOpportunity(item: MapOpportunity) { const i = ordered.findIndex((x) => x.id === item.id); setIndex(Math.max(0, i)); setSelected(item); trackFarqMap("opportunity_selected", { id: item.id, difference: item.price.difference }); }
	function nextOpportunity() { if (!ordered.length) return; const next = (index + 1) % ordered.length; setIndex(next); setSelected(ordered[next]); trackFarqMap("next_opportunity", { from: index, to: next }); }
	function chooseDrawer(id: string) {
		setOpenDrawer(false);
		if (["burgers", "pizza", "coffee", "shawarma", "grocery"].includes(id)) { setActiveCategory(id); trackFarqMap("category_changed", { category: id }); return; }
		if (id === "largest-gap") { if (ordered[0]) selectOpportunity(ordered[0]); return; }
	}
	return <>
		<MapExplorationChrome mode={mode} opportunities={ordered} onMenu={() => setOpenDrawer(true)} onLocate={() => { trackFarqMap("location_requested"); requestLocation(); }} onSearch={() => undefined} onSelectOpportunity={selectOpportunity} />
		<ExplorationDrawer open={openDrawer} onClose={() => setOpenDrawer(false)} onSelect={chooseDrawer} />
		<ExplorationSheet opportunity={selected} mode={mode} index={index + 1} total={ordered.length} onClose={() => setSelected(null)} onNext={nextOpportunity} onCompare={() => {
			if (!selected?.place.restaurant_id) return; trackFarqMap("compare_clicked", { id: selected.id }); trackFarqMap("provider_opened", { id: selected.id, provider: selected.providers.cheapest || null });
			void navigate({ to: "/merchant/$type/$id", params: { type: "restaurant", id: selected.place.restaurant_id } });
		}} />
		<button className="farq-mobile-locate" onClick={() => { trackFarqMap("location_requested"); requestLocation(); }} aria-label="موقعي">◎</button>
	</>;
}
