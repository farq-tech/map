import { lazy, Suspense } from "react";
import Header from "../components/Header";
import RouteFallback from "../components/RouteFallback";
import { useLanguage } from "../contexts/LanguageContext";
import { usePageMeta } from "../lib/usePageMeta";
import type { MapProduct, MapSearch } from "../routes/map";

const IntelligenceMapSplit = lazy(() => import("../components/intelligence/IntelligenceMapSplit"));
const SaryMapSplit = lazy(() => import("../components/sary/SaryMapSplit"));

export default function MapPage({
	search,
	product = "outdoor",
}: {
	search: MapSearch;
	product?: MapProduct;
}) {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const outdoor = product === "outdoor";

	usePageMeta({
		title: outdoor
			? isRTL
				? "سَرى البارق"
				: "Sary Albarq"
			: isRTL
				? "الخريطة — فرق"
				: "Map — Farq",
		description: outdoor
			? isRTL
				? "خريطة سعودية تستكشف بها البر — صور أقمار وتضاريس ومسارات مرصودة."
				: "A Saudi outdoor map — satellite, terrain, and observed tracks."
			: isRTL
				? "خريطة شوارع حقيقية لدبابيس فرق — إحداثيات ذهبية، بدون بطل وهمي."
				: "A real street map of Farq pins — Golden coordinates, never a fake champion.",
		path: outdoor ? "/map" : "/compare",
		robots: "noindex",
	});

	return (
		<div
			className="farq-map-page flex min-h-0 flex-col lg:min-h-screen"
			data-testid={outdoor ? "sary-map-page" : "intelligence-map-page"}
			data-product={product}
			style={{ ["--bottom-nav-h" as string]: "0px" }}
		>
			{outdoor ? null : (
				<div className="hidden lg:block">
					<Header />
				</div>
			)}
			<Suspense fallback={<RouteFallback />}>
				{outdoor ? <SaryMapSplit search={search} /> : <IntelligenceMapSplit search={search} />}
			</Suspense>
		</div>
	);
}
