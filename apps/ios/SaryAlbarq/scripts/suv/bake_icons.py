#!/usr/bin/env python3
"""Bake the Cycles renders of blender_suv.py into the app's car icons.

    python3 scripts/suv/bake_icons.py BLENDER_OUT Resources/CarIcon [--preview DIR]

- CarIcon-<hex>.png: each member colour, downsampled 2× (premultiplied), with a light outline
  around the car (readable on night maps) over the soft contact shadow.
- CarIconBase.png / CarIconBody.png: the layers CarIcon.paint uses for any other colour
  (from the white-paint, black-paint and paint-coverage renders), with the same outline.
"""
import argparse
import glob
import os

import numpy as np
from PIL import Image, ImageFilter

OUTLINE = np.array([0.97, 0.97, 0.95])


def load(path):
    a = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float64) / 255.0
    return a  # straight alpha, sRGB


def dec(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def enc(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def half(a):
    h, w = a.shape[:2]
    return a[: h // 2 * 2, : w // 2 * 2].reshape(h // 2, 2, w // 2, 2, *a.shape[2:]).mean(axis=(1, 3))


def premul_half(img):
    """2× downsample of a straight-alpha image, averaging premultiplied (no dark fringes)."""
    a = img[..., 3:4]
    p = half(img[..., :3] * a)
    al = half(a)
    return np.concatenate([p, al], axis=2)  # premultiplied


def car_mask(alpha):
    """The car's own pixels: opaque; the shadow catcher's shadow stays well under 0.8."""
    return np.clip((alpha - 0.8) / 0.18, 0, 1)


def outline_of(car):
    m = Image.fromarray((car * 255).astype(np.uint8))
    o = m.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(0.8))
    return np.asarray(o, dtype=np.float64) / 255.0 * 0.9


def with_outline(pm):
    """pm: premultiplied RGBA (car + shadow) → shadow, then outline, then car."""
    car = car_mask(pm[..., 3])
    ol = outline_of(car)
    car_p = pm * car[..., None]
    # contact shadow only near the car: the shadow catcher also darkens the whole floor a little
    near = Image.fromarray((car * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(10))
    fade = np.clip(np.asarray(near, dtype=np.float64) / 255.0 * 2.4, 0, 1) ** 1.5
    shadow_p = pm * (1 - car[..., None]) * fade[..., None]
    under = OUTLINE * ol[..., None]
    ua = ol
    under_rgb = under + shadow_p[..., :3] * (1 - ol[..., None])
    under_a = ua + shadow_p[..., 3] * (1 - ol)
    rgb = car_p[..., :3] + under_rgb * (1 - car[..., None])
    a = car_p[..., 3] + under_a * (1 - car)
    return np.dstack([rgb, a])


def save_premul(pm, path):
    """PNG stores straight alpha: un-premultiply."""
    a = pm[..., 3:4]
    rgb = np.where(a > 1e-4, pm[..., :3] / np.maximum(a, 1e-4), 0)
    Image.fromarray((np.dstack([np.clip(rgb, 0, 1), np.clip(a[..., 0], 0, 1)]) * 255 + 0.5).astype(np.uint8), "RGBA").save(path, optimize=True)


def bake(src, dst, preview=None):
    os.makedirs(dst, exist_ok=True)
    for f in sorted(glob.glob(os.path.join(src, "icons", "CarIcon-*.png"))):
        pm = with_outline(premul_half(load(f)))
        save_premul(pm, os.path.join(dst, os.path.basename(f)))
    W = load(os.path.join(src, "layers", "white.png"))
    B = load(os.path.join(src, "layers", "black.png"))
    M = load(os.path.join(src, "layers", "mask.png"))
    m_full = M[..., 3] * (M[..., :3].mean(axis=2) > 0.5)
    # D, K at full resolution over paint, then 2× down weighted by coverage
    D = np.clip((dec(W[..., :3]) - dec(B[..., :3])).mean(axis=2), 0, 1)
    K = np.clip(dec(B[..., :3]).mean(axis=2), 0, 1)
    m = half(m_full)
    Dh = half(D * m_full) / np.maximum(m, 1e-6)
    Kh = half(K * m_full) / np.maximum(m, 1e-6)
    base = with_outline(premul_half(B))
    # (where the paint is, CarIcon.paint covers the base by the coverage m)
    save_premul(base, os.path.join(dst, "CarIconBase.png"))
    body = np.dstack([enc(Dh), enc(Kh), np.clip(m, 0, 1)])
    Image.fromarray((body * 255 + 0.5).astype(np.uint8), "RGB").save(os.path.join(dst, "CarIconBody.png"), optimize=True)
    if preview:
        os.makedirs(preview, exist_ok=True)
        for h in ("E8EEF0", "D6452F", "2F6FD6", "15191C", "7A5C3E"):
            out = compose(base, body, h)
            save_premul(out, os.path.join(preview, f"painted-{h}.png"))


def compose(base, body, hexs):
    """Same maths as CarIcon.paint (base premultiplied)."""
    lin = dec(np.array([int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4)]))
    D, K, m = dec(body[..., 0]), dec(body[..., 1]), body[..., 2]
    paint = enc(lin * D[..., None] + K[..., None])
    rgb = paint * m[..., None] + base[..., :3] * (1 - m[..., None])
    a = m + base[..., 3] * (1 - m)
    return np.dstack([rgb, a])


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("dst"); ap.add_argument("--preview")
    a = ap.parse_args()
    bake(a.src, a.dst, a.preview)
    print("baked", sorted(os.listdir(a.dst)))
