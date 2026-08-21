/**
 * The Farq wordmark, as farq.sa draws it.
 *
 * Ported verbatim from the product's own `BrandWordmark` in farq-tech/farq
 * (Frontend/src/components/BrandWordmark.tsx): the word set in Futura 700 on a
 * 262×148 design canvas at 111.217px with −2.31703px tracking, then scaled to
 * the height the header needs. Same canvas, same font stack, same tracking, so
 * the map reads as the same product rather than a cousin of it.
 *
 * The only thing this adds is ink: farq.sa only ever puts the mark on a light
 * surface, and this map has a dark teal header too. Colour is the one property
 * a wordmark may change; the letterforms may not.
 */

const DESIGN_W = 262;
const DESIGN_H = 148;

/** farq.sa's own two sizes: 28px tall on a phone, 32px from `sm` up. */
export const WORDMARK_HEIGHT_SM = 28;
export const WORDMARK_HEIGHT_MD = 32;

/** The brand's dark teal, exactly as the production component states it. */
export const WORDMARK_INK = "#063B37";
/** For the dark header, where the production ink would be invisible. */
export const WORDMARK_INK_MINT = "#83F1B1";

export type WordmarkTone = "dark" | "mint";

export default function FarqWordmark({
	height = WORDMARK_HEIGHT_SM,
	tone = "dark",
	className = "",
	title = "فرق",
}: {
	height?: number;
	tone?: WordmarkTone;
	className?: string;
	title?: string;
}) {
	const scale = height / DESIGN_H;
	return (
		<span
			className={`relative inline-block shrink-0 overflow-visible ${className}`.trim()}
			style={{ width: DESIGN_W * scale, height: DESIGN_H * scale }}
			data-testid="farq-brand-mark"
			role="img"
			aria-label={title}
		>
			<span
				aria-hidden
				className="absolute left-0 top-0 block origin-top-left"
				style={{
					width: DESIGN_W,
					height: DESIGN_H,
					fontFamily:
						"'Futura', 'Futura PT', 'Century Gothic', 'Trebuchet MS', sans-serif",
					fontStyle: "normal",
					fontWeight: 700,
					fontSize: 111.217,
					lineHeight: "148px",
					textAlign: "center",
					letterSpacing: "-2.31703px",
					color: tone === "mint" ? WORDMARK_INK_MINT : WORDMARK_INK,
					transform: `scale(${scale})`,
					transformOrigin: "top left",
				}}
			>
				Farq
			</span>
		</span>
	);
}
