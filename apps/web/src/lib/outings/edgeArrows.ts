/**
 * Where to put a small arrow chip for someone who is off screen.
 *
 * Pure screen geometry: the caller projects each member to screen pixels and
 * passes the part of the screen that is really map (minus the top bar, the
 * bottom sheet and side panels). A member outside that area gets a chip on
 * its edge, on the line from the area's centre towards them, rotated to point
 * at them. The chip only says where the last real fix is; it never moves it.
 */

export type Insets = { top: number; right: number; bottom: number; left: number };
export type Size = { w: number; h: number };
export type Edge = "top" | "right" | "bottom" | "left";

export type EdgeSpot = {
	/** Chip centre, screen px. */
	x: number;
	y: number;
	/** Direction to the member, degrees clockwise from screen-up. */
	angle: number;
	edge: Edge;
};

/** Gap between the chip and the edge of the map area. */
export const EDGE_MARGIN = 6;

/** The visible map area after insets (never inverted). */
export function safeRect(view: Size, insets: Insets) {
	const left = Math.max(0, insets.left);
	const top = Math.max(0, insets.top);
	const right = Math.max(left + 1, view.w - Math.max(0, insets.right));
	const bottom = Math.max(top + 1, view.h - Math.max(0, insets.bottom));
	return { left, top, right, bottom };
}

/** Clockwise-from-up angle of a screen vector (y grows downward). */
export function screenAngle(dx: number, dy: number): number {
	return ((Math.atan2(dx, -dy) * 180) / Math.PI + 360) % 360;
}

/**
 * null when the point is inside the map area (its car is visible); otherwise
 * the chip's spot on the area's edge, kept fully inside the area.
 */
export function edgeSpot(p: { x: number; y: number }, view: Size, insets: Insets, chip: Size): EdgeSpot | null {
	if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) return null;
	const r = safeRect(view, insets);
	if (p.x >= r.left && p.x <= r.right && p.y >= r.top && p.y <= r.bottom) return null;
	const cx = (r.left + r.right) / 2;
	const cy = (r.top + r.bottom) / 2;
	const dx = p.x - cx;
	const dy = p.y - cy;
	/* Room for the chip's centre. */
	const hx = Math.max(0, (r.right - r.left) / 2 - chip.w / 2 - EDGE_MARGIN);
	const hy = Math.max(0, (r.bottom - r.top) / 2 - chip.h / 2 - EDGE_MARGIN);
	const tx = dx === 0 ? Infinity : hx / Math.abs(dx);
	const ty = dy === 0 ? Infinity : hy / Math.abs(dy);
	const t = Math.min(tx, ty);
	const edge: Edge = tx <= ty ? (dx > 0 ? "right" : "left") : dy > 0 ? "bottom" : "top";
	return { x: cx + dx * t, y: cy + dy * t, angle: screenAngle(dx, dy), edge };
}

/**
 * Chips on the same edge must not cover each other: walk them along the edge
 * and push each one past the previous, then back inside if the last overflows.
 */
export function spreadOnEdges<T extends EdgeSpot>(spots: T[], view: Size, insets: Insets, chip: Size, gap = 4): T[] {
	const r = safeRect(view, insets);
	const out = spots.map((s) => ({ ...s }));
	for (const edge of ["top", "right", "bottom", "left"] as Edge[]) {
		const vertical = edge === "left" || edge === "right";
		const step = (vertical ? chip.h : chip.w) + gap;
		const lo = (vertical ? r.top + chip.h / 2 : r.left + chip.w / 2) + EDGE_MARGIN;
		const hi = (vertical ? r.bottom - chip.h / 2 : r.right - chip.w / 2) - EDGE_MARGIN;
		const group = out.filter((s) => s.edge === edge).sort((a, b) => (vertical ? a.y - b.y : a.x - b.x));
		const key = vertical ? "y" : "x";
		for (let i = 1; i < group.length; i += 1) {
			if (group[i][key] < group[i - 1][key] + step) group[i][key] = group[i - 1][key] + step;
		}
		const last = group[group.length - 1];
		if (last && last[key] > hi) {
			const shift = last[key] - hi;
			for (const s of group) s[key] -= shift;
		}
		/* If they still do not fit, keep them inside; overlap beats falling off screen. */
		for (const s of group) s[key] = Math.min(hi, Math.max(lo, s[key]));
	}
	return out;
}
