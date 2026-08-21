/**
 * The circular «ف» — a map symbol, not the brand signature: it is what a Farq
 * pin wears and what the legend shows to explain that pin. The wordmark lives
 * in FarqWordmark.tsx, drawn the way farq.sa draws it, and there is only one.
 */
import {
	FARQ_BRAND_900,
	FARQ_FAA_PATH,
	FARQ_FAA_TRANSFORM,
	FARQ_MINT,
} from "../lib/farqBrandAssets";

export default function FarqBrandMark({
	size = 29,
	className = "",
	title = "فرق",
}: {
	size?: number;
	className?: string;
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
				<circle cx="16" cy="16" r="16" fill={FARQ_BRAND_900} />
				<g transform={FARQ_FAA_TRANSFORM}>
					<path fill={FARQ_MINT} d={FARQ_FAA_PATH} />
				</g>
			</svg>
		</span>
	);
}
