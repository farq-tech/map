import { describe, expect, it } from "vitest";
import { buildSuvGlb, buildSuvParts, hexToLinear } from "./suvModel";

describe("generated 4x4 model", () => {
	it("is a valid glTF 2.0 binary with JSON and BIN chunks", () => {
		const glb = buildSuvGlb("#1b2a4a");
		const dv = new DataView(glb);
		expect(dv.getUint32(0, true)).toBe(0x46546c67);
		expect(dv.getUint32(4, true)).toBe(2);
		expect(dv.getUint32(8, true)).toBe(glb.byteLength);
		const jsonLen = dv.getUint32(12, true);
		const json = JSON.parse(new TextDecoder().decode(new Uint8Array(glb, 20, jsonLen)));
		expect(json.asset.version).toBe("2.0");
		expect(json.meshes[0].primitives.length).toBeGreaterThanOrEqual(6);
		expect(dv.getUint32(20 + jsonLen + 4, true)).toBe(0x004e4942);
		expect(glb.byteLength).toBeLessThan(80_000);
	});

	it("has real-world proportions (metres) and sits on the ground", () => {
		const parts = buildSuvParts();
		const all = Object.values(parts).flatMap((p) => p.positions);
		const xs = all.filter((_, i) => i % 3 === 0);
		const ys = all.filter((_, i) => i % 3 === 1);
		const zs = all.filter((_, i) => i % 3 === 2);
		const span = (a: number[]) => Math.max(...a) - Math.min(...a);
		expect(span(zs)).toBeGreaterThan(4.8);
		expect(span(zs)).toBeLessThan(5.4);
		expect(span(xs)).toBeGreaterThan(1.8);
		expect(span(xs)).toBeLessThan(2.3);
		expect(Math.min(...ys)).toBeCloseTo(0, 1);
		expect(Math.max(...ys)).toBeLessThan(2.1);
	});

	it("takes the person's car colour in linear space", () => {
		const [r, g, b] = hexToLinear("#b3202b");
		expect(r).toBeGreaterThan(g);
		expect(r).toBeGreaterThan(b);
		const json = JSON.parse(new TextDecoder().decode(new Uint8Array(buildSuvGlb("#b3202b"), 20, new DataView(buildSuvGlb("#b3202b")).getUint32(12, true))));
		expect(json.materials[0].name).toBe("body");
		expect(json.materials[0].pbrMetallicRoughness.baseColorFactor[0]).toBeCloseTo(r, 5);
	});
});
