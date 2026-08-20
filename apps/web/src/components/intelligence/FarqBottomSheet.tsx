/**
 * The mobile sheet — the list is this, the map is behind it.
 *
 * Three detents: peek (one honest line + the sort rail), half (the list or the
 * selected place), full (the same with room). The map never hides; the sheet
 * drops to peek when the map is touched and rises when something is chosen.
 * A tap on the handle steps it up; the chevron steps it down; drags move it.
 */
import { ChevronDown } from "lucide-react";
import {
	useRef,
	useState,
	type PointerEvent as ReactPointerEvent,
	type ReactNode,
} from "react";

export type SheetSnap = "peek" | "half" | "full";

const ORDER: SheetSnap[] = ["peek", "half", "full"];

/** Heights in CSS px the camera can rely on (matched in farq-mapbox.css). */
export function sheetHeightPx(snap: SheetSnap, viewportHeight: number): number {
	if (snap === "peek") return 148;
	if (snap === "half") return Math.round(viewportHeight * 0.52);
	return Math.round(viewportHeight * 0.9);
}

export function stepSnap(snap: SheetSnap, direction: 1 | -1): SheetSnap {
	const i = ORDER.indexOf(snap);
	return ORDER[Math.min(ORDER.length - 1, Math.max(0, i + direction))];
}

export default function FarqBottomSheet({
	snap,
	onSnap,
	isRTL,
	header,
	rail,
	children,
	testId = "farq-sheet",
}: {
	snap: SheetSnap;
	onSnap: (snap: SheetSnap) => void;
	isRTL: boolean;
	/** One line that is true for what the camera shows. */
	header: ReactNode;
	/** Sort chips / quick filters shown at every detent. */
	rail?: ReactNode;
	children?: ReactNode;
	testId?: string;
}) {
	const dragRef = useRef<{ pointerId: number; startY: number; moved: boolean } | null>(null);
	const [dragDy, setDragDy] = useState(0);

	const onPointerDown = (ev: ReactPointerEvent<HTMLDivElement>) => {
		ev.currentTarget.setPointerCapture(ev.pointerId);
		dragRef.current = { pointerId: ev.pointerId, startY: ev.clientY, moved: false };
		setDragDy(0);
	};
	const onPointerMove = (ev: ReactPointerEvent<HTMLDivElement>) => {
		const d = dragRef.current;
		if (!d || d.pointerId !== ev.pointerId) return;
		const dy = ev.clientY - d.startY;
		if (Math.abs(dy) > 6) d.moved = true;
		/* growing past full or shrinking past peek is resisted, not allowed */
		const limited =
			(dy < 0 && snap === "full") || (dy > 0 && snap === "peek") ? dy * 0.25 : dy;
		setDragDy(limited);
	};
	const onPointerUp = (ev: ReactPointerEvent<HTMLDivElement>) => {
		const d = dragRef.current;
		dragRef.current = null;
		setDragDy(0);
		if (!d || d.pointerId !== ev.pointerId) return;
		const dy = ev.clientY - d.startY;
		if (!d.moved) {
			onSnap(stepSnap(snap, snap === "full" ? -1 : 1));
			return;
		}
		if (dy < -56) onSnap(stepSnap(snap, 1));
		else if (dy > 56) onSnap(stepSnap(snap, -1));
	};

	return (
		<section
			className="farq-sheet"
			data-snap={snap}
			data-testid={testId}
			style={dragDy ? { transform: `translateY(${dragDy}px)`, transition: "none" } : undefined}
			aria-label={isRTL ? "النتائج" : "Results"}
		>
			<div
				className="farq-sheet-grab touch-none"
				data-testid="farq-sheet-handle"
				onPointerDown={onPointerDown}
				onPointerMove={onPointerMove}
				onPointerUp={onPointerUp}
				onPointerCancel={onPointerUp}
				role="button"
				tabIndex={0}
				aria-label={isRTL ? "اسحب لتغيير حجم القائمة" : "Drag to resize the list"}
				onKeyDown={(e) => {
					if (e.key === "ArrowUp") onSnap(stepSnap(snap, 1));
					if (e.key === "ArrowDown") onSnap(stepSnap(snap, -1));
				}}
			>
				<span className="farq-sheet-handle" aria-hidden />
				<div className="farq-sheet-head">
					<div className="farq-sheet-headline">{header}</div>
					{snap !== "peek" ? (
						<button
							type="button"
							className="farq-sheet-collapse"
							aria-label={isRTL ? "تصغير" : "Collapse"}
							onPointerDown={(e) => e.stopPropagation()}
							onClick={() => onSnap(stepSnap(snap, -1))}
						>
							<ChevronDown className="size-4" />
						</button>
					) : null}
				</div>
				{rail ? <div className="farq-sheet-rail">{rail}</div> : null}
			</div>
			<div className="farq-sheet-body" data-testid="farq-sheet-body">
				{children}
			</div>
		</section>
	);
}
