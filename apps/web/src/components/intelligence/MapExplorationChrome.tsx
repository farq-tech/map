import { ChevronLeft, Layers3, LocateFixed, Menu, Search, X } from "lucide-react";
import { useMemo, useState } from "react";
import type { MapOpportunity, MapZoomMode } from "../../lib/mapExploration";
import { formatDifference, formatPercentage } from "../../lib/mapExploration";

const FILTERS = [
	{ id: "food", label: "استكشاف", icon: "🧭" },
	{ id: "burgers", label: "برجر", icon: "🍔" },
	{ id: "pizza", label: "بيتزا", icon: "🍕" },
	{ id: "shawarma", label: "شاورما", icon: "🌯" },
	{ id: "coffee", label: "قهوة", icon: "☕" },
	{ id: "grocery", label: "بقالة", icon: "🛒" },
];

export function ExplorationDrawer({ open, onClose, onSelect }: { open: boolean; onClose: () => void; onSelect?: (id: string) => void }) {
	if (!open) return null;
	return (
		<div className="farq-map-drawer-backdrop" onClick={onClose}>
			<aside className="farq-map-drawer" dir="rtl" onClick={(e) => e.stopPropagation()}>
				<div className="farq-map-drawer-head">
					<strong>استكشاف</strong>
					<button type="button" onClick={onClose} aria-label="إغلاق"><X size={20} /></button>
				</div>
				<button className="farq-map-drawer-item is-hot" onClick={() => onSelect?.("largest-gap")}>🔥 أكبر فرق</button>
				<button className="farq-map-drawer-item" onClick={() => onSelect?.("cheapest")}>💰 الأرخص</button>
				<button className="farq-map-drawer-item" onClick={() => onSelect?.("delivery-gap")}>🚚 فرق التوصيل</button>
				<div className="farq-map-drawer-divider" />
				<div className="farq-map-drawer-label">التصنيفات</div>
				{FILTERS.slice(1).map((f) => <button key={f.id} className="farq-map-drawer-item" onClick={() => onSelect?.(f.id)}>{f.icon} {f.label}</button>)}
				<div className="farq-map-drawer-divider" />
				<button className="farq-map-drawer-item" onClick={() => onSelect?.("layers")}><Layers3 size={17} /> طبقات الخريطة</button>
			</aside>
		</div>
	);
}

export function ExplorationSheet({ opportunity, mode, onClose, onNext, onCompare, index, total }: {
	opportunity: MapOpportunity | null;
	mode: MapZoomMode;
	onClose?: () => void;
	onNext?: () => void;
	onCompare?: () => void;
	index?: number;
	total?: number;
}) {
	if (!opportunity) return null;
	const d = formatDifference(opportunity.price.difference);
	const pct = formatPercentage(opportunity.price.percentage);
	return (
		<section className={`farq-exploration-sheet farq-exploration-sheet--${mode}`} dir="rtl">
			<div className="farq-sheet-handle" />
			<div className="farq-sheet-top">
				<span className="farq-opportunity-kicker">🔥 فرصة قوية</span>
				{onClose && <button type="button" onClick={onClose} aria-label="إغلاق"><X size={18} /></button>}
			</div>
			<h2>{opportunity.place.name || "مطعم"}</h2>
			{opportunity.product?.name && <div className="farq-sheet-product">{opportunity.product.name}</div>}
			<div className="farq-price-row">
				<div><small>الأرخص</small><strong>{formatDifference(opportunity.price.cheapest)} <i>ر.س</i></strong></div>
				<div className="farq-price-arrow">→</div>
				<div><small>الأغلى</small><strong>{formatDifference(opportunity.price.expensive)} <i>ر.س</i></strong></div>
			</div>
			<div className="farq-gap-line"><strong>وفر {d} ر.س</strong>{pct && <span>{pct}</span>}</div>
			<div className="farq-provider-line"><span>{opportunity.providers.count || 0} تطبيقات مقارنة</span></div>
			<div className="farq-sheet-actions">
				<button className="farq-primary-cta" onClick={onCompare}>افتح الأرخص <ChevronLeft size={17} /></button>
				{onNext && <button className="farq-secondary-cta" onClick={onNext}>التالي {index && total ? `${index} من ${total}` : ""}</button>}
			</div>
		</section>
	);
}

export default function MapExplorationChrome({ mode, opportunities, onSearch, onLocate, onMenu, onSelectOpportunity }: {
	mode: MapZoomMode;
	opportunities: MapOpportunity[];
	onSearch?: (q: string) => void;
	onLocate?: () => void;
	onMenu?: () => void;
	onSelectOpportunity?: (opportunity: MapOpportunity) => void;
}) {
	const [query, setQuery] = useState("");
	const [filter, setFilter] = useState("food");
	const top = opportunities[0] || null;
	const filters = useMemo(() => FILTERS, []);
	return (
		<>
			<div className="farq-map-chrome" dir="rtl">
				<div className="farq-map-topline">
					<button className="farq-map-icon-button" onClick={onMenu} aria-label="القائمة"><Menu size={20} /></button>
					<div className="farq-map-search">
						<Search size={18} />
						<input value={query} onChange={(e) => { setQuery(e.target.value); onSearch?.(e.target.value); }} placeholder="ماذا تريد أن تستكشف؟" />
					</div>
					<button className="farq-map-icon-button" onClick={onLocate} aria-label="موقعي"><LocateFixed size={19} /></button>
				</div>
				<div className="farq-map-filter-rail" role="tablist">
					{filters.map((f) => <button key={f.id} className={filter === f.id ? "is-active" : ""} onClick={() => setFilter(f.id)}>{f.icon} {f.label}</button>)}
				</div>
				{top && <button className="farq-map-top-opportunity" onClick={() => onSelectOpportunity?.(top)}>
					<span>🔥 أكبر فرصة حولك</span><strong>فرق {formatDifference(top.price.difference)} ر.س</strong>
				</button>}
			</div>
			<div className="farq-map-mode-pill">{mode === "discover" ? "🔥 اكتشف الفرص حولك" : mode === "opportunity" ? "أكبر فروقات الأسعار" : mode === "restaurant" ? "مطاعم وفرص قريبة" : "المقارنة"}</div>
		</>
	);
}
