import type { ReactNode } from "react";
import { useLanguage } from "../contexts/LanguageContext";
import { Button } from "./ui/Button";

interface ActionConfig {
	label: string;
	labelAr?: string;
	onClick: () => void;
}

interface SecondaryActionConfig extends ActionConfig {
	variant?: "outline";
}

interface Props {
	icon?: ReactNode;
	title: string;
	titleAr?: string;
	body?: string;
	bodyAr?: string;
	action?: ActionConfig;
	secondaryAction?: SecondaryActionConfig;
	illustration?: ReactNode;
	suggestions?: string[];
	onSuggestionClick?: (s: string) => void;
	/** Icon-circle tone (Farq state screens 16–18). */
	iconTone?: "default" | "brand" | "danger";
	/** Primary action styling: brand pill (default) or dark button (design darkbtn). */
	actionVariant?: "brand" | "dark";
}

const ICON_TONES: Record<NonNullable<Props["iconTone"]>, string> = {
	default: "bg-surface-2 text-ink-muted",
	brand: "bg-mint-50 text-brand-900",
	danger: "bg-red-50 text-red-600",
};

export default function EmptyState({
	icon,
	title,
	titleAr,
	body,
	bodyAr,
	action,
	secondaryAction,
	illustration,
	suggestions,
	onSuggestionClick,
	iconTone = "brand",
	actionVariant = "brand",
}: Props) {
	const { language } = useLanguage();
	const isRTL = language === "ar";

	const resolvedTitle = isRTL && titleAr ? titleAr : title;
	const resolvedBody = isRTL && bodyAr ? bodyAr : body;
	const resolvedAction = action
		? {
				...action,
				label: isRTL && action.labelAr ? action.labelAr : action.label,
			}
		: null;
	const resolvedSecondaryAction = secondaryAction
		? {
				...secondaryAction,
				label:
					isRTL && secondaryAction.labelAr
						? secondaryAction.labelAr
						: secondaryAction.label,
			}
		: null;

	return (
		<div
			role="status"
			dir={isRTL ? "rtl" : "ltr"}
			className="relative mx-auto flex max-w-[360px] flex-col items-center gap-3 overflow-hidden rounded-ds-2xl bg-mint-50/60 px-4 py-12 text-center dark:bg-mint-500/10"
		>
			<div
				aria-hidden="true"
				className="pointer-events-none absolute -end-10 -top-10 h-28 w-28 rounded-full bg-mint-500/25"
			/>
			{illustration ? (
				<div className="relative flex max-h-[120px] items-center justify-center">
					{illustration}
				</div>
			) : null}
			<div
				className={`relative flex h-16 w-16 items-center justify-center rounded-full ring-1 ring-mint-500/30 ${ICON_TONES[iconTone]}`}
			>
				{icon ?? (
					<span
						className={`text-[15px] font-black text-brand-900 ${isRTL ? "font-arabic" : ""}`}
						aria-hidden
					>
						{isRTL ? "فرق" : "F"}
					</span>
				)}
			</div>
			<h3
				className={`relative text-[16px] font-bold text-brand-900 dark:text-teal-200 ${isRTL ? "font-arabic" : ""}`}
			>
				{resolvedTitle}
			</h3>
			{resolvedBody ? (
				<p className="relative text-[13px] leading-[1.65] text-ink-muted">
					{resolvedBody}
				</p>
			) : null}
			{suggestions && suggestions.length > 0 ? (
				<div className="relative mt-1 flex flex-wrap justify-center gap-1.5">
					{suggestions.map((s) => (
						<button
							key={s}
							type="button"
							onClick={() => onSuggestionClick?.(s)}
							className="rounded-full border border-mint-500/30 bg-surface px-2.5 py-1 text-[13px] font-medium text-brand-900 transition-colors hover:bg-mint-50"
						>
							{s}
						</button>
					))}
				</div>
			) : null}
			{resolvedAction || resolvedSecondaryAction ? (
				<div className="relative mt-2 flex flex-wrap items-center justify-center gap-2">
					{resolvedAction ? (
						<Button
							variant="primary"
							size="sm"
							shape={actionVariant === "dark" ? "rounded" : "pill"}
							onClick={resolvedAction.onClick}
						>
							{resolvedAction.label}
						</Button>
					) : null}
					{resolvedSecondaryAction ? (
						<Button
							variant="secondary"
							size="sm"
							shape="pill"
							onClick={resolvedSecondaryAction.onClick}
						>
							{resolvedSecondaryAction.label}
						</Button>
					) : null}
				</div>
			) : null}
		</div>
	);
}
