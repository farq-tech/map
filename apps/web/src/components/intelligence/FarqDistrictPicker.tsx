/**
 * "اختر حي" — the fastest way to a district at any zoom, on any device.
 *
 * One button shows the selected حي (or invites a pick); the panel is a search
 * field over the city's أحياء, busiest first, each with how many observed
 * opportunities it holds and the biggest. Selecting goes through the same
 * path a tap on the map or a copilot answer uses; nothing here is a second
 * source of truth.
 */
import { ChevronDown, MapPin, Search, X } from "lucide-react";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { useFocusTrap } from "../../hooks/useFocusTrap";
import { districtDisplayName, filterDistricts } from "../../lib/farqDistrictSearch";
import { localizeDigitString } from "../../lib/formatPrice";
import type { CityDistricts } from "../../services/intelligenceService";

/** Rows rendered at once; the search narrows long before anyone scrolls this far. */
const ROW_CAP = 120;

export default function FarqDistrictPicker({
	districts,
	selectedId,
	isRTL,
	onSelect,
	onClear,
	variant = "chip",
	className = "",
}: {
	districts: CityDistricts | null;
	selectedId: string;
	isRTL: boolean;
	onSelect: (districtId: string) => void;
	onClear: () => void;
	variant?: "chip" | "toolbar";
	className?: string;
}) {
	const [open, setOpen] = useState(false);
	const [query, setQuery] = useState("");
	const rootRef = useRef<HTMLDivElement | null>(null);
	const triggerRef = useRef<HTMLButtonElement | null>(null);
	const popRef = useRef<HTMLDivElement | null>(null);
	const inputRef = useRef<HTMLInputElement | null>(null);
	const listId = useId();
	useFocusTrap(popRef, open);

	const features = districts?.features ?? null;
	const selected = useMemo(
		() => (selectedId && features ? features.find((f) => f.properties.district_id === selectedId) || null : null),
		[features, selectedId],
	);
	const rows = useMemo(() => filterDistricts(features, query), [features, query]);
	const withOpportunities = useMemo(
		() => (features ? features.filter((f) => f.properties.opportunities > 0).length : 0),
		[features],
	);

	useEffect(() => {
		if (!open) return;
		setQuery("");
		const t = window.setTimeout(() => inputRef.current?.focus(), 30);
		const onPointer = (e: PointerEvent) => {
			if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
		};
		const onKey = (e: KeyboardEvent) => {
			if (e.key !== "Escape") return;
			setOpen(false);
			/* Closing must hand focus back to the button that opened it — otherwise
			 * Escape drops a keyboard user on <body> and they re-tab from the top. */
			triggerRef.current?.focus();
		};
		document.addEventListener("pointerdown", onPointer, true);
		document.addEventListener("keydown", onKey);
		return () => {
			window.clearTimeout(t);
			document.removeEventListener("pointerdown", onPointer, true);
			document.removeEventListener("keydown", onKey);
		};
	}, [open]);

	/**
	 * Arrows walk the list. Every row is a real button, so focus moves rather
	 * than a virtual cursor — Tab-to-row-120 was the only way down before.
	 */
	const moveFocus = (from: HTMLElement, delta: number) => {
		const rows = Array.from(
			popRef.current?.querySelectorAll<HTMLButtonElement>(".farq-district-picker-list button") || [],
		);
		if (!rows.length) return;
		const here = rows.indexOf(from as HTMLButtonElement);
		const next = here < 0 ? (delta > 0 ? 0 : rows.length - 1) : here + delta;
		if (next < 0) {
			inputRef.current?.focus();
			return;
		}
		rows[Math.min(next, rows.length - 1)]?.focus();
	};
	const onListKeyDown = (e: React.KeyboardEvent<HTMLElement>) => {
		if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
		e.preventDefault();
		moveFocus(e.target as HTMLElement, e.key === "ArrowDown" ? 1 : -1);
	};

	const n = (v: number) => localizeDigitString(String(v), isRTL);
	const pick = (id: string) => {
		onSelect(id);
		setOpen(false);
	};
	const label = selected ? districtDisplayName(selected, isRTL) : isRTL ? "اختر حي" : "Pick a district";

	return (
		<div ref={rootRef} className={`farq-district-picker farq-district-picker--${variant} ${className}`}>
			<button
				ref={triggerRef}
				type="button"
				className={`farq-district-picker-btn ${selected ? "is-on" : ""}`}
				aria-haspopup="dialog"
				aria-expanded={open}
				aria-controls={listId}
				disabled={!features}
				data-testid="intelligence-map-district-picker"
				onClick={() => setOpen((v) => !v)}
				title={features ? undefined : isRTL ? "حدود الأحياء غير متاحة لهذه المدينة" : "No district boundaries for this city"}
			>
				<MapPin className="size-3.5 shrink-0" aria-hidden />
				<span className="truncate">{label}</span>
				<ChevronDown className="size-3.5 shrink-0" aria-hidden />
			</button>
			{open && features ? (
				<div
					ref={popRef}
					id={listId}
					role="dialog"
					aria-label={isRTL ? "اختيار الحي" : "Pick a district"}
					className="farq-district-picker-pop"
					data-testid="intelligence-map-district-picker-pop"
				>
					<form
						className="farq-district-picker-search"
						onSubmit={(e) => {
							e.preventDefault();
							if (rows[0]) pick(rows[0].properties.district_id);
						}}
					>
						<Search className="size-4 shrink-0" aria-hidden />
						<input
							ref={inputRef}
							value={query}
							onChange={(e) => setQuery(e.currentTarget.value)}
							placeholder={isRTL ? "ابحث عن حي: النرجس، العليا…" : "Search a district: Narjas, Olaya…"}
							aria-label={isRTL ? "ابحث عن حي" : "Search a district"}
							autoComplete="off"
							enterKeyHint="go"
							onKeyDown={(e) => {
								if (e.key !== "ArrowDown") return;
								e.preventDefault();
								popRef.current
									?.querySelector<HTMLButtonElement>(".farq-district-picker-list button")
									?.focus();
							}}
						/>
						{query ? (
							<button type="button" aria-label={isRTL ? "مسح" : "Clear"} onClick={() => setQuery("")}>
								<X className="size-3.5" aria-hidden />
							</button>
						) : null}
					</form>
					<ul
						className="farq-district-picker-list"
						aria-label={isRTL ? "الأحياء" : "Districts"}
						onKeyDown={onListKeyDown}
					>
						{rows.slice(0, ROW_CAP).map((f) => {
							const p = f.properties;
							const on = p.district_id === selectedId;
							return (
								<li key={p.district_id}>
									<button
										type="button"
										aria-current={on ? "true" : undefined}
										className={`${on ? "is-on" : ""} ${p.opportunities ? "" : "is-empty"}`}
										onClick={() => pick(p.district_id)}
									>
										<span className="name">{districtDisplayName(f, isRTL)}</span>
										<span className="meta">
											{p.opportunities > 0
												? isRTL
													? `${n(p.opportunities)} فرصة · أكبرها ${n(p.max_gap || 0)} ر.س`
													: `${p.opportunities} · biggest ${p.max_gap} SAR`
												: isRTL
													? "لا فرص مرصودة"
													: "no observed gaps"}
										</span>
									</button>
								</li>
							);
						})}
						{rows.length === 0 ? (
							<li className="farq-district-picker-empty">
								{isRTL ? "ما فيه حي بهذا الاسم" : "No district by that name"}
							</li>
						) : null}
					</ul>
					{selected ? (
						<button
							type="button"
							className="farq-district-picker-clear"
							data-testid="intelligence-map-district-picker-clear"
							onClick={() => {
								onClear();
								setOpen(false);
							}}
						>
							{isRTL ? "عرض كل المدينة" : "Show the whole city"}
						</button>
					) : null}
					<p className="farq-district-picker-hint">
						{isRTL
							? `${n(withOpportunities)} حيًا فيه فرص مرصودة من ${n(features.length)}`
							: `${withOpportunities} of ${features.length} districts have observed opportunities`}
					</p>
				</div>
			) : null}
		</div>
	);
}
