/**
 * Premium selected-place moment on `/map`.
 * Photo only when the API returns image_url — never invent URLs.
 * App marks come from getProviderLogo / ProviderLogoMark (bundled assets).
 * CTA «افتح الأرخص» opens the real /merchant/restaurant/:id menu.
 */
import { Link } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, MapPin, X } from "lucide-react";
import {
	useEffect,
	useRef,
	useState,
	type PointerEvent as ReactPointerEvent,
} from "react";
import { useCountUp } from "../../hooks/useCountUp";
import { localizeDigitString } from "../../lib/formatPrice";
import { getProviderLabel, getProviderLogo } from "../../lib/platformLogos";
import type {
	IntelligenceCategory,
	IntelligenceMapPlaceDetail,
	IntelligenceMapPlaceProperties,
} from "../../services/intelligenceService";
import { ProviderLogoMark } from "../ProviderLogoMark";
import { Button } from "../ui/Button";

function freshnessFromObserved(
	iso: string | null | undefined,
	isRTL: boolean,
): { kind: "today" | "week" | "older"; label: string } | null {
	if (!iso) return null;
	const t = Date.parse(iso);
	if (!Number.isFinite(t)) return null;
	const ageMs = Date.now() - t;
	const hours = ageMs / 3_600_000;
	if (hours < 24) {
		const mins = Math.max(1, Math.round(Math.max(0, ageMs) / 60_000));
		return {
			kind: "today",
			label: isRTL
				? `الأسعار محدثة آلياً قبل ${localizeDigitString(String(mins), true)} دقيقة`
				: `Prices updated ${mins} min ago`,
		};
	}
	if (hours < 24 * 7) {
		return { kind: "week", label: isRTL ? "هذا الأسبوع" : "This week" };
	}
	return { kind: "older", label: isRTL ? "قديم" : "Older" };
}

function observedImageUrl(
	...candidates: Array<string | null | undefined>
): string | null {
	for (const raw of candidates) {
		const url = String(raw || "").trim();
		if (!url) continue;
		if (!/^https?:\/\//i.test(url) && !url.startsWith("/")) continue;
		return url;
	}
	return null;
}

function GapCountBadge({
	amount,
	isRTL,
}: {
	amount: number;
	isRTL: boolean;
}) {
	const live = useCountUp(amount);
	const digits = localizeDigitString(String(Math.round(live)), isRTL);
	return (
		<span
			className="rounded-[10px] bg-mint-500 px-3 py-1.5 text-[40px] font-black leading-none text-brand-900 lg:text-[48px]"
			data-testid="intelligence-map-gap-count"
		>
			{digits} {isRTL ? "ر.س فرق" : "SAR gap"}
		</span>
	);
}

function AppMark({
	provider,
	isRTL,
	size,
}: {
	provider: string | null | undefined;
	isRTL: boolean;
	size: number;
}) {
	const logo = getProviderLogo(provider);
	return (
		<ProviderLogoMark
			provider={provider}
			label={isRTL ? logo?.labelAr : logo?.label}
			isRTL={isRTL}
			size={size}
			rounded="md"
			tintedFallback
		/>
	);
}

export default function SelectedPlaceSheet({
	placeDetail,
	feature,
	selectedCategory,
	selectedRestaurantId,
	isRTL,
	variant,
	onClose,
	onHide,
	onOpenMenu,
	opportunityIndex,
	opportunityCount,
	onPrevOpportunity,
	onNextOpportunity,
}: {
	placeDetail: IntelligenceMapPlaceDetail | null;
	feature?: IntelligenceMapPlaceProperties | null;
	selectedCategory?: IntelligenceCategory | null;
	selectedRestaurantId?: string;
	isRTL: boolean;
	variant: "sheet" | "panel" | "popup";
	onClose: () => void;
	onHide?: () => void;
	onOpenMenu: (opts: {
		restaurantId: string;
		name?: string;
		image?: string | null;
	}) => void;
	opportunityIndex?: number;
	opportunityCount?: number;
	onPrevOpportunity?: () => void;
	onNextOpportunity?: () => void;
}) {
	const imageUrl = observedImageUrl(
		placeDetail?.image_url,
		feature?.image_url,
		feature?.branch_image_url,
		feature?.restaurant_logo_url,
		feature?.restaurant_image_url,
		feature?.restaurant_image,
	);
	const restaurantName =
		placeDetail?.name_ar ||
		placeDetail?.name ||
		feature?.name ||
		(isRTL ? "مطعم" : "Restaurant");
	const restaurantNameEn = placeDetail?.name_en;
	const difference = (placeDetail?.difference ||
		feature?.difference ||
		null) as {
		product_name?: string | null;
		cheapest_provider_id?: string | null;
		expensive_provider_id?: string | null;
		cheapest_price?: number | null;
		expensive_price?: number | null;
		difference_amount?: number | null;
		observed_at?: string | null;
	} | null;
	const mealName =
		difference?.product_name || feature?.product_name || null;
	const gapAmount = Number(
		difference?.difference_amount ?? feature?.gap,
	);
	const hasGap = Number.isFinite(gapAmount) && gapAmount > 0;
	const cheap = Number(
		difference?.cheapest_price ?? feature?.cheapest_price,
	);
	const expensive = Number(
		difference?.expensive_price ?? feature?.expensive_price,
	);
	const cheapProvider =
		difference?.cheapest_provider_id || feature?.cheapest_provider_id;
	const expensiveProvider =
		difference?.expensive_provider_id || feature?.expensive_provider_id;
	const hasPrices =
		Number.isFinite(cheap) && Number.isFinite(expensive) && expensive > 0;
	const cheapPct = hasPrices
		? Math.max(8, Math.min(92, (cheap / expensive) * 100))
		: 0;
	const fresh = freshnessFromObserved(difference?.observed_at, isRTL);
	const categoryLabel = [
		placeDetail?.subcategory ||
			placeDetail?.category ||
			selectedCategory?.category_name_ar ||
			selectedCategory?.category_name,
		placeDetail?.city,
	]
		.filter(Boolean)
		.join(" · ");

	const openMenu = () => {
		if (!selectedRestaurantId) return;
		onOpenMenu({
			restaurantId: selectedRestaurantId,
			name: restaurantName,
			image: imageUrl,
		});
	};

	const hideButton = onHide ? (
		<button
			type="button"
			className="farq-place-hit flex size-9 items-center justify-center rounded-2xl bg-white text-brand-900 shadow-sm"
			aria-label={isRTL ? "إخفاء" : "Hide"}
			data-testid="intelligence-map-place-hide"
			onClick={onHide}
		>
			{isRTL ? (
				<ChevronRight className="size-3.5" />
			) : (
				<ChevronLeft className="size-3.5" />
			)}
		</button>
	) : null;

	const opportunityNav =
		opportunityCount &&
		opportunityCount > 1 &&
		opportunityIndex != null &&
		opportunityIndex >= 0 ? (
			<div className="flex shrink-0 items-center gap-1">
				<button
					type="button"
					className="inline-flex h-9 items-center rounded-full bg-[#e6eef0] px-3 text-[12px] font-extrabold text-brand-900 disabled:opacity-30"
					aria-label={isRTL ? "السابق" : "Previous"}
					disabled={opportunityIndex <= 0}
					onClick={(e) => {
						e.stopPropagation();
						onPrevOpportunity?.();
					}}
				>
					{isRTL ? "→ السابق" : "← Prev"}
				</button>
				<span
					className="min-w-10 text-center text-[12px] font-bold text-brand-900"
					data-testid="intelligence-map-opportunity-index"
				>
					{localizeDigitString(String(opportunityIndex + 1), isRTL)}{" "}
					{isRTL ? "من" : "of"}{" "}
					{localizeDigitString(String(opportunityCount), isRTL)}{" "}
					{isRTL ? "فرق" : ""}
				</span>
				<button
					type="button"
					className="inline-flex h-9 items-center rounded-full bg-mint-500 px-3 text-[12px] font-extrabold text-brand-900 disabled:opacity-30"
					aria-label={isRTL ? "التالي" : "Next"}
					disabled={opportunityIndex >= opportunityCount - 1}
					onClick={(e) => {
						e.stopPropagation();
						onNextOpportunity?.();
					}}
				>
					{isRTL ? "التالي ←" : "Next →"}
				</button>
			</div>
		) : null;

	if (variant === "popup") {
		return (
			<div
				className="farq-place-popup pointer-events-auto"
				data-testid="intelligence-map-place-sheet"
				data-sheet-snap="peek"
			>
				<div className="absolute end-2 top-2 flex items-center gap-1">
					{onHide ? (
						<button
							type="button"
							className="inline-flex size-8 items-center justify-center rounded-full bg-[#e6eef0] text-brand-900"
							aria-label={isRTL ? "إخفاء" : "Hide"}
							data-testid="intelligence-map-place-hide"
							onClick={onHide}
						>
							{isRTL ? (
								<ChevronRight className="size-3.5" />
							) : (
								<ChevronLeft className="size-3.5" />
							)}
						</button>
					) : null}
					<button
						type="button"
						className="inline-flex size-8 items-center justify-center rounded-full bg-[#e6eef0] text-brand-900"
						aria-label={isRTL ? "إغلاق" : "Close"}
						onClick={onClose}
					>
						<X className="size-3.5" />
					</button>
				</div>
				{hasGap ? (
					<p className="pe-8 text-[22px] font-black leading-none text-brand-900">
						{localizeDigitString(String(Math.round(gapAmount)), isRTL)}{" "}
						{isRTL ? "ر.س فرق" : "SAR gap"}
					</p>
				) : (
					<p className="pe-8 text-[13px] font-bold text-[#6b7c7c]">
						{isRTL ? "ما رصدنا فرقاً بعد" : "No observed gap yet"}
					</p>
				)}
				{categoryLabel ? (
					<p className="mt-1.5 text-[11px] font-bold text-[#6b7c7c]">{categoryLabel}</p>
				) : null}
				<p className="mt-0.5 text-[13px] font-bold leading-snug text-brand-900">
					{restaurantName}
				</p>
				{(cheapProvider || expensiveProvider) && (
					<div
						className="mt-3 flex items-center justify-between gap-2"
						data-testid="intelligence-map-place-apps"
					>
						<div className="flex min-w-0 items-center gap-2">
							<AppMark
								provider={cheapProvider}
								isRTL={isRTL}
								size={32}
							/>
							<div className="min-w-0">
								<p className="text-[10px] font-extrabold text-mint-700">
									{isRTL ? "الأرخص" : "Cheapest"}
								</p>
								<p className="truncate text-[12px] font-black text-brand-900">
									{getProviderLabel(cheapProvider, {
										isRTL,
									}) || (isRTL ? "الأرخص" : "Cheapest")}
									{hasPrices
										? ` · ${localizeDigitString(String(cheap), isRTL)} ${isRTL ? "ر.س" : "SAR"}`
										: ""}
								</p>
							</div>
						</div>
						<span className="text-[12px] font-black text-[#6b7c7c]" aria-hidden>
							← →
						</span>
						<div className="flex min-w-0 items-center gap-2">
							<div className="min-w-0 text-end">
								<p className="text-[10px] font-extrabold text-[#c45c5c]">
									{expensiveProvider
										? isRTL
											? "الأغلى"
											: "Highest"
										: isRTL
											? "أعلى سعر مرصود"
											: "Highest observed price"}
								</p>
								<p className="truncate text-[12px] font-black text-brand-900">
									{expensiveProvider
										? getProviderLabel(expensiveProvider, { isRTL }) || expensiveProvider
										: ""}
									{hasPrices
										? `${expensiveProvider ? " · " : ""}${localizeDigitString(String(expensive), isRTL)} ${isRTL ? "ر.س" : "SAR"}`
										: ""}
								</p>
							</div>
							{expensiveProvider ? (
								<AppMark provider={expensiveProvider} isRTL={isRTL} size={32} />
							) : null}
						</div>
					</div>
				)}
				<div className="mt-3 flex items-center justify-between gap-2">
					{opportunityNav}
				</div>
				{selectedRestaurantId ? (
					<Button asChild variant="primary" className="mt-3 w-full text-mint-500">
						<Link
							to="/merchant/$type/$id"
							params={{ type: "restaurant", id: selectedRestaurantId }}
							search={{
								...(restaurantName ? { name: restaurantName } : {}),
								...(imageUrl ? { image: imageUrl } : {}),
							}}
							data-testid="intelligence-map-compare"
							onClick={() => openMenu()}
						>
							{isRTL ? "قارن الآن ←" : "Compare now →"}
						</Link>
					</Button>
				) : (
					<Button
						type="button"
						variant="primary"
						className="mt-3 w-full text-mint-500"
						disabled
						data-testid="intelligence-map-compare"
					>
						{isRTL ? "قارن الآن ←" : "Compare now →"}
					</Button>
				)}
			</div>
		);
	}

	const [sheetSnap, setSheetSnap] = useState<"peek" | "expanded">("peek");
	const dragRef = useRef<{
		pointerId: number;
		startY: number;
		lastY: number;
	} | null>(null);
	const placeKey = placeDetail?.place_id || feature?.place_id || "";

	useEffect(() => {
		setSheetSnap("peek");
	}, [placeKey]);

	const onHandlePointerDown = (ev: ReactPointerEvent<HTMLDivElement>) => {
		if (variant !== "sheet") return;
		ev.currentTarget.setPointerCapture(ev.pointerId);
		dragRef.current = {
			pointerId: ev.pointerId,
			startY: ev.clientY,
			lastY: ev.clientY,
		};
	};
	const onHandlePointerMove = (ev: ReactPointerEvent<HTMLDivElement>) => {
		if (!dragRef.current || dragRef.current.pointerId !== ev.pointerId) return;
		dragRef.current.lastY = ev.clientY;
	};
	const onHandlePointerUp = (ev: ReactPointerEvent<HTMLDivElement>) => {
		const drag = dragRef.current;
		dragRef.current = null;
		if (!drag || drag.pointerId !== ev.pointerId) return;
		const dy = ev.clientY - drag.startY;
		if (Math.abs(dy) < 12) {
			if (sheetSnap === "peek") setSheetSnap("expanded");
			return;
		}
		if (dy > 56 && sheetSnap === "peek") {
			onClose();
			return;
		}
		if (dy > 40 && sheetSnap === "expanded") {
			setSheetSnap("peek");
			return;
		}
		if (dy < -32) {
			setSheetSnap("expanded");
		}
	};

	return (
		<div
			className={
				variant === "sheet"
					? `farq-place-sheet farq-place-sheet--mobile ${
							sheetSnap === "expanded"
								? "farq-place-sheet--expanded"
								: "farq-place-sheet--peek"
						} pointer-events-auto flex w-full flex-col overflow-hidden rounded-t-[28px] bg-white shadow-[0_-16px_48px_rgba(4,52,52,0.22)]`
					: "farq-place-panel flex h-full w-full flex-col overflow-hidden bg-white"
			}
			data-sheet-snap={variant === "sheet" ? sheetSnap : undefined}
			data-testid={
				variant === "sheet"
					? "intelligence-map-place-sheet"
					: "intelligence-map-place-panel"
			}
		>
			{variant === "sheet" ? (
				<div
					className="farq-place-sheet-handle flex shrink-0 cursor-grab justify-center pt-2 touch-none"
					data-testid="intelligence-map-place-handle"
					onPointerDown={onHandlePointerDown}
					onPointerMove={onHandlePointerMove}
					onPointerUp={onHandlePointerUp}
					onPointerCancel={onHandlePointerUp}
					role="slider"
					aria-valuetext={sheetSnap}
					aria-label={isRTL ? "سحب البطاقة" : "Drag sheet"}
				>
					<span className="h-1.5 w-12 rounded-full bg-[#d7e2e2]" />
				</div>
			) : null}

			{variant === "sheet" ? (
				<div
					className="farq-place-sheet-peekbar flex min-h-11 shrink-0 items-center justify-between gap-2 px-4 pb-2 touch-none"
					data-testid="intelligence-map-place-peek"
					onPointerDown={onHandlePointerDown}
					onPointerMove={onHandlePointerMove}
					onPointerUp={onHandlePointerUp}
					onPointerCancel={onHandlePointerUp}
				>
					<div className="min-w-0">
						<p className="truncate text-[14px] font-extrabold text-brand-900">
							{restaurantName}
						</p>
						{hasGap ? (
							<p className="text-[12px] font-black text-brand-900">
								+
								{localizeDigitString(String(Math.round(gapAmount)), isRTL)}{" "}
								{isRTL ? "ر.س" : "SAR"}
							</p>
						) : null}
					</div>
					{opportunityCount &&
					opportunityCount > 1 &&
					opportunityIndex != null &&
					opportunityIndex >= 0 ? (
						<div className="flex shrink-0 items-center">
							<button
								type="button"
								className="inline-flex size-11 items-center justify-center text-brand-900 disabled:opacity-30"
								aria-label={isRTL ? "السابق" : "Previous"}
								disabled={opportunityIndex <= 0}
								onClick={(e) => {
									e.stopPropagation();
									onPrevOpportunity?.();
								}}
							>
								{isRTL ? (
									<ChevronRight className="size-4" />
								) : (
									<ChevronLeft className="size-4" />
								)}
							</button>
							<span
								className="min-w-10 text-center text-[12px] font-bold text-brand-900"
								data-testid="intelligence-map-opportunity-index"
							>
								{localizeDigitString(String(opportunityIndex + 1), isRTL)}{" "}
								{isRTL ? "من" : "of"}{" "}
								{localizeDigitString(String(opportunityCount), isRTL)}
							</span>
							<button
								type="button"
								className="inline-flex size-11 items-center justify-center text-brand-900 disabled:opacity-30"
								aria-label={isRTL ? "التالي" : "Next"}
								disabled={opportunityIndex >= opportunityCount - 1}
								onClick={(e) => {
									e.stopPropagation();
									onNextOpportunity?.();
								}}
							>
								{isRTL ? (
									<ChevronLeft className="size-4" />
								) : (
									<ChevronRight className="size-4" />
								)}
							</button>
						</div>
					) : null}
				</div>
			) : null}

			<div
				className="farq-place-sheet-detail relative min-h-0 flex-1 overflow-y-auto"
				data-testid="intelligence-map-place"
			>
				{imageUrl ? (
					<div
						className="relative h-[148px] overflow-hidden bg-brand-900"
						data-testid="intelligence-map-place-cover"
					>
						<img
							src={imageUrl}
							alt=""
							className="absolute inset-0 size-full object-cover"
						/>
						<div className="absolute inset-0 bg-gradient-to-t from-brand-900/55 to-brand-900/10" />
						<div className="absolute start-4 top-4 flex items-center gap-1.5">
							{hideButton}
							<button
								type="button"
								className="farq-place-hit flex size-9 items-center justify-center rounded-2xl bg-white text-brand-900 shadow-sm"
								aria-label={isRTL ? "إغلاق" : "Close"}
								onClick={onClose}
							>
								<X className="size-3.5" />
							</button>
						</div>
					</div>
				) : (
					<div className="flex items-center justify-between px-5 pb-1 pt-4">
						<p className="text-[11px] font-bold uppercase tracking-wide text-[#6b7c7c]">
							{isRTL ? "فرق مرصود" : "Observed فرق"}
						</p>
						<div className="flex items-center gap-1">
							{hideButton}
							<button
								type="button"
								className="farq-place-hit flex size-8 items-center justify-center rounded-2xl bg-[#e6eef0] text-brand-900"
								aria-label={isRTL ? "إغلاق" : "Close"}
								onClick={onClose}
							>
								<X className="size-3.5" />
							</button>
						</div>
					</div>
				)}

				<div className="flex flex-col gap-5 p-5">
					{hasGap || difference ? (
						<div className="flex flex-col gap-4 rounded-[22px] bg-brand-900 p-5 text-white shadow-[0_16px_28px_rgba(4,52,52,0.28)]">
							<div className="flex flex-col items-center gap-2">
								<p className="text-[12px] font-bold text-mint-500">
									{isRTL ? "فلوسك تضيع هنا" : "Your money leaks here"}
								</p>
								{hasGap ? (
									<GapCountBadge amount={gapAmount} isRTL={isRTL} />
								) : (
									<span className="rounded-[10px] bg-mint-500 px-3 py-1.5 text-[32px] font-black leading-none text-brand-900">
										—
									</span>
								)}
								<p className="text-center text-[13px] text-white/70">
									{hasGap
										? isRTL
											? `لو طلبت هذا من المزوّد الغلط تدفع ${localizeDigitString(String(Math.round(gapAmount)), true)} ر.س زيادة`
											: `If you order from the wrong provider you pay ${Math.round(gapAmount)} SAR extra`
										: isRTL
											? "ما رصدنا فرق يستحق هنا بعد"
											: "No worthwhile gap observed here yet"}
								</p>
							</div>

							<div className="h-px w-full bg-white/15" />

							<div>
								<p className="text-[12px] font-bold text-mint-500">
									{isRTL ? "الوجبة المقارنة" : "Compared meal"}
								</p>
								<p className="mt-1 text-[18px] font-extrabold leading-snug">
									{mealName || (isRTL ? "طلب مرصود" : "Observed order")}
								</p>
							</div>

							{hasPrices || cheapProvider || expensiveProvider ? (
								<div className="flex flex-col gap-3" data-testid="intelligence-map-place-apps">
									<p className="text-[12px] font-bold text-mint-500">
										{isRTL ? "الأرخص مقابل الأغلى" : "Cheapest vs expensive"}
									</p>
									<div className="grid grid-cols-2 gap-2">
										<div className="rounded-2xl bg-white/8 px-3 py-3">
											<div className="flex items-center gap-2">
												<AppMark
													provider={cheapProvider}
													isRTL={isRTL}
													size={28}
												/>
												<div className="min-w-0">
													<p className="text-[10px] font-bold text-mint-500">
														{isRTL ? "أرخص تطبيق" : "Cheapest app"}
													</p>
													{hasPrices ? (
														<p className="text-[15px] font-black text-mint-500">
															{localizeDigitString(String(cheap), isRTL)}{" "}
															{isRTL ? "ر.س" : "SAR"}
														</p>
													) : null}
												</div>
											</div>
										</div>
										<div className="rounded-2xl bg-white/8 px-3 py-3">
											<div className="flex items-center gap-2">
												{expensiveProvider ? (
													<AppMark
														provider={expensiveProvider}
														isRTL={isRTL}
														size={28}
													/>
												) : null}
												<div className="min-w-0">
													<p className="text-[10px] font-bold text-[#ff8a8a]">
														{expensiveProvider
															? isRTL
																? "أغلى تطبيق"
																: "Expensive app"
															: isRTL
																? "أعلى سعر مرصود"
																: "Highest observed price"}
													</p>
													{hasPrices ? (
														<p className="text-[15px] font-black text-[#ff6b6b]">
															{localizeDigitString(String(expensive), isRTL)}{" "}
															{isRTL ? "ر.س" : "SAR"}
														</p>
													) : null}
												</div>
											</div>
										</div>
									</div>
									{hasPrices ? (
										<div
											className="flex flex-col gap-2"
											data-testid="intelligence-map-savings-bar"
											dir="ltr"
										>
											<div className="flex h-2.5 overflow-hidden rounded-full bg-[#0b2d2d]">
												<div
													className="h-full bg-mint-500"
													style={{ width: `${cheapPct}%` }}
												/>
												<div className="h-full flex-1 bg-[#e85d5d]" />
											</div>
										</div>
									) : null}
								</div>
							) : null}
						</div>
					) : (
						<div
							className="rounded-2xl bg-[#e6eef0] p-4"
							data-testid="intelligence-map-place-caution"
						>
							<p className="font-bold text-brand-900">
								{isRTL
									? "ما رصدنا فرقاً بعد"
									: "No observed price gap for this place yet."}
							</p>
						</div>
					)}

					<div className="flex flex-col gap-1.5">
						{categoryLabel ? (
							<span className="w-fit rounded-md bg-[#e6eef0] px-2 py-1 text-[10px] font-bold text-brand-900">
								{categoryLabel}
							</span>
						) : null}
						<h2 className="text-[20px] font-extrabold leading-tight text-brand-900">
							{restaurantName}
						</h2>
						{restaurantNameEn && restaurantNameEn !== restaurantName ? (
							<p className="text-[12px] text-[#6b7c7c]">{restaurantNameEn}</p>
						) : null}
						{placeDetail?.city ? (
							<p className="flex items-center gap-1 text-[12px] text-[#6b7c7c]">
								<MapPin className="size-3 text-red-500" />
								{placeDetail.city}
							</p>
						) : null}
					</div>
				</div>
			</div>

			<div className="farq-place-sheet-cta shrink-0 border-t border-[#e6eef0] bg-[#f9fafb] p-4">
				{fresh ? (
					<p
						className="mb-3 flex items-center justify-center gap-1.5 text-[11px] text-[#6b7c7c]"
						data-testid="intelligence-map-freshness"
					>
						<span
							className={`size-1.5 rounded-full ${
								fresh.kind === "today"
									? "bg-mint-500"
									: fresh.kind === "week"
										? "bg-[#ff8a00]"
										: "bg-[#6b7c7c]"
							}`}
							aria-hidden
						/>
						{fresh.label}
					</p>
				) : null}
				{selectedRestaurantId ? (
					<Button asChild variant="primary" className="w-full text-mint-500">
						<Link
							to="/merchant/$type/$id"
							params={{ type: "restaurant", id: selectedRestaurantId }}
							search={{
								...(restaurantName ? { name: restaurantName } : {}),
								...(imageUrl ? { image: imageUrl } : {}),
							}}
							data-testid="intelligence-map-compare"
							onClick={() => openMenu()}
						>
							{isRTL ? "قارن الآن ←" : "Compare now →"}
						</Link>
					</Button>
				) : (
					<Button
						type="button"
						variant="primary"
						className="w-full text-mint-500"
						disabled
						data-testid="intelligence-map-compare"
					>
					{isRTL ? "قارن الآن ←" : "Compare now →"}
					</Button>
				)}
				<p className="mt-2 text-center text-[11px] text-[#6b7c7c]">
					{selectedRestaurantId
						? isRTL
							? "يفتح قائمة فرق الحقيقية لهذا المطعم — نفس بطاقة الصفحة الرئيسية."
							: "Opens this restaurant’s real Farq menu — same route as a home card."
						: isRTL
							? "ما عندنا معرف قائمة بعد — بدون سكّ place_id."
							: "No menu id yet — we never remint place_id."}
				</p>
			</div>
		</div>
	);
}
