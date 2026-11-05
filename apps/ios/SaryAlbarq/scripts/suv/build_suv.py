#!/usr/bin/env python3
"""«سَرى البارق» expedition SUV — the participants' car on the live map.

An ORIGINAL generic rugged boxy overland 4x4 (no brand, badge, logo or production-model
design): boxy body with bevelled edges, black flares and bumpers, simplified platform roof
rack with a rolled awning bag, spare tyre on the tailgate, square lamps, mirrors.

Designed for the map first (like the 3D vehicle puck of Google / Apple Maps navigation):
slightly stylised proportions (a touch wide and tall so it reads at 26 pt), a bold
silhouette from top-down and pitched views, the nose readable (raked windscreen + white
square headlights) and the tail readable (spare tyre + red lamps), a soft contact shadow
with a light rim so it pops on satellite sand AND on night maps.

"Glassy" finish within what Mapbox's model layer renders (glTF 2.0 metallic-roughness, no
clearcoat/transmission): low-roughness body, rounded bevels with smoothed normals for soft
specular highlights, dark smoked glass with mild metallic reflection, and a baked
vertex-colour gradient (COLOR_0: slightly darker low on the body, full at the shoulder) in
place of a clear-coat/fresnel layer.

Pure Python (numpy + scipy ConvexHull), deterministic, no Blender needed:
    python3 scripts/suv/build_suv.py Resources/Models/SuvExpedition.glb
The same parts can be imported into Blender (File > Import > glTF) for touch-ups.

glTF axes (same as the previous in-code model so `Vehicle.rotation` is unchanged):
+Y up, +Z the nose, +X the vehicle's left. Units metres, origin on the ground at the centre.
Materials (names are the contract with SuvModel.swift, which recolours BODY at runtime):
BODY, TRIM, GLASS, TYRE, RIM, HEADLIGHT, TAILLIGHT, SHADOW*, RIMLIGHT.
"""
import json
import math
import struct
import sys

import numpy as np
from scipy.spatial import ConvexHull

# ---------------------------------------------------------------- materials

def srgb_to_linear(c):
    return [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]

MATERIALS = [
    # name, baseColor (linear rgba), metallic, roughness, emissive, alphaMode
    ("BODY", srgb_to_linear([0.91, 0.93, 0.94]) + [1.0], 0.05, 0.2, None, None),
    ("TRIM", srgb_to_linear([0.10, 0.105, 0.115]) + [1.0], 0.1, 0.5, None, None),
    ("GLASS", srgb_to_linear([0.07, 0.09, 0.11]) + [1.0], 0.6, 0.06, None, None),
    ("TYRE", srgb_to_linear([0.06, 0.06, 0.065]) + [1.0], 0.0, 0.9, None, None),
    ("RIM", srgb_to_linear([0.55, 0.57, 0.6]) + [1.0], 0.8, 0.3, None, None),
    ("HEADLIGHT", [1.0, 0.98, 0.92, 1.0], 0.0, 0.15, [1.0, 0.97, 0.88], None),
    ("TAILLIGHT", srgb_to_linear([0.85, 0.08, 0.08]) + [1.0], 0.0, 0.2, [0.9, 0.04, 0.03], None),
    ("SHADOW", [0.0, 0.0, 0.0, 0.45], 0.0, 1.0, None, "BLEND"),
    ("SHADOW_SOFT", [0.0, 0.0, 0.0, 0.25], 0.0, 1.0, None, "BLEND"),
    ("SHADOW_EDGE", [0.0, 0.0, 0.0, 0.11], 0.0, 1.0, None, "BLEND"),
    ("RIMLIGHT", [1.0, 1.0, 1.0, 0.5], 0.0, 1.0, [0.55, 0.55, 0.55], "BLEND"),
]

# ---------------------------------------------------------------- geometry

class Part:
    def __init__(self):
        self.tris = []      # list of (3,3) arrays
        self.smooth = []    # per-triangle smoothing angle (deg); 0 = flat

    def add(self, tris, smooth):
        for t in tris:
            self.tris.append(np.asarray(t, dtype=float))
            self.smooth.append(smooth)


PARTS = {m[0]: Part() for m in MATERIALS}

# Directions for rounding a convex shape (Minkowski sum with a faceted sphere): the
# surface of a 5x5x5 grid cube, normalised → bevels in ~25° steps.
_g = np.linspace(-1, 1, 5)
_dirs = np.array([(x, y, z) for x in _g for y in _g for z in _g if max(abs(x), abs(y), abs(z)) == 1.0])
ROUND_DIRS = _dirs / np.linalg.norm(_dirs, axis=1, keepdims=True)
# Coarser set (single 45° chamfer) for small parts, which are only a few pixels on the map.
_c = np.array([(x, y, z) for x in (-1, 0, 1) for y in (-1, 0, 1) for z in (-1, 0, 1) if (x, y, z) != (0, 0, 0)], dtype=float)
COARSE_DIRS = _c / np.linalg.norm(_c, axis=1, keepdims=True)


def hull_tris(points):
    pts = np.asarray(points, dtype=float)
    h = ConvexHull(pts)
    centre = pts.mean(axis=0)
    out = []
    for s, eq in zip(h.simplices, h.equations):
        a, b, c = pts[s]
        n = np.cross(b - a, c - a)
        if np.dot(n, eq[:3]) < 0:
            b, c = c, b
        out.append(np.array([a, b, c]))
    return out


def hull(part, points, round_r=0.0, smooth=35.0):
    pts = np.asarray(points, dtype=float)
    if round_r > 0:
        dirs = ROUND_DIRS if round_r >= 0.04 else COARSE_DIRS
        pts = (pts[:, None, :] + dirs[None, :, :] * round_r).reshape(-1, 3)
    PARTS[part].add(hull_tris(pts), smooth if round_r > 0 else 0.0)


def box_pts(x0, x1, y0, y1, z0, z1):
    return [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]


def rbox(part, x0, x1, y0, y1, z0, z1, r=0.0, smooth=35.0):
    """Rounded box given by its OUTER bounds."""
    hull(part, box_pts(x0 + r, x1 - r, y0 + r, y1 - r, z0 + r, z1 - r), r, smooth)


def slab(part, bottom, top, r=0.0, smooth=35.0):
    """Convex solid between two horizontal rectangles (x0,x1,z0,z1) at y0 / y1 (outer bounds)."""
    (bx0, bx1, bz0, bz1, y0), (tx0, tx1, tz0, tz1, y1) = bottom, top
    pts = [(x, y0 + r, z) for x in (bx0 + r, bx1 - r) for z in (bz0 + r, bz1 - r)]
    pts += [(x, y1 - r, z) for x in (tx0 + r, tx1 - r) for z in (tz0 + r, tz1 - r)]
    hull(part, pts, r, smooth)


def cylinder(part, centre, radius, width, axis, seg=20, round_r=0.0):
    cx, cy, cz = centre
    pts = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        u, v = math.cos(a) * (radius - round_r), math.sin(a) * (radius - round_r)
        for s in (-1, 1):
            w = s * (width / 2 - round_r)
            if axis == "x":
                pts.append((cx + w, cy + v, cz + u))
            else:
                pts.append((cx + u, cy + v, cz + w))
    if round_r > 0:
        # only a small edge roll: few directions keep tyres cheap
        p = np.asarray(pts)
        p = (p[:, None, :] + COARSE_DIRS[None, :, :] * round_r).reshape(-1, 3)
        PARTS[part].add(hull_tris(p), 40.0)
    else:
        PARTS[part].add(hull_tris(pts), 40.0)


def ground_ring(part, hx, hz, r, y, inner=None, seg_corner=6):
    """Rounded rectangle on the ground (a filled disc, or a ring when `inner` is given)."""
    def outline(hx, hz, r):
        pts = []
        for cx, cz, a0 in ((hx - r, hz - r, 0), (-hx + r, hz - r, 90), (-hx + r, -hz + r, 180), (hx - r, -hz + r, 270)):
            for i in range(seg_corner + 1):
                a = math.radians(a0 + 90 * i / seg_corner)
                pts.append((cx + r * math.cos(a), y, cz + r * math.sin(a)))
        return pts
    o = outline(hx, hz, r)
    tris = []
    if inner is None:
        c = np.array([0.0, y, 0.0])
        for i in range(len(o)):
            a, b = np.array(o[i]), np.array(o[(i + 1) % len(o)])
            tris.append(np.array([c, b, a]))  # facing +Y
    else:
        ihx, ihz, ir = inner
        ii = outline(ihx, ihz, ir)
        for i in range(len(o)):
            j = (i + 1) % len(o)
            a, b, c, d = map(np.array, (o[i], o[j], ii[j], ii[i]))
            tris.append(np.array([a, d, c]))
            tris.append(np.array([a, c, b]))
    PARTS[part].add(tris, 0.0)


# ---------------------------------------------------------------- the vehicle
# Stylised: body 1.96 wide (flares 2.08), 4.72 long incl. bumpers and spare, 1.98 tall.

W = 0.98           # half width of the body
ZF, ZR = 2.10, -2.10   # body nose / tail faces
BELT = 1.14        # top of the lower body (bonnet / waist)
ROOF = 1.80

# Contact shadow + light rim (drawn first, on the ground).
# A soft-edged shadow: a core plus two fading bands (alpha adds up towards the centre),
# then a thin light rim just outside it.
ground_ring("SHADOW", 1.06, 2.36, 0.4, 0.014)
ground_ring("SHADOW_SOFT", 1.16, 2.46, 0.45, 0.013, inner=(1.06, 2.36, 0.4))
ground_ring("SHADOW_EDGE", 1.26, 2.56, 0.5, 0.012, inner=(1.16, 2.46, 0.45))
ground_ring("RIMLIGHT", 1.38, 2.68, 0.56, 0.010, inner=(1.26, 2.56, 0.5))

# Lower body: one rounded tub, a little narrower at the waist, nose slightly lower.
slab("BODY", (-W, W, ZR, ZF, 0.46), (-W + 0.03, W - 0.03, ZR + 0.02, ZF - 0.04, BELT), r=0.09)
# Bonnet: a gentle raised panel (catches a highlight from above).
slab("BODY", (-W + 0.1, W - 0.1, 0.95, ZF - 0.08, BELT - 0.04), (-W + 0.16, W - 0.16, 1.0, ZF - 0.14, BELT + 0.035), r=0.03)

# Greenhouse: smoked glass block, raked windscreen, upright rear.
slab("GLASS", (-W + 0.05, W - 0.05, ZR + 0.05, 0.98, BELT - 0.02), (-W + 0.11, W - 0.11, ZR + 0.08, 0.55, ROOF - 0.02), r=0.04)
# Roof shell in body colour, slightly proud of the glass so it reads as a solid roof.
slab("BODY", (-W + 0.07, W - 0.07, ZR + 0.04, 0.62, ROOF - 0.07), (-W + 0.09, W - 0.09, ZR + 0.06, 0.55, ROOF + 0.03), r=0.04)
# Pillars in body colour (boxy look: thick C/D pillars, slim A pillars).
for s in (-1, 1):
    xo = s * (W - 0.07)
    xi = s * (W - 0.13)
    lo, hi = min(xo, xi), max(xo, xi)
    # A pillar: follows the windscreen rake
    hull("BODY", [(lo, BELT, 0.98), (hi, BELT, 0.98), (lo, BELT, 0.9), (hi, BELT, 0.9),
                  (lo, ROOF - 0.04, 0.58), (hi, ROOF - 0.04, 0.58), (lo, ROOF - 0.04, 0.5), (hi, ROOF - 0.04, 0.5)], 0.015)
    xo2 = s * (W - 0.035)
    lo2, hi2 = min(xo2, xi), max(xo2, xi)
    rbox("BODY", lo2, hi2, BELT - 0.02, ROOF, -0.05, 0.08, 0.02)          # B pillar
    rbox("BODY", lo2, hi2, BELT - 0.02, ROOF, ZR + 0.02, ZR + 0.62, 0.03)  # wide D pillar
# Tailgate panel below the rear window (body colour) and a dark rear window above it.
rbox("BODY", -W + 0.05, W - 0.05, 0.5, BELT + 0.02, ZR - 0.03, ZR + 0.1, 0.04)
rbox("GLASS", -W + 0.2, W - 0.2, BELT + 0.06, ROOF - 0.1, ZR - 0.012, ZR + 0.05, 0.02)

# Front: black grille panel between square headlights; chunky black bumper; silver skid.
rbox("TRIM", -0.56, 0.56, 0.66, 1.02, ZF - 0.03, ZF + 0.025, 0.02)
for y in (0.78, 0.9):
    rbox("RIM", -0.5, 0.5, y - 0.015, y + 0.015, ZF + 0.02, ZF + 0.04, 0.0)   # two grille bars
for s in (-1, 1):
    x0, x1 = sorted((s * 0.6, s * 0.9))
    rbox("HEADLIGHT", x0, x1, 0.74, 1.0, ZF - 0.02, ZF + 0.035, 0.03)       # square lamp
rbox("TRIM", -W - 0.05, W + 0.05, 0.36, 0.66, ZF - 0.1, ZF + 0.14, 0.06)    # bumper
rbox("RIM", -0.55, 0.55, 0.28, 0.4, ZF - 0.05, ZF + 0.1, 0.03)              # skid plate

# Rear: chunky black bumper, square red tail lamps on the corners, high stop lamp, reflectors.
rbox("TRIM", -W - 0.04, W + 0.04, 0.36, 0.64, ZR - 0.12, ZR + 0.08, 0.06)
rbox("RIM", -0.5, 0.5, 0.3, 0.4, ZR - 0.08, ZR + 0.06, 0.03)
for s in (-1, 1):
    x0, x1 = sorted((s * (W - 0.02), s * (W - 0.24)))
    rbox("TRIM", x0 - 0.01, x1 + 0.01, 0.66, 1.1, ZR - 0.045, ZR + 0.05, 0.02)  # lamp bezel
    rbox("TAILLIGHT", x0 + 0.02, x1 - 0.02, 0.7, 1.06, ZR - 0.06, ZR + 0.02, 0.02)
    xr0, xr1 = sorted((s * (W - 0.05), s * (W - 0.2)))
    rbox("TAILLIGHT", xr0, xr1, 0.44, 0.5, ZR - 0.13, ZR - 0.1, 0.0)          # bumper reflector
rbox("TAILLIGHT", -0.18, 0.18, ROOF - 0.06, ROOF - 0.02, ZR - 0.01, ZR + 0.08, 0.01)  # high stop lamp

# Spare tyre on the tailgate (offset towards the right side, -X) with a grey wheel.
SPX, SPY, SPZ = -0.22, 1.04, ZR - 0.2
cylinder("TYRE", (SPX, SPY, SPZ), 0.42, 0.26, "z", seg=28, round_r=0.05)
cylinder("RIM", (SPX, SPY, SPZ - 0.11), 0.25, 0.06, "z", seg=20)
rbox("TRIM", SPX - 0.05, SPX + 0.05, SPY - 0.05, SPY + 0.05, SPZ - 0.15, SPZ - 0.12, 0.0)  # hub cap
for k in range(8):  # spokes of the spare's wheel (dark, so the grey rim reads as an alloy)
    a = 2 * math.pi * k / 8 + math.pi / 8
    pts = []
    for rr in (0.07, 0.23):
        for da in (-0.09, 0.09):
            for dz in (-0.152, -0.142):
                pts.append((SPX + rr * math.cos(a + da / rr * 0.07), SPY + rr * math.sin(a + da / rr * 0.07), SPZ + dz))
    hull("TRIM", pts)
rbox("TRIM", 0.28, 0.56, 0.86, 0.92, ZR - 0.045, ZR - 0.02, 0.01)  # tailgate handle
rbox("TRIM", SPX - 0.14, SPX + 0.14, SPY - 0.06, SPY + 0.06, ZR - 0.1, ZR, 0.0)           # carrier

# Wheels with black fender flares over them.
for zc in (1.38, -1.36):
    for s in (-1, 1):
        cylinder("TYRE", (s * 0.86, 0.41, zc), 0.41, 0.32, "x", seg=24, round_r=0.05)
        cylinder("RIM", (s * 1.0, 0.41, zc), 0.24, 0.05, "x", seg=16)
        xo, xi = s * (W + 0.1), s * (W - 0.03)
        lo, hi = min(xo, xi), max(xo, xi)
        # flare: a trapezoid arch over the tyre (wider at the bottom, like an off-roader's)
        hull("TRIM", [(lo, 0.52, zc + 0.62), (hi, 0.52, zc + 0.62), (lo, 0.52, zc - 0.62), (hi, 0.52, zc - 0.62),
                      (lo, 0.86, zc + 0.44), (hi, 0.86, zc + 0.44), (lo, 0.86, zc - 0.44), (hi, 0.86, zc - 0.44)], 0.03)
# Rock sliders / side steps.
for s in (-1, 1):
    x0, x1 = sorted((s * (W - 0.05), s * (W + 0.08)))
    rbox("TRIM", x0, x1, 0.38, 0.5, -0.78, 0.8, 0.04)
# Mirrors (body colour caps on black arms).
for s in (-1, 1):
    x0, x1 = sorted((s * (W - 0.02), s * (W + 0.1)))
    rbox("TRIM", x0, x1, 1.17, 1.22, 0.84, 0.92, 0.0)
    x0, x1 = sorted((s * (W + 0.04), s * (W + 0.16)))
    rbox("BODY", x0, x1, 1.14, 1.36, 0.78, 0.94, 0.03)

# Roof rack: a perimeter frame with five crossbars (thin, so the body colour still shows),
# four feet, and the rolled awning bag along the right side (-X).
RY = ROOF + 0.1
RZ0, RZ1 = ZR + 0.32, 0.42
RX = W - 0.16
for s in (-1, 1):
    x0, x1 = sorted((s * RX, s * (RX - 0.06)))
    rbox("TRIM", x0, x1, RY - 0.03, RY + 0.04, RZ0, RZ1, 0.015)        # side rails
    for zf in (RZ0 + 0.05, (RZ0 + RZ1) / 2, RZ1 - 0.05):
        rbox("TRIM", x0, x1, ROOF + 0.02, RY, zf - 0.04, zf + 0.04, 0.0)  # feet
for zc in (RZ0 + 0.02, RZ1 - 0.02):
    rbox("TRIM", -RX, RX, RY - 0.03, RY + 0.04, zc - 0.03, zc + 0.03, 0.015)  # end bars
for i in range(5):
    zc = RZ0 + (RZ1 - RZ0) * (i + 1) / 6
    rbox("TRIM", -RX + 0.04, RX - 0.04, RY - 0.01, RY + 0.025, zc - 0.022, zc + 0.022, 0.0)
cylinder("TRIM", (-(W - 0.02), RY + 0.02, (RZ0 + RZ1) / 2 - 0.05), 0.1, RZ1 - RZ0 + 0.15, "z", seg=14, round_r=0.03)
rbox("RIM", -(W - 0.02) - 0.105, -(W - 0.02) + 0.105, RY - 0.085, RY + 0.125, RZ0 - 0.14, RZ0 - 0.1, 0.0)  # end cap

# ---------------------------------------------------------------- export

def build_primitive(part, name):
    tris = np.array(part.tris)                       # (n,3,3)
    fn = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    ln = np.linalg.norm(fn, axis=1, keepdims=True)
    keep = ln[:, 0] > 1e-10
    tris, fn, ln = tris[keep], fn[keep], ln[keep]
    smooth = np.array(part.smooth)[keep]
    fn = fn / ln
    pos = tris.reshape(-1, 3)
    nrm = np.repeat(fn, 3, axis=0)
    # smoothed normals: average face normals around a position within the triangle's angle
    keyed = {}
    keys = [tuple(np.round(p, 4)) for p in pos]
    for i, k in enumerate(keys):
        keyed.setdefault(k, []).append(i)
    out_n = nrm.copy()
    for idxs in keyed.values():
        if len(idxs) < 2:
            continue
        for i in idxs:
            ang = smooth[i // 3]
            if ang <= 0:
                continue
            c = math.cos(math.radians(ang))
            acc = np.zeros(3)
            for j in idxs:
                if np.dot(nrm[i], nrm[j]) >= c:
                    acc += nrm[j]
            out_n[i] = acc / np.linalg.norm(acc)
    # weld identical (position, normal) corners
    verts, index, remap = [], [], {}
    for p, n in zip(pos, out_n):
        k = tuple(np.round(p, 5)) + tuple(np.round(n, 3))
        if k not in remap:
            remap[k] = len(verts)
            verts.append((p, n))
        index.append(remap[k])
    P = np.array([v[0] for v in verts], dtype=np.float32)
    N = np.array([v[1] for v in verts], dtype=np.float32)
    N /= np.linalg.norm(N, axis=1, keepdims=True)
    colors = None
    if name == "BODY":
        # baked gradient: 0.8 at the sills → 1.0 at the waist and above (fake clear-coat depth)
        y = P[:, 1]
        g = np.clip(0.8 + (y - 0.46) / (BELT - 0.46) * 0.2, 0.8, 1.0)
        up = np.clip(N[:, 1], 0, 1)
        g = np.minimum(1.0, g + 0.04 * up)
        colors = np.stack([g, g, g, np.ones_like(g)], axis=1).astype(np.float32)
    return P, N, np.array(index, dtype=np.uint16 if len(verts) < 65535 else np.uint32), colors


def write_glb(path):
    bin_ = bytearray()
    views, accessors, prims = [], [], []

    def push(arr, target):
        data = arr.tobytes()
        off = len(bin_)
        bin_.extend(data)
        bin_.extend(b"\0" * ((4 - len(data) % 4) % 4))
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        return len(views) - 1

    total_tris = 0
    for mi, (name, *_rest) in enumerate(MATERIALS):
        part = PARTS[name]
        if not part.tris:
            continue
        P, N, I, C = build_primitive(part, name)
        total_tris += len(I) // 3
        attrs = {}
        accessors.append({"bufferView": push(P, 34962), "componentType": 5126, "count": len(P), "type": "VEC3",
                          "min": [float(v) for v in P.min(0)], "max": [float(v) for v in P.max(0)]})
        attrs["POSITION"] = len(accessors) - 1
        accessors.append({"bufferView": push(N, 34962), "componentType": 5126, "count": len(N), "type": "VEC3"})
        attrs["NORMAL"] = len(accessors) - 1
        if C is not None:
            accessors.append({"bufferView": push(C, 34962), "componentType": 5126, "count": len(C), "type": "VEC4"})
            attrs["COLOR_0"] = len(accessors) - 1
        accessors.append({"bufferView": push(I, 34963), "componentType": 5123 if I.dtype == np.uint16 else 5125,
                          "count": len(I), "type": "SCALAR"})
        prims.append({"attributes": attrs, "indices": len(accessors) - 1, "material": mi})

    mats = []
    for name, base, metal, rough, emissive, alpha in MATERIALS:
        m = {"name": name, "pbrMetallicRoughness": {"baseColorFactor": [round(v, 6) for v in base],
                                                     "metallicFactor": metal, "roughnessFactor": rough}}
        if emissive:
            m["emissiveFactor"] = emissive
        if alpha:
            m["alphaMode"] = alpha
        mats.append(m)

    gltf = {
        "asset": {"version": "2.0", "generator": "sary-albarq build_suv.py (original expedition SUV)"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "sary-suv"}],
        "meshes": [{"name": "sary-suv", "primitives": prims}],
        "materials": mats, "accessors": accessors, "bufferViews": views,
        "buffers": [{"byteLength": len(bin_)}],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bin_))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(bin_), 0x004E4942) + bytes(bin_)
    with open(path, "wb") as f:
        f.write(out)
    return total_tris, len(out)


if __name__ == "__main__":
    dst = sys.argv[1] if len(sys.argv) > 1 else "SuvExpedition.glb"
    tris, size = write_glb(dst)
    print(f"{dst}: {tris} triangles, {size} bytes")
