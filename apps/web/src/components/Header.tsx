import { Link } from "@tanstack/react-router";
import { MapPin } from "lucide-react";
import { useLanguage } from "../contexts/LanguageContext";
import { useLocation } from "../contexts/LocationContext";
import FarqBrandMark from "./FarqBrandMark";
import { Button } from "./ui/Button";

export default function Header() {
	const { language, toggleLanguage } = useLanguage();
	const { openMapModal, locationAddress } = useLocation();
	const isRTL = language === "ar";

	return (
		<header className="sticky top-0 z-40 flex items-center justify-between gap-3 bg-brand-900/95 px-4 py-3 backdrop-blur">
			<Link to="/" className="flex items-center gap-2">
				<FarqBrandMark
					variant="lockup"
					size={28}
					wordmarkClassName="h-5 w-auto"
					title={isRTL ? "فرق" : "Farq"}
				/>
				<span className="text-sm font-black text-mint-500">
					{isRTL ? "خريطة فرق" : "Farq Map"}
				</span>
			</Link>
			<div className="flex items-center gap-2">
				<Button
					variant="ghost"
					size="sm"
					className="text-white hover:bg-white/10"
					onClick={openMapModal}
					startIcon={<MapPin className="h-4 w-4" />}
				>
					<span className="max-w-[9rem] truncate text-xs">
						{locationAddress || (isRTL ? "الرياض" : "Riyadh")}
					</span>
				</Button>
				<Button
					variant="outline"
					size="sm"
					className="border-white/20 text-white"
					onClick={toggleLanguage}
				>
					{isRTL ? "EN" : "عربي"}
				</Button>
			</div>
		</header>
	);
}
