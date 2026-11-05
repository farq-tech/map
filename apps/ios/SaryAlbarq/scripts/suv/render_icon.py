#!/usr/bin/env python3
"""The 2D car icon (map marker, list avatars) rendered from our own SUV model.

    python3 scripts/suv/render_icon.py Resources/Models/SuvExpedition.glb Resources/CarIcon [--preview DIR]

A studio render (numpy rasteriser: key light + hemispheric fill, softbox reflections, a glossy
clear-coat on the body, Schlick fresnel rim, soft contact shadow, light outline) of the model
seen from above and slightly behind, nose up. It writes two layers so the app paints the
body any colour at runtime (CarIcon.swift), exactly like this renderer would:

  CarIconBase.png  RGBA, everything that is not paint (trim, rack, awning, glass, tyres,
                   lamps) + the light outline + the soft shadow; transparent where paint is.
  CarIconBody.png  RGB, opaque. R = diffuse factor D, G = reflection K (both sRGB-encoded
                   0…1), B = paint coverage. Paint pixel (linear) = colour · D + K, then the
                   same tone curve as below, then sRGB — composited over the base by B.

Original artwork from our own model: no reference pixels, no logo or badge.
"""
import argparse
import math
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_suv import load_glb, rasterise  # noqa: E402

PX_PER_M = 64            # master resolution
CANVAS_M = (3.7, 5.6)    # width × height of the icon in metres (car + outline + shadow)
ELEVATION = 48.0         # degrees above the horizon, looking from behind
SS = 3                   # supersampling


def tone(c):
    return c / (1 + 0.3 * c)


def srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def env(r):
    """Studio environment: dark floor, soft sky gradient, two long softboxes overhead."""
    y = r[:, 1]
    sky = np.where(y[:, None] > 0, np.array([0.62, 0.68, 0.76]) * (0.55 + 0.45 * y[:, None]), np.array([0.05, 0.05, 0.06]))
    # a bright horizon band, so upright glass (rear window) catches a soft reflection
    sky = sky + np.clip(1 - np.abs(y[:, None] + 0.05) / 0.25, 0, 1) * np.array([0.32, 0.34, 0.37])
    # softboxes: bands across the car (along X), seen in reflections of the hood/roof/rear
    box = np.zeros(len(r))
    for zc, w, k in ((0.35, 0.18, 2.6), (-0.45, 0.14, 1.8)):
        d = np.abs(r[:, 2] - zc)
        box += k * np.clip((w - d) / 0.06, 0, 1) * (y > 0.55)
    # a side strip light (rim on the flanks)
    box += 1.4 * np.clip((np.abs(r[:, 0]) - 0.82) / 0.08, 0, 1) * (y > -0.1) * (y < 0.5)
    return sky + box[:, None] * np.array([1.0, 0.98, 0.95])


def render_layers(prims, body_name="BODY"):
    Wm, Hm = CANVAS_M
    S_w, S_h = int(Wm * PX_PER_M) * SS, int(Hm * PX_PER_M) * SS
    S = max(S_w, S_h)
    # camera from behind and above, nose up
    el = math.radians(ELEVATION)
    dist = 8.0  # a real (mild) perspective, like a photo from a drone behind the car
    target = np.array([0.0, 0.8, -0.05])
    eye = target + dist * np.array([0.0, math.sin(el), -math.cos(el)])
    fwd = (target - eye) / dist
    right = np.cross(fwd, np.array([0.0, 1.0, 0.0])); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    half_h = Hm / 2
    fl = dist / half_h  # so that ±half_h metres fills the canvas height

    def project(P):
        d = P - eye
        x, y, z = d @ right, d @ up, d @ fwd
        sx = (x * fl / z) * S_h / 2 + S_h / 2
        sy = (1 - y * fl / z) * S_h / 2
        return np.stack([sx, sy, z], axis=1)

    # square buffers (the rasteriser's contract), cropped to the canvas width afterwards
    depth = np.full((S_h, S_h), np.inf)
    nbuf = np.zeros((S_h, S_h, 3)); pbuf = np.zeros((S_h, S_h, 3)); cbuf = np.zeros((S_h, S_h, 3))
    mbuf = np.full((S_h, S_h), -1, int)
    mats = []
    for mi, (m, P, N, C, I) in enumerate(prims):
        mats.append(m)
        if m.get("alphaMode") == "BLEND":  # the in-map shadow/rim discs: the icon draws its own
            continue
        rasterise(project(P), P, N, C, I, mi, depth, nbuf, pbuf, cbuf, mbuf, S_h)
    x0 = (S_h - S_w) // 2
    depth, nbuf, pbuf, cbuf, mbuf = (b[:, x0:x0 + S_w] for b in (depth, nbuf, pbuf, cbuf, mbuf))
    hit = mbuf >= 0
    names = np.array([m["name"] for m in mats])
    is_body = np.zeros_like(hit); is_body[hit] = names[mbuf[hit]] == body_name

    n = nbuf[hit]; n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-9
    p = pbuf[hit]; vc = cbuf[hit]; ids = mbuf[hit]
    v = np.tile(-fwd, (len(n), 1))
    pbr = [m["pbrMetallicRoughness"] for m in mats]
    base = np.array([pb["baseColorFactor"][:3] for pb in pbr])[ids] * vc
    metal = np.array([pb["metallicFactor"] for pb in pbr])[ids][:, None]
    rough = np.array([pb["roughnessFactor"] for pb in pbr])[ids][:, None]
    emis = np.array([m.get("emissiveFactor", [0, 0, 0]) for m in mats])[ids]
    body = is_body[hit][:, None]

    L = np.array([0.35, 0.9, 0.25]); L /= np.linalg.norm(L)
    ndl = np.clip(n @ L, 0, 1)[:, None]
    ndv = np.clip(np.sum(n * v, 1), 1e-3, 1)[:, None]
    h = L + v; h /= np.linalg.norm(h, axis=1, keepdims=True)
    ndh = np.clip(np.sum(n * h, 1), 0, 1)[:, None]
    # ambient occlusion-ish: lower and inward-facing parts get less fill
    ao = np.clip(0.55 + 0.45 * (p[:, 1:2] / 1.2), 0.55, 1.0) * (0.75 + 0.25 * np.clip(n[:, 1:2] + 0.3, 0, 1))
    fill = (0.42 + 0.3 * np.clip(n[:, 1:2], 0, 1)) * ao
    D = (1 - metal) * (ndl * 1.05 + fill * 1.15)                      # × base colour
    a2 = np.maximum(rough ** 2, 0.004) ** 2
    Dg = a2 / (math.pi * (ndh ** 2 * (a2 - 1) + 1) ** 2)
    r = 2 * np.sum(n * v, 1)[:, None] * n - v
    e = env(r)
    # base layer reflection (for paint: a soft one; the clear-coat adds a sharp one)
    f0 = 0.04 * (1 - metal) + base * metal
    F = f0 + (1 - f0) * (1 - ndv) ** 5
    blur = np.clip(1 - rough * 1.6, 0, 1)
    spec_other = Dg * F * 0.25 / ndv * ndl * 1.6 + e * F * (0.15 + 0.85 * blur) * ao
    Fc = 0.04 + 0.96 * (1 - ndv) ** 5
    a2c = 0.06 ** 4
    Dc = a2c / (math.pi * (ndh ** 2 * (a2c - 1) + 1) ** 2)
    clear = (np.minimum(Dc * 0.25 / ndv, 40) * 0.04 * ndl + e * Fc * 1.1) * ao
    K_body = clear + Dg * 0.04 * 0.25 / ndv * ndl  # colour-independent part of paint

    # pixels
    col_other = base * D + spec_other + emis
    out_rgb = np.zeros((S_h, S_w, 3)); out_rgb[hit] = srgb(tone(col_other))
    Dmap = np.zeros((S_h, S_w)); Kmap = np.zeros((S_h, S_w, 3))
    Dmap[hit] = D[:, 0]
    Kmap[hit] = K_body
    return dict(S_w=S_w, S_h=S_h, hit=hit, body=is_body, rgb=out_rgb, D=Dmap, K=Kmap.mean(axis=2))


def downsample(a, f):
    h, w = a.shape[:2]
    return a.reshape(h // f, f, w // f, f, *a.shape[2:]).mean(axis=(1, 3))


def build(glb, out_dir, preview=None):
    L = render_layers(load_glb(glb))
    hit, body = L["hit"].astype(float), L["body"].astype(float)
    other = hit * (1 - body)
    # supersampled → master
    cov_other = downsample(other, SS)
    cov_body = downsample(body, SS)
    cov_car = downsample(hit, SS)
    rgb_other = downsample(L["rgb"] * other[..., None], SS) / np.maximum(cov_other[..., None], 1e-6)
    Dm = downsample(L["D"] * body, SS) / np.maximum(cov_body, 1e-6)
    Km = downsample(L["K"] * body, SS) / np.maximum(cov_body, 1e-6)

    car_mask = Image.fromarray((cov_car * 255).astype(np.uint8))
    # soft contact shadow (offset a little towards the bottom-right, away from the key light)
    sh = car_mask.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(9))
    sh = np.array(sh.transform(sh.size, Image.AFFINE, (1, 0, -3, 0, 1, -6))) / 255.0 * 0.55
    # light outline: the silhouette grown ~2.5 px at master size, softened a touch
    ol = np.array(car_mask.filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.GaussianBlur(1.0))) / 255.0 * 0.92
    outline_rgb = np.array([0.97, 0.97, 0.95])

    # base = shadow, then outline over it, then non-paint parts; paint pixels are cut out
    a_sh = sh
    rgb = np.zeros(cov_car.shape + (3,))
    a = a_sh.copy()
    a_ol = ol
    rgb = (rgb * a[..., None] * (1 - a_ol[..., None]) + outline_rgb * a_ol[..., None])
    a = a_ol + a * (1 - a_ol)
    rgb = rgb / np.maximum(a[..., None], 1e-6)
    # the car's own pixels (body + other) replace the outline/shadow beneath them
    rgb = rgb_other * cov_other[..., None] + rgb * (a * (1 - cov_car))[..., None]
    a = cov_other + a * (1 - cov_car)
    rgb = rgb / np.maximum(a[..., None], 1e-6)
    base_img = np.dstack([np.clip(rgb, 0, 1), np.clip(a, 0, 1)])
    body_img = np.dstack([srgb(np.clip(Dm, 0, 1)), srgb(np.clip(Km, 0, 1)), np.clip(cov_body, 0, 1)])

    os.makedirs(out_dir, exist_ok=True)
    Image.fromarray((base_img * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(out_dir, "CarIconBase.png"), optimize=True)
    Image.fromarray((body_img * 255 + 0.5).astype(np.uint8), "RGB").save(os.path.join(out_dir, "CarIconBody.png"), optimize=True)
    return base_img, body_img


def decode(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def compose(base_img, body_img, hexs):
    """Same maths as CarIcon.swift."""
    rgb = np.array([int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4)])
    lin = decode(rgb)
    D, K, m = decode(body_img[..., 0]), decode(body_img[..., 1]), body_img[..., 2]
    paint = srgb(tone(lin * D[..., None] + K[..., None]))
    a = m + base_img[..., 3] * (1 - m)
    out = (paint * m[..., None] + base_img[..., :3] * (base_img[..., 3] * (1 - m))[..., None]) / np.maximum(a[..., None], 1e-6)
    return np.dstack([out, a])


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("glb"); ap.add_argument("out_dir"); ap.add_argument("--preview")
    a = ap.parse_args()
    b, d = build(a.glb, a.out_dir)
    if a.preview:
        os.makedirs(a.preview, exist_ok=True)
        for c in ["E8EEF0", "D6452F", "2F6FD6", "F2B630", "2FA56A", "8A4FD1", "F07F2F", "1FB8C4", "E05A9C", "15191C"]:
            img = compose(b, d, c)
            Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(a.preview, f"icon-{c}.png"))
    print("ok", b.shape)
