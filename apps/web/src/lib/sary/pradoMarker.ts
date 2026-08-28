/**
 * Active-trip vehicle — the rendered Prado assets, not a generic blue dot.
 *
 * idle     → front 3/4 on sand (stationary)
 * moving   → rear 3/4 with dust (recording and actually moving)
 * far zoom → 64px isometric marker so the car does not cover the land
 *
 * Heading is applied only when the device reported one. Each sprite has a
 * different nose direction in the PNG; we subtract that offset so 0° is north.
 */

export const PRADO_MARKER_CLASS = "sary-prado";

export type PradoMotion = "idle" | "moving";

export type PradoPose = "idle" | "moving" | "marker";

export const PRADO_ASSETS: Record<PradoPose, string> = {
	idle: "/sary/prado-stationary-idle.png",
	moving: "/sary/prado-moving-active.png",
	marker: "/sary/prado-map-marker-64.png",
};

/** Degrees clockwise from image-up to the vehicle nose in that PNG. */
export const PRADO_NOSE_OFFSET: Record<PradoPose, number> = {
	idle: 250,
	moving: 315,
	marker: 225,
};

export function pickPradoPose(opts: {
	simplified: boolean;
	motion: PradoMotion;
}): PradoPose {
	if (opts.simplified) return "marker";
	return opts.motion === "moving" ? "moving" : "idle";
}

export function pradoHeadingRotate(heading: number | null, pose: PradoPose): string {
	if (heading == null || !Number.isFinite(heading)) return "";
	return `rotate(${heading - PRADO_NOSE_OFFSET[pose]}deg)`;
}

export function buildPradoMarker(): HTMLElement {
	const root = document.createElement("div");
	root.className = PRADO_MARKER_CLASS;
	root.dataset.testid = "sary-prado";
	root.dataset.pose = "idle";

	const body = document.createElement("div");
	body.className = "sary-prado-body";
	body.setAttribute("aria-hidden", "true");

	const img = document.createElement("img");
	img.className = "sary-prado-img";
	img.alt = "";
	img.draggable = false;
	img.src = PRADO_ASSETS.idle;

	body.append(img);
	root.append(body);
	return root;
}

export function updatePradoMarker(
	root: HTMLElement,
	opts: {
		heading: number | null;
		simplified: boolean;
		motion?: PradoMotion;
	},
) {
	const pose = pickPradoPose({
		simplified: opts.simplified,
		motion: opts.motion ?? "idle",
	});
	root.classList.toggle("is-simplified", pose === "marker");
	root.classList.toggle("is-moving", pose === "moving");
	root.dataset.pose = pose;
	root.dataset.testid = "sary-prado";

	const img = root.querySelector<HTMLImageElement>(".sary-prado-img");
	if (img && img.getAttribute("src") !== PRADO_ASSETS[pose]) {
		img.src = PRADO_ASSETS[pose];
	}

	const body = root.querySelector<HTMLElement>(".sary-prado-body");
	if (!body) return;
	body.style.transform = pradoHeadingRotate(opts.heading, pose);
}
