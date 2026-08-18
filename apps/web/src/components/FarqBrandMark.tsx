/**
 * Official Farq mark — circular «ف» from farq-wordmark-mint.svg,
 * plus the same wordmark file for the lockup (never a CSS-fake ف / فرق).
 */
import { FARQ_FAA_PATH, FARQ_WORDMARK_SRC } from "../lib/farqBrandAssets";

type Variant = "circle" | "lockup";

export default function FarqBrandMark({
	variant = "circle",
	size = 29,
	className = "",
	wordmarkClassName = "hidden h-[18px] w-[39px] text-brand-900 lg:inline-block",
	title = "فرق",
}: {
	variant?: Variant;
	size?: number;
	className?: string;
	wordmarkClassName?: string;
	title?: string;
}) {
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
				<circle cx="16" cy="16" r="16" className="fill-brand-900" />
				<g transform="translate(10.82 7.02) scale(0.1079)">
					<path fill="#83F1B1" d={FARQ_FAA_PATH} />
				</g>
			</svg>
			{variant === "lockup" ? (
				<span
					aria-hidden
					className={wordmarkClassName}
					style={{
						backgroundColor: "currentColor",
						WebkitMaskImage: `url(${FARQ_WORDMARK_SRC})`,
						maskImage: `url(${FARQ_WORDMARK_SRC})`,
						WebkitMaskRepeat: "no-repeat",
						maskRepeat: "no-repeat",
						WebkitMaskPosition: "center",
						maskPosition: "center",
						WebkitMaskSize: "contain",
						maskSize: "contain",
					}}
				/>
			) : null}
		</span>
	);
}
