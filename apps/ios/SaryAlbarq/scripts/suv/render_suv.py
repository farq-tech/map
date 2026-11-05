#!/usr/bin/env python3
"""Preview renderer for the SUV .glb (numpy software rasteriser, metallic-roughness shading).

    python3 scripts/suv/render_suv.py model.glb out.png --view top|rear34|front34|side|nav \
        [--body E8EEF0] [--trim 3A4046] [--bg sand|night|white] [--size 900]

Approximates what a glTF PBR renderer does (sun + sky ambient, GGX highlight, Schlick
fresnel reflection of a sky gradient, emissive, BLEND materials over the ground), good
enough to judge silhouette, colour and readability without Blender.
"""
import argparse
import json
import math
import struct

import numpy as np
from PIL import Image


def lin(hexs):
    c = [int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]


def load_glb(path):
    data = open(path, "rb").read()
    jlen = struct.unpack_from("<I", data, 12)[0]
    gl = json.loads(data[20:20 + jlen])
    bin_ = data[20 + jlen + 8:]
    def acc(i):
        a = gl["accessors"][i]
        v = gl["bufferViews"][a["bufferView"]]
        dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32}[a["componentType"]]
        n = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[a["type"]]
        arr = np.frombuffer(bin_, dtype=dt, count=a["count"] * n, offset=v["byteOffset"] + a.get("byteOffset", 0))
        return arr.reshape(-1, n) if n > 1 else arr
    prims = []
    for p in gl["meshes"][0]["primitives"]:
        m = gl["materials"][p["material"]]
        P = acc(p["attributes"]["POSITION"]).astype(float)
        N = acc(p["attributes"]["NORMAL"]).astype(float)
        C = acc(p["attributes"]["COLOR_0"])[:, :3].astype(float) if "COLOR_0" in p["attributes"] else np.ones((len(P), 3))
        I = acc(p["indices"]).astype(int).reshape(-1, 3)
        prims.append((m, P, N, C, I))
    return prims


def look_at(eye, target, up=(0, 1, 0)):
    eye, target, up = map(lambda v: np.asarray(v, float), (eye, target, up))
    f = target - eye; f /= np.linalg.norm(f)
    r = np.cross(f, up); r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return eye, r, u, f


VIEWS = {
    # eye position (glTF: +Z nose, +X left, +Y up)
    "top": ((0.0, 18.0, 0.0), (0, 0.6, 0.0), (0, 0, 1), 19),
    "rear34": ((-4.2, 5.2, -6.8), (0, 0.8, 0), (0, 1, 0), 34),
    "front34": ((4.6, 4.0, 6.6), (0, 0.8, 0), (0, 1, 0), 34),
    "side": ((-9.0, 1.6, 0.0), (0, 0.9, 0), (0, 1, 0), 32),
    "nav": ((0.0, 7.0, -10.5), (0, 0.6, 1.0), (0, 1, 0), 32),
}

BG = {"sand": (0.78, 0.66, 0.5), "night": (0.08, 0.09, 0.12), "white": (0.96, 0.96, 0.97)}


def render(prims, view, size, body=None, trim=None, bg="sand"):
    S = size * 2
    eye, right, upv, fwd = look_at(*VIEWS[view][:3])
    fov = math.radians(VIEWS[view][3])
    fl = 1 / math.tan(fov / 2)
    depth = np.full((S, S), np.inf)
    nbuf = np.zeros((S, S, 3)); pbuf = np.zeros((S, S, 3)); cbuf = np.zeros((S, S, 3))
    mbuf = np.full((S, S), -1, int)
    mats = []
    blend = []

    def project(P):
        d = P - eye
        x, y, z = d @ right, d @ upv, d @ fwd
        return np.stack([(x * fl / z + 1) * S / 2, (1 - y * fl / z) * S / 2, z], axis=1)

    for mi, (m, P, N, C, I) in enumerate(prims):
        base = np.array(m["pbrMetallicRoughness"]["baseColorFactor"], float)
        if body and m["name"] in ("BODY", "body"):
            base[:3] = lin(body)
        if trim and m["name"] == "TRIM":
            base[:3] = lin(trim)
        mats.append((m, base))
        if m.get("alphaMode") == "BLEND":
            blend.append(mi)
            continue
        rasterise(project(P), P, N, C, I, mi, depth, nbuf, pbuf, cbuf, mbuf, S)

    # ground plane + sky
    L = np.array([0.35, 0.85, -0.4]); L /= np.linalg.norm(L)
    out = np.zeros((S, S, 3)); out[:] = BG[bg]
    if bg == "sand":  # subtle grain so it reads like satellite sand
        rng = np.random.default_rng(3)
        out *= (0.94 + 0.06 * rng.random((S, S, 1)))
    # BLEND layers over the ground (contact shadow, rim)
    for mi in blend:
        m, base = mats[mi]
        _, P, N, C, I = prims[mi]
        a = np.zeros((S, S)); d2 = np.full((S, S), np.inf)
        dummy = np.zeros((S, S, 3)); mb = np.full((S, S), -1, int)
        rasterise(project(P), P, N, C, I, 0, d2, dummy, dummy.copy(), dummy.copy(), mb, S)
        cover = (mb >= 0) & (mbuf < 0)
        col = base[:3] + np.array(m.get("emissiveFactor", [0, 0, 0]))
        col = np.clip(col, 0, 1)
        k = base[3]
        if m["name"] == "SHADOW":
            # soft: fade towards the outline using distance in model XZ (approximation of a blur)
            pass
        out[cover] = out[cover] * (1 - k) + col * k

    hit = mbuf >= 0
    if hit.any():
        n = nbuf[hit]; n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-9
        p = pbuf[hit]; vc = cbuf[hit]; ids = mbuf[hit]
        v = eye - p; v /= np.linalg.norm(v, axis=1, keepdims=True)
        base = np.array([mats[i][1][:3] for i in range(len(mats))])[ids] * vc
        metal = np.array([mats[i][0]["pbrMetallicRoughness"]["metallicFactor"] for i in range(len(mats))])[ids][:, None]
        rough = np.array([mats[i][0]["pbrMetallicRoughness"]["roughnessFactor"] for i in range(len(mats))])[ids][:, None]
        emis = np.array([mats[i][0].get("emissiveFactor", [0, 0, 0]) for i in range(len(mats))])[ids]
        ndl = np.clip(n @ L, 0, 1)[:, None]
        h = L + v; h /= np.linalg.norm(h, axis=1, keepdims=True)
        ndh = np.clip(np.sum(n * h, 1), 0, 1)[:, None]
        ndv = np.clip(np.sum(n * v, 1), 1e-3, 1)[:, None]
        a2 = np.maximum(rough ** 2, 0.02) ** 2
        D = a2 / (math.pi * (ndh ** 2 * (a2 - 1) + 1) ** 2)
        f0 = 0.04 * (1 - metal) + base * metal
        F = f0 + (1 - f0) * (1 - ndv) ** 5
        spec = D * F * 0.25 / ndv
        sky_amb = 0.55 + 0.25 * n[:, 1:2]
        diffuse = base * (1 - metal) * (ndl * 0.95 + sky_amb * 0.5)
        r = 2 * np.sum(n * v, 1)[:, None] * n - v
        sky = np.where(r[:, 1:2] > 0, np.array([0.75, 0.85, 1.0]) * (0.6 + 0.4 * r[:, 1:2]), np.array(BG[bg]) * 0.6)
        refl = sky * F * (1 - rough) ** 2
        col = diffuse + spec * ndl * 2.2 + refl + emis
        # tone map (filmic-ish) + gamma
        col = col / (1 + col * 0.35)
        out[hit] = np.clip(col, 0, 1) ** (1 / 2.2) if False else np.clip(col, 0, 1)
    # out is "display" ~ linear for bg; convert car pixels linear→sRGB, keep bg as is
    final = out.copy()
    final[hit] = np.clip(out[hit], 0, 1) ** (1 / 2.2)
    img = Image.fromarray((np.clip(final, 0, 1) * 255).astype(np.uint8))
    return img.resize((size, size), Image.LANCZOS)


def rasterise(scr, P, N, C, I, mi, depth, nbuf, pbuf, cbuf, mbuf, S):
    for tri in I:
        s = scr[tri]
        if (s[:, 2] <= 0.05).any():
            continue
        x0, y0 = np.floor(s[:, :2].min(0)).astype(int)
        x1, y1 = np.ceil(s[:, :2].max(0)).astype(int)
        x0, y0 = max(x0, 0), max(y0, 0); x1, y1 = min(x1, S - 1), min(y1, S - 1)
        if x0 > x1 or y0 > y1:
            continue
        (ax, ay, _), (bx, by, _), (cx, cy, _) = s
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-12:
            continue
        xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        w0 = ((by - cy) * (xs - cx) + (cx - bx) * (ys - cy)) / den
        w1 = ((cy - ay) * (xs - cx) + (ax - cx) * (ys - cy)) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not inside.any():
            continue
        iz = w0 / s[0, 2] + w1 / s[1, 2] + w2 / s[2, 2]
        z = 1 / iz
        sub = depth[y0:y1 + 1, x0:x1 + 1]
        win = inside & (z < sub)
        if not win.any():
            continue
        # perspective-correct weights
        q0, q1, q2 = w0 / s[0, 2] * z, w1 / s[1, 2] * z, w2 / s[2, 2] * z
        sub[win] = z[win]
        for buf, attr in ((nbuf, N), (pbuf, P), (cbuf, C)):
            a = attr[tri]
            val = q0[..., None] * a[0] + q1[..., None] * a[1] + q2[..., None] * a[2]
            bsub = buf[y0:y1 + 1, x0:x1 + 1]
            bsub[win] = val[win]
        mbuf[y0:y1 + 1, x0:x1 + 1][win] = mi


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("glb"); ap.add_argument("out")
    ap.add_argument("--view", default="rear34"); ap.add_argument("--body"); ap.add_argument("--trim")
    ap.add_argument("--bg", default="sand"); ap.add_argument("--size", type=int, default=900)
    a = ap.parse_args()
    render(load_glb(a.glb), a.view, a.size, a.body, a.trim, a.bg).save(a.out)
