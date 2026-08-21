/**
 * How far apart are two colours to an eye, rather than to a byte?
 *
 * RGB distance is meaningless for this question — two greens can be numerically
 * far apart and look identical, while a blue and a purple can be numerically
 * close and read as different colours. CIE Lab is built so that a fixed
 * distance means roughly the same perceived difference anywhere in the space,
 * which is what "can a person tell these two districts apart" actually needs.
 *
 * ΔE is that distance. Rough calibration: below 2 is invisible to anyone, 2–10
 * is a difference you would notice only side by side, and above 15 reads as two
 * different colours at a glance — which is the bar for a map you scan rather
 * than study.
 */

export type Rgb = [number, number, number];
export type Lab = [number, number, number];

export function hexToRgb(hex: string): Rgb {
	const value = hex.replace("#", "");
	const full = value.length === 3
		? value.split("").map((c) => c + c).join("")
		: value;
	return [
		parseInt(full.slice(0, 2), 16),
		parseInt(full.slice(2, 4), 16),
		parseInt(full.slice(4, 6), 16),
	];
}

/** Undo the display gamma before doing any arithmetic on light. */
function toLinear(channel: number): number {
	const v = channel / 255;
	return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

export function rgbToLab([r, g, b]: Rgb): Lab {
	const R = toLinear(r);
	const G = toLinear(g);
	const B = toLinear(b);
	/* D65 white point. */
	const x = (R * 0.4124 + G * 0.3576 + B * 0.1805) / 0.95047;
	const y = R * 0.2126 + G * 0.7152 + B * 0.0722;
	const z = (R * 0.0193 + G * 0.1192 + B * 0.9505) / 1.08883;
	const f = (t: number) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
	return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}

export function deltaE(a: string, b: string): number {
	const [l1, a1, b1] = rgbToLab(hexToRgb(a));
	const [l2, a2, b2] = rgbToLab(hexToRgb(b));
	return Math.hypot(l1 - l2, a1 - a2, b1 - b2);
}

/**
 * What a colour actually looks like once it is painted as a district fill.
 *
 * The fill is translucent, so the question is never "how different are these two
 * colours" but "how different are they after both have been washed toward the
 * basemap". Sampled from the live map, the unpainted ground is around #fcfcfc
 * with patches near #eaf0f0; the separation between two fills barely moves
 * between those, because both get washed by the same amount.
 */
export const BASEMAP_GROUND = "#fcfcfc";

export function asFill(hex: string, alpha: number, ground = BASEMAP_GROUND): string {
	const c = hexToRgb(hex);
	const g = hexToRgb(ground);
	const mixed = c.map((v, i) => Math.round(v * alpha + g[i] * (1 - alpha)));
	return `#${mixed.map((v) => Math.max(0, Math.min(255, v)).toString(16).padStart(2, "0")).join("")}`;
}
