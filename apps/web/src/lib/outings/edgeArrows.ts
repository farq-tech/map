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

export type Rect = { left: number; top: number; right: number; bottom: number };

function overlaps(a: Rect, b: Rect): boolean {
	return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
}

function chipRect(s: { x: number; y: number }, chip: Size): Rect {
	return { left: s.x - chip.w / 2, top: s.y - chip.h / 2, right: s.x + chip.w / 2, bottom: s.y + chip.h / 2 };
}

/**
 * A chip must never cover something that has to stay readable — above all my
 * own car's «أنت» name chip, which can sit right at the edge of the map area.
 * Slide each chip that would cover `keepClear` along its own edge, to the
 * nearer side that still fits; chips it would then land on are pushed on in
 * the same direction. If neither side fits, it stays where it was.
 */
export function avoidRect<T extends EdgeSpot>(spots: T[], keepClear: Rect | null, view: Size, insets: Insets, chip: Size, gap = 4): T[] {
	if (!keepClear) return spots;
	const r = safeRect(view, insets);
	const out = spots.map((s) => ({ ...s }));
	const clear: Rect = { left: keepClear.left - gap, top: keepClear.top - gap, right: keepClear.right + gap, bottom: keepClear.bottom + gap };
	for (const s of out) {
		if (!overlaps(chipRect(s, chip), clear)) continue;
		const vertical = s.edge === "left" || s.edge === "right";
		const key = vertical ? "y" : "x";
		const half = vertical ? chip.h / 2 : chip.w / 2;
		const lo = (vertical ? r.top : r.left) + half + EDGE_MARGIN;
		const hi = (vertical ? r.bottom : r.right) - half - EDGE_MARGIN;
		const before = (vertical ? clear.top : clear.left) - half;
		const after = (vertical ? clear.bottom : clear.right) + half;
		const options = [before, after].filter((v) => v >= lo && v <= hi).sort((a, b) => Math.abs(a - s[key]) - Math.abs(b - s[key]));
		const step = (vertical ? chip.h : chip.w) + gap;
		/* Try the nearer side first; take it only if the neighbours it pushes still fit. */
		for (const target of options) {
			const dir = Math.sign(target - s[key]) || 1;
			/* Neighbours not clearly behind the new spot, nearest first in the direction of travel. */
			const ahead = out.filter((o) => o !== s && o.edge === s.edge && dir * (o[key] - target) > -step).sort((a, b) => dir * (a[key] - b[key]));
			const moves: Array<[T, number]> = [];
			let prev = target;
			let fits = true;
			for (const o of ahead) {
				const next = dir * Math.max(dir * o[key], dir * prev + step);
				if (next < lo || next > hi) {
					fits = false;
					break;
				}
				moves.push([o, next]);
				prev = next;
			}
			if (!fits) continue;
			s[key] = target;
			for (const [o, v] of moves) o[key] = v;
			break;
		}
	}
	return out;
}
