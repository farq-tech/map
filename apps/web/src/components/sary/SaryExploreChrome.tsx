import type { OutdoorLayerId } from "../../routes/map";
import type { SheetSnap } from "../intelligence/FarqBottomSheet";
import FarqBottomSheet from "../intelligence/FarqBottomSheet";
import { Button } from "../ui/Button";
import type { ReactNode } from "react";

const LAYERS: Array<{ id: OutdoorLayerId; ar: string; en: string }> = [
	{ id: "around", ar: "حولك", en: "Around" },
	{ id: "tracks", ar: "المسارات", en: "Tracks" },
	{ id: "places", ar: "المعالم", en: "Places" },
	{ id: "trips", ar: "طلعاتي", en: "My trips" },
];

export default function SaryExploreChrome({
	isRTL,
	query,
	onQueryChange,
	onSearchSubmit,
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
}: {
	isRTL: boolean;
	query: string;
	onQueryChange: (v: string) => void;
	onSearchSubmit: () => void;
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
}) {
	return (
		<div className="sary-chrome" data-testid="sary-chrome">
			<form
				className="sary-search"
				onSubmit={(e) => {
					e.preventDefault();
					onSearchSubmit();
				}}
			>
				<input
					value={query}
					onChange={(e) => onQueryChange(e.target.value)}
					placeholder={isRTL ? "روضة خريم، نفود الثمامة، شعيب…" : "Rawdat Khuraim, Nafud, shaib…"}
					aria-label={isRTL ? "بحث" : "Search"}
					data-testid="sary-search"
				/>
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
			<div className="sary-fabs">
				<button
					type="button"
					className="sary-fab"
					onClick={onLocate}
					aria-label={isRTL ? "موقعي" : "My location"}
					data-testid="sary-locate"
				>
					{locating ? "…" : isRTL ? "موقعي" : "Me"}
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
