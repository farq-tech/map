/**
 * Premium selected-place moment on `/map`.
 * Photo only when the API returns image_url — never invent URLs.
 * App marks come from getProviderLogo / ProviderLogoMark (bundled assets).
 * CTA «افتح الأرخص» opens the real /merchant/restaurant/:id menu.
 */
import { Link } from "@tanstack/react-router";
import { MapPin, X } from "lucide-react";
import {
	useEffect,
	useRef,
	useState,
	type PointerEvent as ReactPointerEvent,
} from "react";
import { useCountUp } from "../../hooks/useCountUp";
import { localizeDigitString } from "../../lib/formatPrice";
import { getProviderLogo } from "../../lib/platformLogos";
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
	onOpenMenu,
}: {
	placeDetail: IntelligenceMapPlaceDetail | null;
	feature?: IntelligenceMapPlaceProperties | null;
	selectedCategory?: IntelligenceCategory | null;
	selectedRestaurantId?: string;
	isRTL: boolean;
	variant: "sheet" | "panel";
	onClose: () => void;
	onOpenMenu: (opts: {
		restaurantId: string;
		name?: string;
		image?: string | null;
	}) => void;
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
	const mealName = difference?.product_name || null;
	const gapAmount = Number(difference?.difference_amount);
	const hasGap = Number.isFinite(gapAmount) && gapAmount > 0;
	const cheap = Number(difference?.cheapest_price);
	const expensive = Number(difference?.expensive_price);
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
		if (dy > 72 && sheetSnap === "peek") {
			onClose();
			return;
		}
		if (dy > 48 && sheetSnap === "expanded") {
			setSheetSnap("peek");
			return;
		}
		if (dy < -40) {
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

			<div className="relative flex-1 overflow-y-auto" data-testid="intelligence-map-place">
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
						<button
							type="button"
							className="absolute start-4 top-4 flex size-9 items-center justify-center rounded-2xl bg-white text-brand-900 shadow-sm"
							aria-label={isRTL ? "إغلاق" : "Close"}
							onClick={onClose}
						>
							<X className="size-3.5" />
						</button>
					</div>
				) : (
					<div className="flex items-center justify-between px-5 pb-1 pt-4">
						<p className="text-[11px] font-bold uppercase tracking-wide text-[#6b7c7c]">
							{isRTL ? "فرق مرصود" : "Observed فرق"}
						</p>
						<button
							type="button"
							className="flex size-8 items-center justify-center rounded-2xl bg-[#e6eef0] text-brand-900"
							aria-label={isRTL ? "إغلاق" : "Close"}
							onClick={onClose}
						>
							<X className="size-3.5" />
						</button>
					</div>
				)}

				<div className="flex flex-col gap-5 p-5">
					{hasGap || difference ? (
						<div className="flex flex-col gap-4 rounded-[22px] bg-brand-900 p-5 text-white shadow-[0_16px_28px_rgba(4,52,52,0.28)]">
							<div className="flex flex-col items-center gap-2">
								<p className="text-[12px] font-bold text-mint-500">
									{isRTL ? "الفرق المرصود" : "Observed فرق"}
								</p>
								{hasGap ? (
									<GapCountBadge amount={gapAmount} isRTL={isRTL} />
								) : (
									<span className="rounded-[10px] bg-mint-500 px-3 py-1.5 text-[32px] font-black leading-none text-brand-900">
										—
									</span>
								)}
								<p className="text-center text-[13px] text-white/70">
									{isRTL
										? "الفارق الكلي في الطلب الأساسي"
										: "Total gap on the compared order"}
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

							{hasPrices ||
							difference?.cheapest_provider_id ||
							difference?.expensive_provider_id ? (
								<div className="flex flex-col gap-3" data-testid="intelligence-map-place-apps">
									<p className="text-[12px] font-bold text-mint-500">
										{isRTL ? "الأرخص مقابل الأغلى" : "Cheapest vs expensive"}
									</p>
									<div className="grid grid-cols-2 gap-2">
										<div className="rounded-2xl bg-white/8 px-3 py-3">
											<div className="flex items-center gap-2">
												<AppMark
													provider={difference?.cheapest_provider_id}
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
												<AppMark
													provider={difference?.expensive_provider_id}
													isRTL={isRTL}
													size={28}
												/>
												<div className="min-w-0">
													<p className="text-[10px] font-bold text-[#ff8a8a]">
														{isRTL ? "أغلى تطبيق" : "Expensive app"}
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

			<div className="shrink-0 border-t border-[#e6eef0] bg-[#f9fafb] p-4">
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
							{isRTL ? "افتح الأرخص" : "Open the cheapest"}
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
						{isRTL ? "افتح الأرخص" : "Open the cheapest"}
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
