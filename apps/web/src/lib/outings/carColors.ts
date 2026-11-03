/**
 * Every participant drives a different colour, and everyone sees the same
 * colour for the same person: the colour comes from join order, which the
 * server gives every device identically.
 */

/** Distinct on satellite imagery and from each other; no two neighbours alike. */
export const OUTING_CAR_COLORS = [
	"#e8eef0", // white
	"#d6452f", // red
	"#2f6fd6", // blue
	"#f2b630", // yellow
	"#2fa56a", // green
	"#8a4fd1", // purple
	"#f07f2f", // orange
	"#1fb8c4", // teal
	"#e05a9c", // pink
	"#15191c", // black
	"#9aa5ad", // silver
	"#7a5230", // brown
] as const;

export function memberColors(members: Array<{ user_id: string; joined_at: string }>): Map<string, string> {
	const order = [...members].sort((a, b) => a.joined_at.localeCompare(b.joined_at) || a.user_id.localeCompare(b.user_id));
	return new Map(order.map((m, i) => [m.user_id, OUTING_CAR_COLORS[i % OUTING_CAR_COLORS.length]]));
}
