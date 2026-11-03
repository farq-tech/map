import type { OutdoorLayerId } from "../../routes/map";
import type { SheetSnap } from "../intelligence/FarqBottomSheet";
import FarqBottomSheet from "../intelligence/FarqBottomSheet";
import { Button } from "../ui/Button";
import { useEffect, useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { loadIdentity, OutingsApi } from "../../lib/outings/api";

/* «مساراتي» are tracks recorded on this phone — not the shared outing (طلعة مشتركة). */
const LAYERS: Array<{ id: OutdoorLayerId; ar: string; en: string }> = [
	{ id: "around", ar: "حولك", en: "Around" },
	{ id: "tracks", ar: "المسارات", en: "Tracks" },
	{ id: "places", ar: "المعالم", en: "Places" },
	{ id: "trips", ar: "مساراتي", en: "My tracks" },
];

/** The first outing this person is in right now, if any — so the entry says «طلعتك جارية». */
function useCurrentOuting(): { id: string; name: string } | null {
	const [current, setCurrent] = useState<{ id: string; name: string } | null>(null);
	useEffect(() => {
		if (!loadIdentity()) return;
		let alive = true;
		OutingsApi.list().then(
			(r) => {
				const row = r.current.find((o) => o.status === "active") || r.current[0];
				if (alive) setCurrent(row ? { id: row.id, name: row.name } : null);
			},
			() => undefined,
		);
		return () => {
			alive = false;
		};
	}, []);
	return current;
}

export default function SaryExploreChrome({
	isRTL,
	query,
	onQueryChange,
	onSearchSubmit,
	onSearchClear,
	searchHint,
	layer,
	onLayer,
	sheetSnap,
	onSheetSnap,
	header,
	children,
	cta,
	onCta,
	onLocate,
	onRecenter,
	showRecenter,
	locating,
	onToggleLanguage,
}: {
	isRTL: boolean;
	query: string;
	onQueryChange: (v: string) => void;
	onSearchSubmit: () => void;
	onSearchClear?: () => void;
	/** One line under the field, e.g. "type at least two letters". */
	searchHint?: string | null;
	layer: OutdoorLayerId;
	onLayer: (layer: OutdoorLayerId) => void;
	sheetSnap: SheetSnap;
	onSheetSnap: (snap: SheetSnap) => void;
	header: ReactNode;
	children: ReactNode;
	cta?: string;
	onCta?: () => void;
	onLocate: () => void;
	onRecenter?: () => void;
	showRecenter?: boolean;
	locating?: boolean;
	onToggleLanguage?: () => void;
}) {
	const outing = useCurrentOuting();
	return (
		<div className="sary-chrome" data-testid="sary-chrome" data-snap={sheetSnap}>
			<form
				className="sary-search"
				role="search"
				onSubmit={(e) => {
					e.preventDefault();
					onSearchSubmit();
				}}
			>
				<input
					value={query}
					onChange={(e) => onQueryChange(e.target.value)}
					placeholder={isRTL ? "روضة خريم، نفود الثمامة، شعيب…" : "Rawdat Khuraim, Nafud, shaib…"}
					aria-label={isRTL ? "ابحث عن روضة أو شعيب أو معلم" : "Search for a rawdah, shaib or place"}
					enterKeyHint="search"
					data-testid="sary-search"
				/>
				{query ? (
					<button
						type="button"
						className="sary-search-clear"
						onClick={() => {
							onQueryChange("");
							onSearchClear?.();
						}}
						aria-label={isRTL ? "مسح البحث" : "Clear search"}
						data-testid="sary-search-clear"
					>
						×
					</button>
				) : null}
				{searchHint ? (
					<p className="sary-search-hint" role="status" data-testid="sary-search-hint">
						{searchHint}
					</p>
				) : null}
			</form>
			<div className="sary-layer-rail" role="tablist" aria-label={isRTL ? "طبقات الخريطة" : "Map layers"}>
				{LAYERS.map((row) => (
					<button
						key={row.id}
						type="button"
						role="tab"
						aria-selected={layer === row.id}
						className={`sary-layer-chip${layer === row.id ? " is-on" : ""}`}
						onClick={() => onLayer(row.id)}
						data-testid={`sary-layer-${row.id}`}
					>
						{isRTL ? row.ar : row.en}
					</button>
				))}
			</div>
			{outing ? (
				<Link
					to="/outings/$id"
					params={{ id: outing.id }}
					className="sary-outing-entry is-live"
					data-testid="sary-outing-entry"
					aria-label={isRTL ? `طلعتك جارية: ${outing.name}` : `Your outing is on: ${outing.name}`}
				>
					<span className="sary-outing-dot" aria-hidden="true" />
					{isRTL ? "طلعتك جارية" : "Outing on"}
				</Link>
			) : (
				<Link to="/outings" className="sary-outing-entry" data-testid="sary-outing-entry">
					{isRTL ? "طلعة مشتركة" : "Shared outing"}
				</Link>
			)}
			<div className="sary-fabs">
				{onToggleLanguage ? (
					<button
						type="button"
						className="sary-fab sary-fab--small"
						onClick={onToggleLanguage}
						aria-label={isRTL ? "Switch to English" : "التبديل إلى العربية"}
						data-testid="sary-lang"
					>
						{isRTL ? "EN" : "ع"}
					</button>
				) : null}
				<button
					type="button"
					className="sary-fab"
					onClick={onLocate}
					aria-label={locating ? (isRTL ? "جارٍ تحديد موقعك" : "Finding your location") : isRTL ? "اذهب إلى موقعي" : "Go to my location"}
					aria-busy={locating || undefined}
					data-testid="sary-locate"
				>
					{locating ? (isRTL ? "جارٍ التحديد…" : "Locating…") : isRTL ? "موقعي" : "Me"}
				</button>
				{showRecenter ? (
					<button
						type="button"
						className="sary-fab"
						onClick={onRecenter}
						data-testid="sary-recenter"
					>
						{isRTL ? "إعادة التمركز" : "Recenter"}
					</button>
				) : null}
			</div>
			<FarqBottomSheet
				snap={sheetSnap}
				onSnap={onSheetSnap}
				isRTL={isRTL}
				testId="sary-sheet"
				header={header}
				rail={
					cta && onCta ? (
						<Button variant="primary" className="sary-cta" onClick={onCta} data-testid="sary-cta">
							{cta}
						</Button>
					) : null
				}
			>
				{children}
			</FarqBottomSheet>
		</div>
	);
}
