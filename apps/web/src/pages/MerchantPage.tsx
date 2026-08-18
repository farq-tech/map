import { Link, useParams, useSearch } from "@tanstack/react-router";
import { ArrowRight, MapPin } from "lucide-react";
import { useEffect, useState } from "react";
import Header from "../components/Header";
import { ProviderLogoMark } from "../components/ProviderLogoMark";
import { Button } from "../components/ui/Button";
import { useLanguage } from "../contexts/LanguageContext";
import { fetchApi } from "../lib/api";
import { localizeDigitString } from "../lib/formatPrice";
import { usePageMeta } from "../lib/usePageMeta";
import {
	IntelligenceService,
	type IntelligenceMapPlaceDetail,
} from "../services/intelligenceService";

type MenuItem = {
	name?: string;
	name_ar?: string;
	cheapest_provider?: string;
	cheapest_price?: number;
	dearest_price?: number;
	difference_amount?: number;
};

export default function MerchantPage() {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const { type, id } = useParams({ from: "/merchant/$type/$id" });
	const search = useSearch({ from: "/merchant/$type/$id" });
	const [place, setPlace] = useState<IntelligenceMapPlaceDetail | null>(null);
	const [items, setItems] = useState<MenuItem[]>([]);
	const [error, setError] = useState<string | null>(null);

	usePageMeta({
		title: search.name
			? `${search.name} — Farq Map`
			: isRTL
				? "قائمة المطعم — فرق"
				: "Restaurant menu — Farq",
		path: `/merchant/${type}/${id}`,
		robots: "noindex",
	});

	useEffect(() => {
		const controller = new AbortController();
		void IntelligenceService.mapPlace(id, controller.signal)
			.then(setPlace)
			.catch(() => setPlace(null));
		void fetchApi<{ items?: MenuItem[] }>(`/api/restaurant/${encodeURIComponent(id)}/menu`, {
			signal: controller.signal,
		})
			.then((env) => setItems(Array.isArray(env.data?.items) ? env.data.items : []))
			.catch(() => {
				setItems([]);
				setError(null);
			});
		return () => controller.abort();
	}, [id]);

	const title = place?.name || search.name || (isRTL ? "مطعم" : "Restaurant");
	const image = place?.image_url || search.image;
	const gap = place?.difference?.difference_amount;

	return (
		<div className="min-h-screen bg-brand-900 text-white">
			<Header />
			<main className="mx-auto max-w-2xl px-4 py-6">
				<Link to="/map" className="mb-4 inline-flex items-center gap-2 text-sm text-mint-500">
					<ArrowRight className={`h-4 w-4 ${isRTL ? "" : "rotate-180"}`} />
					{isRTL ? "رجوع للخريطة" : "Back to map"}
				</Link>
				<div className="overflow-hidden rounded-2xl bg-[#0b2c2c]">
					{image ? (
						<img src={image} alt="" className="h-40 w-full object-cover" />
					) : null}
					<div className="p-5">
						<h1 className="text-2xl font-black">{title}</h1>
						<p className="mt-1 flex items-center gap-1 text-sm text-[#9bb0b0]">
							<MapPin className="h-4 w-4" />
							{place?.city || "Riyadh"}
						</p>
						{gap != null ? (
							<p className="mt-3 text-mint-500">
								{isRTL ? "أكبر فرق مرصود" : "Largest observed gap"}{" "}
								<span className="text-2xl font-black">
									{localizeDigitString(String(Math.round(gap)), isRTL)} ر.س
								</span>
							</p>
						) : null}
						{place?.difference?.cheapest_provider_id ? (
							<div className="mt-3 flex items-center gap-2">
								<ProviderLogoMark
									provider={place.difference.cheapest_provider_id}
									isRTL={isRTL}
									size={28}
								/>
								<span className="text-sm text-[#cfe8d8]">
									{isRTL ? "الأرخص المرصود" : "Observed cheapest app"}
								</span>
							</div>
						) : null}
					</div>
				</div>
				<section className="mt-6">
					<h2 className="mb-3 text-lg font-bold">
						{isRTL ? "بنود المقارنة" : "Comparison items"}
					</h2>
					{items.length === 0 ? (
						<p className="text-sm text-[#9bb0b0]">
							{error ||
								(isRTL
									? "لا توجد قائمة محلية — عيّن FARQ_API_ORIGIN أو SUPABASE_COMPARISON_DB_URL لجلب القائمة."
									: "No local menu — set FARQ_API_ORIGIN or SUPABASE_COMPARISON_DB_URL to load items.")}
						</p>
					) : (
						<ul className="space-y-2">
							{items.slice(0, 24).map((item, i) => (
								<li
									key={`${item.name || "item"}-${i}`}
									className="flex items-center justify-between rounded-xl bg-[#0b2c2c] px-4 py-3"
								>
									<span>{isRTL ? item.name_ar || item.name : item.name}</span>
									{item.difference_amount != null ? (
										<span className="text-mint-500">
											{localizeDigitString(
												String(Math.round(item.difference_amount)),
												isRTL,
											)}{" "}
											ر.س
										</span>
									) : null}
								</li>
							))}
						</ul>
					)}
				</section>
				<div className="mt-8">
					<Button asChild variant="primary" className="w-full text-mint-500">
						<Link to="/map" search={{ place: id }}>
							{isRTL ? "عرض على الخريطة" : "Show on map"}
						</Link>
					</Button>
				</div>
			</main>
		</div>
	);
}
