import Header from "../components/Header";
import IntelligenceMapSplit from "../components/intelligence/IntelligenceMapSplit";
import MobileMapExperience from "../components/intelligence/MobileMapExperience";
import { useLanguage } from "../contexts/LanguageContext";
import { usePageMeta } from "../lib/usePageMeta";
import type { MapSearch } from "../routes/map";

export default function MapPage({ search }: { search: MapSearch }) {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	usePageMeta({
		title: isRTL ? "الخريطة — فرق" : "Map — Farq",
		description: isRTL ? "خريطة استكشاف فرص الأسعار في فرق." : "Farq price-opportunity exploration map.",
		path: "/map", robots: "noindex",
	});
	return <div className="relative flex min-h-0 flex-col bg-brand-900 lg:min-h-screen" data-testid="intelligence-map-page">
		<div className="hidden lg:block"><Header /></div>
		<div className="relative min-h-0 flex-1"><IntelligenceMapSplit search={search} /><MobileMapExperience category={search.category} q={search.q} /></div>
	</div>;
}
