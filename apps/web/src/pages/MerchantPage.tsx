import { Link, useParams, useSearch } from "@tanstack/react-router";
import { ArrowRight, MapPin } from "lucide-react";
import { useEffect, useState } from "react";
import EmptyState from "../components/EmptyState";
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
	name_en?: string;
	cheapest_provider?: string;
	cheapest_price?: number | null;
	starting_price?: number | null;
	dearest_price?: number | null;
	difference_amount?: number | null;
	savings?: number | null;
	cheapest_offer?: { price?: number | null } | null;
};

type CatalogCategory = {
	name_ar?: string;
	name_en?: string;
	item_count?: number;
	items?: MenuItem[];
};

type CatalogBody = {
	ok?: boolean;
	restaurant?: { name_ar?: string; name_en?: string; image_url?: string };
	categories?: CatalogCategory[];
	items?: MenuItem[];
	error?: string;
	note?: string;
};

function finiteAmount(
	...candidates: Array<number | null | undefined>
): number | null {
	for (const raw of candidates) {
		const n = Number(raw);
		if (Number.isFinite(n)) return n;
	}
	return null;
}

function itemGap(item: MenuItem): number | null {
	const n = finiteAmount(item.difference_amount, item.savings);
	return n != null && n > 0 ? n : null;
}

function itemPrice(item: MenuItem): number | null {
	return finiteAmount(
		item.cheapest_price,
		item.starting_price,
		item.cheapest_offer?.price,
	);
}

function flattenCatalog(body: CatalogBody | null | undefined): MenuItem[] {
	if (Array.isArray(body?.items) && body.items.length) return body.items;
	const categories = Array.isArray(body?.categories) ? body.categories : [];
	return categories.flatMap((c) => (Array.isArray(c.items) ? c.items : []));
}

function MenuRow({ item, isRTL }: { item: MenuItem; isRTL: boolean }) {
	const gap = itemGap(item);
	const price = itemPrice(item);
	return (
		<li className="flex items-center justify-between rounded-xl bg-[#0b2c2c] px-4 py-3">
			<span>
				{isRTL
					? item.name_ar || item.name_en || item.name
					: item.name_en || item.name_ar || item.name}
			</span>
			{gap != null ? (
				<span className="text-mint-500">
					{localizeDigitString(String(Math.round(gap)), isRTL)} ر.س
				</span>
			) : price != null ? (
				<span className="text-mint-500">
					{localizeDigitString(String(Math.round(price)), isRTL)} ر.س
				</span>
			) : null}
		</li>
	);
}

export default function MerchantPage() {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const { type, id } = useParams({ from: "/merchant/$type/$id" });
	const search = useSearch({ from: "/merchant/$type/$id" });
	const [place, setPlace] = useState<IntelligenceMapPlaceDetail | null>(null);
	const [items, setItems] = useState<MenuItem[]>([]);
	const [categories, setCategories] = useState<CatalogCategory[]>([]);

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
		void fetchApi<CatalogBody>(
			`/api/comparison/restaurants/${encodeURIComponent(id)}/catalog`,
			{ signal: controller.signal },
		)
			.then((env) => {
				const body = env.data || {};
				const cats = Array.isArray(body.categories) ? body.categories : [];
				setCategories(cats);
				setItems(flattenCatalog(body));
			})
			.catch(() => {
				setCategories([]);
				setItems([]);
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
						<EmptyState
							title="No comparison menu yet"
							titleAr="ما عندنا قائمة مقارنة بعد"
							body="This restaurant is on the map, but Farq does not have a comparison menu for it yet."
							bodyAr="المطعم ظاهر على الخريطة، بس ما عندنا قائمة مقارنة له بعد."
						/>
					) : (
						<div className="space-y-4">
							{categories.length
								? categories.map((cat, ci) => (
										<div key={`${cat.name_en || cat.name_ar || "cat"}-${ci}`}>
											<h3 className="mb-2 text-sm font-semibold text-[#cfe8d8]">
												{isRTL
													? cat.name_ar || cat.name_en
													: cat.name_en || cat.name_ar}
											</h3>
											<ul className="space-y-2">
												{(cat.items || []).slice(0, 24).map((item, i) => (
													<MenuRow
														key={`${item.name || "item"}-${i}`}
														item={item}
														isRTL={isRTL}
													/>
												))}
											</ul>
										</div>
									))
								: (
									<ul className="space-y-2">
										{items.slice(0, 24).map((item, i) => (
											<MenuRow
												key={`${item.name || "item"}-${i}`}
												item={item}
												isRTL={isRTL}
											/>
										))}
									</ul>
								)}
						</div>
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
