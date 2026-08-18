import { Link, useSearch } from "@tanstack/react-router";
import Header from "../components/Header";
import { useLanguage } from "../contexts/LanguageContext";

export default function GroceryStubPage() {
	const { language } = useLanguage();
	const isRTL = language === "ar";
	const search = useSearch({ from: "/grocery" });

	return (
		<div className="min-h-screen bg-brand-900 text-white">
			<Header />
			<main className="mx-auto max-w-lg px-4 py-16 text-center">
				<h1 className="text-2xl font-black text-mint-500">
					{isRTL ? "مقارنة البقالة" : "Grocery compare"}
				</h1>
				<p className="mt-3 text-sm text-[#9bb0b0]">
					{isRTL
						? "هذه معاينة المستثمر لخريطة فرق. مقارنة البقالة الكاملة ليست ضمن هذا المستودع."
						: "This investor preview is the Farq map. Full grocery compare is not in this repo."}
				</p>
				{search.q ? (
					<p className="mt-2 text-mint-500">{search.q}</p>
				) : null}
				<Link to="/map" className="mt-6 inline-block text-mint-500 underline">
					{isRTL ? "العودة للخريطة" : "Back to the map"}
				</Link>
			</main>
		</div>
	);
}
