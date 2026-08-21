/**
 * What the city zoom is answering, said on the map itself.
 *
 * The two lenses read the same server numbers — how many observed
 * opportunities a حي holds, or which app was cheapest there. The second is the
 * thing no competitor can say, and it used to live behind an unlabelled ⓘ in a
 * corner: you had to find a hidden button before the product's second idea
 * existed. A switch that changes what the whole screen means belongs on the
 * screen.
 */
import type { DistrictLens } from "../../lib/farqDistrictTiles";

export default function FarqLensSwitch({
	lens,
	onChange,
	isRTL,
	disabled = false,
	className = "",
}: {
	lens: DistrictLens;
	onChange: (lens: DistrictLens) => void;
	isRTL: boolean;
	/** No boundaries for this city — the lens has nothing to paint. */
	disabled?: boolean;
	className?: string;
}) {
	if (disabled) return null;
	return (
		<div
			className={`farq-lens-switch ${className}`.trim()}
			role="group"
			aria-label={isRTL ? "لون الحي يعني" : "District colour means"}
			data-testid="farq-lens-switch"
		>
			{(
				[
					["gap", isRTL ? "الفرص" : "Opportunities"],
					["app", isRTL ? "التطبيق الأرخص" : "Cheapest app"],
				] as const
			).map(([id, label]) => (
				<button
					key={id}
					type="button"
					aria-pressed={lens === id}
					className={lens === id ? "is-on" : ""}
					data-testid={`intelligence-map-lens-${id}`}
					onClick={() => onChange(id)}
				>
					{label}
				</button>
			))}
		</div>
	);
}
