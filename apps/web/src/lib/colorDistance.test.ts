import { describe, expect, it } from "vitest";
import { BASEMAP_GROUND, asFill, deltaE, rgbToLab } from "./colorDistance";
import { PROVIDER_MAP_COLOR, PROVIDER_MAP_COLOR_TOO_CLOSE } from "./platformLogos";

/**
 * The app lens does not paint at one opacity — it paints at whichever step the
 * winning app's margin lands on, so the weakest step is the one that has to be
 * legible. That is the number these tests use.
 */
import { APP_MARGIN_STEPS, APP_TOO_CLOSE_OPACITY } from "./farqDistrictTiles";
const FILL_ALPHA = APP_MARGIN_STEPS[0].opacity;

/**
 * How many أحياء each app actually wins, measured on production: 109 of
 * Riyadh's 187 districts carry a verdict, and only these six ever win one.
 * Three of them colour 89% of the city.
 */
const DISTRICTS_WON: Record<string, number> = {
	jahez: 46,
	mrsool: 36,
	hungerstation: 15,
	thechefz: 6,
	ninja: 3,
	toyou: 3,
};
const DOMINANT = ["jahez", "mrsool", "hungerstation"];

const painted = (key: string) => asFill(PROVIDER_MAP_COLOR[key], FILL_ALPHA);
const pairs = <T>(list: T[]) =>
	list.flatMap((a, i) => list.slice(i + 1).map((b) => [a, b] as const));

describe("ΔE measures difference the way an eye does", () => {
	it("calls a colour identical to itself zero", () => {
		expect(deltaE("#e8382a", "#e8382a")).toBe(0);
	});

	it("separates black and white by the full lightness range", () => {
		expect(deltaE("#000000", "#ffffff")).toBeCloseTo(100, 0);
	});

	it("accepts short hex", () => {
		expect(deltaE("#fff", "#ffffff")).toBe(0);
	});

	it("puts two greens closer than a green and a blue, unlike RGB distance", () => {
		expect(deltaE("#00a89c", "#0f9b7a")).toBeLessThan(deltaE("#00a89c", "#1f52c8"));
	});

	it("washes a colour toward the basemap the way a translucent fill does", () => {
		const [lightness] = rgbToLab([0, 0, 0]);
		expect(lightness).toBe(0);
		/* A 34% fill of black over near-white is a mid grey, not black. */
		const grey = asFill("#000000", FILL_ALPHA);
		expect(deltaE(grey, "#000000")).toBeGreaterThan(40);
		expect(deltaE(grey, BASEMAP_GROUND)).toBeGreaterThan(25);
	});
});

describe("the district lens stays readable", () => {
	it("makes the three apps that colour 89% of the city unmistakable", () => {
		/* Jahez, Mrsool and HungerStation win 97 of the 109 decided أحياء. If any
		 * two of them look alike the map's main claim is unreadable. */
		for (const [a, b] of pairs(DOMINANT)) {
			expect(deltaE(painted(a), painted(b)),
				`${a} and ${b} colour most of the city and must not look alike`)
				.toBeGreaterThan(30);
		}
	});

	it("keeps every app that ever wins a حي clearly apart from the others", () => {
		for (const [a, b] of pairs(Object.keys(DISTRICTS_WON))) {
			expect(deltaE(painted(a), painted(b)), `${a} ↔ ${b}`).toBeGreaterThan(15);
		}
	});

	it("never lets a painted حي read as empty ground", () => {
		/* The failure this exists to prevent: Ninja was once a pale slate that
		 * measured ΔE 3.3 from unpainted ground — a district it had won looked
		 * exactly like a district with no data. */
		for (const key of Object.keys(DISTRICTS_WON)) {
			expect(deltaE(painted(key), BASEMAP_GROUND), `${key} against empty ground`)
				.toBeGreaterThan(15);
		}
	});

	it("keeps «too close to call» distinct from every app that could have won", () => {
		/* A tie is painted at its own, fainter opacity — that is the point of it. */
		const tooClose = asFill(PROVIDER_MAP_COLOR_TOO_CLOSE, APP_TOO_CLOSE_OPACITY);
		for (const key of Object.keys(DISTRICTS_WON)) {
			expect(deltaE(tooClose, painted(key)), `a tie must not look like ${key} winning`)
				.toBeGreaterThan(12);
		}
	});

	it("draws a tie as something, not as nothing", () => {
		/* «متقارب — لا فائز واضح» and «مقارنات غير كافية» are two different answers
		 * in the legend. At the old 0.14 they measured ΔE 4.6 apart on the map,
		 * which is to say the map could not tell them apart at all. */
		const tooClose = asFill(PROVIDER_MAP_COLOR_TOO_CLOSE, APP_TOO_CLOSE_OPACITY);
		expect(deltaE(tooClose, BASEMAP_GROUND)).toBeGreaterThan(7);
	});

	it("keeps confidence legible: a decisive win is drawn stronger than a narrow one", () => {
		const [narrow, mid, decisive] = APP_MARGIN_STEPS.map((s) => s.opacity);
		expect(narrow).toBeLessThan(mid);
		expect(mid).toBeLessThan(decisive);
		/* And the faintest step must still be readable on its own. */
		expect(deltaE(asFill(PROVIDER_MAP_COLOR.jahez, narrow), BASEMAP_GROUND))
			.toBeGreaterThan(15);
	});

	it("gives every app that can win a حي a colour at all", () => {
		for (const key of Object.keys(DISTRICTS_WON)) {
			expect(PROVIDER_MAP_COLOR[key], `${key} has no colour`).toMatch(/^#[0-9a-f]{6}$/i);
		}
	});
});

describe("apps that never win a حي", () => {
	it("are still given a colour, for chips and legends elsewhere", () => {
		for (const key of ["keeta", "brand_app", "mrmandoob"]) {
			expect(PROVIDER_MAP_COLOR[key]).toMatch(/^#[0-9a-f]{6}$/i);
		}
	});

	it("are deliberately not held to the separation the map needs", () => {
		/* keeta's yellow sits close to HungerStation's by design: it has never won
		 * a حي, so holding it to the map's separation budget would cost brand
		 * fidelity to solve a collision that cannot happen. If keeta starts
		 * winning districts, this test is the place that has to change. */
		expect(DISTRICTS_WON.keeta).toBeUndefined();
	});
});
