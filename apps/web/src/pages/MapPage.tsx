import Header from "../components/Header";
import IntelligenceMapSplit from "../components/intelligence/IntelligenceMapSplit";
import { useLanguage } from "../contexts/LanguageContext";
import { usePageMeta } from "../lib/usePageMeta";
import type { MapSearch } from "../routes/map";

export default function MapPage({ search }: { search: MapSearch }) {
	const { language } = useLanguage();
	const isRTL = language === "ar";

	usePageMeta({
		title: isRTL ? "الخريطة — فرق" : "Map — Farq",
		description: isRTL
			? "خريطة شوارع حقيقية لدبابيس فرق — إحداثيات ذهبية، بدون بطل وهمي."
			: "A real street map of Farq pins — Golden coordinates, never a fake champion.",
		path: "/map",
		robots: "noindex",
	});

	return (
		<div className="min-h-screen bg-brand-900" data-testid="intelligence-map-page">
			<Header />
			<IntelligenceMapSplit search={search} />
		</div>
	);
}
