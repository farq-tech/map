/**
 * Official Farq mark — circular «ف» from farq-wordmark-mint.svg,
 * plus the same wordmark file for the lockup (never a CSS-fake ف / فرق).
 */
import {
	FARQ_BRAND_900,
	FARQ_FAA_PATH,
	FARQ_FAA_TRANSFORM,
	FARQ_MINT,
	FARQ_WORDMARK_SRC,
} from "../lib/farqBrandAssets";

type Variant = "circle" | "lockup" | "wordmark";

export default function FarqBrandMark({
	variant = "circle",
	size = 29,
	className = "",
	wordmarkClassName = "h-[18px] w-auto",
	title = "فرق",
}: {
	variant?: Variant;
	size?: number;
	className?: string;
	wordmarkClassName?: string;
	title?: string;
}) {
	if (variant === "wordmark") {
		return (
			<span
				className={`inline-flex shrink-0 items-center justify-center rounded-full bg-brand-900 px-5 py-2.5 ${className}`.trim()}
				data-testid="farq-brand-mark"
				aria-label={title}
			>
				<img
					src={FARQ_WORDMARK_SRC}
					alt=""
					width={96}
					height={28}
					className="h-7 w-auto"
					draggable={false}
				/>
			</span>
		);
	}

	return (
		<span
			className={`inline-flex shrink-0 items-center gap-1.5 ${className}`.trim()}
			data-testid="farq-brand-mark"
			aria-label={title}
		>
			<svg
				xmlns="http://www.w3.org/2000/svg"
				width={size}
				height={size}
				viewBox="0 0 32 32"
				className="farq-brand-mark shrink-0"
				aria-hidden
				focusable="false"
			>
				<circle cx="16" cy="16" r="16" fill={FARQ_BRAND_900} />
				<g transform={FARQ_FAA_TRANSFORM}>
					<path fill={FARQ_MINT} d={FARQ_FAA_PATH} />
				</g>
			</svg>
			{variant === "lockup" ? (
				<img
					src={FARQ_WORDMARK_SRC}
					alt=""
					width={84}
					height={18}
					className={wordmarkClassName}
					draggable={false}
				/>
			) : null}
		</span>
	);
}
