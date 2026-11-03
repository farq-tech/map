/**
 * A low-poly 4×4 (Land-Cruiser proportions) built in code as a glTF 2.0 binary.
 *
 * Why generated rather than a downloaded .glb:
 *   · no licence question, no third-party asset in the repo
 *   · the body takes the colour the person chose for their car (farqAvatar)
 *   · ~20 KB, built once per colour, handed to Mapbox as a blob: URL
 *
 * Mapbox draws it with a `model` layer: real 3D, lit by the map, sitting on the
 * terrain, no background square. Units are metres; glTF axes: +Y up, +Z is the
 * vehicle's nose, +X its left side.
 */

type Vec3 = [number, number, number];
type Rgb = [number, number, number];

type MaterialDef = {
	color: Rgb;
	metallic: number;
	roughness: number;
	emissive?: Rgb;
};

type Part = { positions: number[]; normals: number[]; indices: number[] };

const MATERIALS = {
	body: { color: [0.92, 0.93, 0.94], metallic: 0.25, roughness: 0.38 },
	glass: { color: [0.05, 0.07, 0.09], metallic: 0.5, roughness: 0.08 },
	trim: { color: [0.12, 0.12, 0.13], metallic: 0.1, roughness: 0.7 },
	tire: { color: [0.04, 0.04, 0.045], metallic: 0, roughness: 0.95 },
	rim: { color: [0.72, 0.74, 0.76], metallic: 0.9, roughness: 0.3 },
	headlight: { color: [1, 0.97, 0.88], metallic: 0, roughness: 0.2, emissive: [1, 0.95, 0.8] },
	taillight: { color: [0.75, 0.05, 0.05], metallic: 0, roughness: 0.3, emissive: [0.6, 0.02, 0.02] },
} satisfies Record<string, MaterialDef>;

type MaterialName = keyof typeof MATERIALS;

function newPart(): Part {
	return { positions: [], normals: [], indices: [] };
}

function quad(p: Part, a: Vec3, b: Vec3, c: Vec3, d: Vec3) {
	const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
	const v = [d[0] - a[0], d[1] - a[1], d[2] - a[2]];
	let n: Vec3 = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
	const len = Math.hypot(...n) || 1;
	n = [n[0] / len, n[1] / len, n[2] / len];
	const base = p.positions.length / 3;
	for (const q of [a, b, c, d]) {
		p.positions.push(...q);
		p.normals.push(...n);
	}
	p.indices.push(base, base + 1, base + 2, base, base + 2, base + 3);
}

function tri(p: Part, a: Vec3, b: Vec3, c: Vec3) {
	const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
	const v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
	let n: Vec3 = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
	const len = Math.hypot(...n) || 1;
	n = [n[0] / len, n[1] / len, n[2] / len];
	const base = p.positions.length / 3;
	for (const q of [a, b, c]) {
		p.positions.push(...q);
		p.normals.push(...n);
	}
	p.indices.push(base, base + 1, base + 2);
}

/**
 * A box whose top face can be smaller than its bottom (a cabin with raked
 * pillars). Centre x/z, from y0 to y1; bottom size w0×l0, top w1×l1, top
 * shifted back by `shift` along Z.
 */
function frustum(p: Part, cx: number, cz: number, y0: number, y1: number, w0: number, l0: number, w1 = w0, l1 = l0, shift = 0) {
	const b = (sx: number, sz: number): Vec3 => [cx + (sx * w0) / 2, y0, cz + (sz * l0) / 2];
	const t = (sx: number, sz: number): Vec3 => [cx + (sx * w1) / 2, y1, cz + shift + (sz * l1) / 2];
	quad(p, t(-1, -1), t(-1, 1), t(1, 1), t(1, -1)); // top
	quad(p, b(-1, -1), b(1, -1), b(1, 1), b(-1, 1)); // bottom
	quad(p, b(-1, 1), b(1, 1), t(1, 1), t(-1, 1)); // front (+Z)
	quad(p, b(1, -1), b(-1, -1), t(-1, -1), t(1, -1)); // back
	quad(p, b(1, 1), b(1, -1), t(1, -1), t(1, 1)); // +X side
	quad(p, b(-1, -1), b(-1, 1), t(-1, 1), t(-1, -1)); // -X side
}

function box(p: Part, c: Vec3, s: Vec3) {
	frustum(p, c[0], c[2], c[1] - s[1] / 2, c[1] + s[1] / 2, s[0], s[2]);
}

/** A cylinder along X (a wheel) or along Z (the spare on the tailgate). */
function cylinder(p: Part, c: Vec3, r: number, width: number, axis: "x" | "z", seg = 18) {
	const ring = (side: number) =>
		Array.from({ length: seg }, (_, i): Vec3 => {
			const a = (i / seg) * Math.PI * 2;
			const u = Math.cos(a) * r;
			const v = Math.sin(a) * r;
			return axis === "x" ? [c[0] + (side * width) / 2, c[1] + v, c[2] + u] : [c[0] + u, c[1] + v, c[2] + (side * width) / 2];
		});
	const A = ring(-1);
	const B = ring(1);
	for (let i = 0; i < seg; i += 1) {
		const j = (i + 1) % seg;
		if (axis === "x") quad(p, A[i], A[j], B[j], B[i]);
		else quad(p, A[j], A[i], B[i], B[j]);
	}
	/* caps: triangle fans */
	const capA: Vec3 = axis === "x" ? [c[0] - width / 2, c[1], c[2]] : [c[0], c[1], c[2] - width / 2];
	const capB: Vec3 = axis === "x" ? [c[0] + width / 2, c[1], c[2]] : [c[0], c[1], c[2] + width / 2];
	for (let i = 0; i < seg; i += 1) {
		const j = (i + 1) % seg;
		if (axis === "x") {
			tri(p, capA, A[j], A[i]);
			tri(p, capB, B[i], B[j]);
		} else {
			tri(p, capA, A[i], A[j]);
			tri(p, capB, B[j], B[i]);
		}
	}
}

/** Builds every part, grouped by material. Exported for tests. */
export function buildSuvParts(): Record<MaterialName, Part> {
	const parts = Object.fromEntries(Object.keys(MATERIALS).map((k) => [k, newPart()])) as Record<MaterialName, Part>;
	const L = 4.85; // length
	const W = 1.88; // width
	const half = L / 2;

	/* Body: lower block, then a slightly narrower shoulder up to the belt line. */
	frustum(parts.body, 0, 0, 0.42, 0.95, W, L, W, L - 0.1);
	frustum(parts.body, 0, -0.05, 0.95, 1.2, W, L - 0.1, W - 0.06, L - 0.35);
	/* Glass house: raked windscreen at the front, upright tailgate glass. */
	frustum(parts.glass, 0, -0.45, 1.2, 1.8, W - 0.08, 2.95, W - 0.2, 2.45, -0.18);
	/* Roof and pillars read as body colour. */
	frustum(parts.body, 0, -0.63, 1.8, 1.86, W - 0.18, 2.47);
	box(parts.body, [0, 1.5, -1.0], [W - 0.06, 0.6, 0.12]); // C-pillar
	for (const x of [-W / 2 + 0.03, W / 2 - 0.03]) box(parts.body, [x, 1.5, -0.05], [0.04, 0.6, 0.1]); // B-pillars

	/* Bumpers, grille, wheel arches, side steps, mirrors. */
	box(parts.trim, [0, 0.5, half + 0.04], [W + 0.04, 0.3, 0.14]);
	box(parts.trim, [0, 0.5, -half - 0.04], [W + 0.04, 0.3, 0.14]);
	box(parts.trim, [0, 0.88, half + 0.005], [1.0, 0.24, 0.02]);
	box(parts.trim, [0, 0.36, 0], [W + 0.02, 0.06, 2.3]);
	for (const x of [-W / 2 - 0.08, W / 2 + 0.08]) box(parts.trim, [x, 1.25, 1.0], [0.12, 0.1, 0.16]);
	for (const z of [1.45, -1.45]) for (const x of [-W / 2 - 0.02, W / 2 + 0.02]) box(parts.trim, [x, 0.84, z], [0.12, 0.1, 1.0]);

	/* Roof rack: two rails and three cross bars. */
	for (const x of [-0.72, 0.72]) box(parts.trim, [x, 1.95, -0.63], [0.05, 0.05, 2.3]);
	for (const z of [0.35, -0.63, -1.6]) box(parts.trim, [0, 1.98, z], [1.5, 0.04, 0.05]);
	for (const z of [0.4, -1.65]) for (const x of [-0.72, 0.72]) box(parts.trim, [x, 1.9, z], [0.05, 0.08, 0.05]);

	/* Lights. */
	for (const x of [-0.62, 0.62]) box(parts.headlight, [x, 0.92, half + 0.01], [0.42, 0.14, 0.03]);
	for (const x of [-0.82, 0.82]) box(parts.taillight, [x, 1.0, -half - 0.01], [0.18, 0.3, 0.03]);

	/* Wheels and the spare on the tailgate. */
	for (const z of [1.45, -1.45]) {
		for (const x of [-W / 2 + 0.05, W / 2 - 0.05]) {
			cylinder(parts.tire, [x, 0.4, z], 0.4, 0.3, "x");
			cylinder(parts.rim, [x + Math.sign(x) * 0.02, 0.4, z], 0.22, 0.3, "x", 12);
		}
	}
	cylinder(parts.tire, [0.25, 0.95, -half - 0.16], 0.37, 0.24, "z");
	cylinder(parts.rim, [0.25, 0.95, -half - 0.19], 0.2, 0.24, "z", 12);
	return parts;
}

export function hexToLinear(hex: string): Rgb {
	const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
	if (!m) return MATERIALS.body.color as Rgb;
	const n = parseInt(m[1], 16);
	const srgb = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => v / 255);
	/* glTF baseColorFactor is linear. */
	return srgb.map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)) as Rgb;
}

/** The whole vehicle as a .glb, body in `bodyHex`. */
export function buildSuvGlb(bodyHex = "#e8eef0"): ArrayBuffer {
	const parts = buildSuvParts();
	const names = Object.keys(MATERIALS) as MaterialName[];
	const chunks: ArrayBuffer[] = [];
	const bufferViews: Array<Record<string, number>> = [];
	const accessors: Array<Record<string, unknown>> = [];
	const primitives: Array<Record<string, unknown>> = [];
	let offset = 0;

	const push = (data: Float32Array | Uint16Array, target: number) => {
		const bytes = data.byteLength;
		const padded = Math.ceil(bytes / 4) * 4;
		const out = new Uint8Array(padded);
		out.set(new Uint8Array(data.buffer, data.byteOffset, bytes));
		chunks.push(out.buffer);
		bufferViews.push({ buffer: 0, byteOffset: offset, byteLength: bytes, target });
		offset += padded;
		return bufferViews.length - 1;
	};

	names.forEach((name, mi) => {
		const p = parts[name];
		if (!p.indices.length) return;
		const pos = new Float32Array(p.positions);
		const min = [Infinity, Infinity, Infinity];
		const max = [-Infinity, -Infinity, -Infinity];
		for (let i = 0; i < pos.length; i += 3) {
			for (let k = 0; k < 3; k += 1) {
				min[k] = Math.min(min[k], pos[i + k]);
				max[k] = Math.max(max[k], pos[i + k]);
			}
		}
		const posView = push(pos, 34962);
		const nrmView = push(new Float32Array(p.normals), 34962);
		const idxView = push(new Uint16Array(p.indices), 34963);
		accessors.push({ bufferView: posView, componentType: 5126, count: pos.length / 3, type: "VEC3", min, max });
		const posAcc = accessors.length - 1;
		accessors.push({ bufferView: nrmView, componentType: 5126, count: pos.length / 3, type: "VEC3" });
		const nrmAcc = accessors.length - 1;
		accessors.push({ bufferView: idxView, componentType: 5123, count: p.indices.length, type: "SCALAR" });
		primitives.push({ attributes: { POSITION: posAcc, NORMAL: nrmAcc }, indices: accessors.length - 1, material: mi });
	});

	const materials = names.map((name) => {
		const m: MaterialDef = MATERIALS[name];
		const color = name === "body" ? hexToLinear(bodyHex) : m.color;
		return {
			name,
			pbrMetallicRoughness: { baseColorFactor: [...color, 1], metallicFactor: m.metallic, roughnessFactor: m.roughness },
			...(m.emissive ? { emissiveFactor: m.emissive } : {}),
		};
	});

	const gltf = {
		asset: { version: "2.0", generator: "sary-albarq suvModel" },
		scene: 0,
		scenes: [{ nodes: [0] }],
		nodes: [{ mesh: 0, name: "suv" }],
		meshes: [{ name: "suv", primitives }],
		materials,
		accessors,
		bufferViews,
		buffers: [{ byteLength: offset }],
	};

	const json = new TextEncoder().encode(JSON.stringify(gltf));
	const jsonPadded = Math.ceil(json.length / 4) * 4;
	const total = 12 + 8 + jsonPadded + 8 + offset;
	const out = new ArrayBuffer(total);
	const dv = new DataView(out);
	const u8 = new Uint8Array(out);
	dv.setUint32(0, 0x46546c67, true); // "glTF"
	dv.setUint32(4, 2, true);
	dv.setUint32(8, total, true);
	dv.setUint32(12, jsonPadded, true);
	dv.setUint32(16, 0x4e4f534a, true); // "JSON"
	u8.set(json, 20);
	for (let i = json.length; i < jsonPadded; i += 1) u8[20 + i] = 0x20;
	let o = 20 + jsonPadded;
	dv.setUint32(o, offset, true);
	dv.setUint32(o + 4, 0x004e4942, true); // "BIN\0"
	o += 8;
	for (const c of chunks) {
		u8.set(new Uint8Array(c), o);
		o += c.byteLength;
	}
	return out;
}

const urlCache = new Map<string, string>();

/** A blob: URL for Mapbox's addModel, one per body colour. */
export function suvModelUrl(bodyHex: string): string {
	const key = bodyHex.toLowerCase();
	const hit = urlCache.get(key);
	if (hit) return hit;
	const url = URL.createObjectURL(new Blob([buildSuvGlb(key)], { type: "model/gltf-binary" }));
	urlCache.set(key, url);
	return url;
}
