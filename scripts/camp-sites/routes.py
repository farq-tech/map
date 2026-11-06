"""«مخطط دروب البر»: the off-road cost grid (bundled in the app) and a reference router.

The app (Sources/Explore/CampSites/DesertRouter.swift) runs the same A* on the device, offline,
over the bundled grid; this module builds that grid and mirrors the router so the rules can be
tested here and an illustration rendered (render_routes.py).

Grid file `routes-<region>.bin` (zlib):  b"SARYRT1\\0" | header JSON length (u32 LE) | header JSON |
  per cell, row-major from the north-west, 4 bytes:
    [0] class (low nibble) | track bit 0x10 | paved-road bit 0x20 | big-wadi bit 0x40
    [1] dune-ridge axis in degrees 0..179 (compass bearing of the crest line), 255 = no clear ridges
    [2..3] elevation, u16 LE, (z - z0) * 4  (quarter metres)

Usage: python -I routes.py <region> <cache_dir> <out_dir>
"""
import heapq
import json
import math
import os
import struct
import sys
import zlib

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model as M  # noqa: E402
from regions import ANALYSIS_ARCSEC, REGIONS, ROUTE_ARCSEC  # noqa: E402

FIRM, SAND, CREST, SABKHA, WADI, FORBIDDEN, ROCK = 0, 1, 2, 3, 4, 5, 6
CLASS_NAMES = {FIRM: "firm", SAND: "sand", CREST: "crest", SABKHA: "sabkha", WADI: "wadi", FORBIDDEN: "forbidden", ROCK: "rock"}
TRACK, ROAD, BIGWADI = 0x10, 0x20, 0x40
BIG_WADI_KM2 = 5.0       # a wadi this big is refused when rain is forecast (flash floods)

# Effort per metre by ground (the explainable table) and the speed assumed on it (km/h).
EFFORT = {FIRM: 1.0, SAND: 1.7, CREST: 4.5, SABKHA: 9.0, WADI: 2.5, ROCK: 6.0}
SPEED = {FIRM: 35, SAND: 18, CREST: 7, SABKHA: 10, WADI: 20, ROCK: 6}
TRACK_EFFORT, TRACK_SPEED = 0.45, 40
ROAD_EFFORT, ROAD_SPEED = 0.35, 70
MAX_GRADE = 0.32         # steeper along the move is refused («نزلة قوية»)
HARD_GRADE = 0.15        # above this a segment is flagged
CREST_SLOPE_PCT = 14.0   # sand steeper than this is a dune face / crest («طعس»)
ROCK_SLOPE_PCT = 25.0

REASON_AR = {
    "crest": "طعس قوي", "against": "طعس عكس العرق", "sabkha": "سبخة", "wadi": "بطن وادي",
    "down": "نزلة قوية", "up": "طلعة قوية", "rock": "منحدر صخري",
}


def ridge_axis(dem, dx, dy, sand, sigma_cells=8):
    """Dune-ridge orientation from the DEM's structure tensor: the dominant gradient direction
    over ~1 km; the crest line runs across it. Returns (axis bearing 0..180 deg, coherence 0..1)."""
    gn, ge = np.gradient(dem, dy, dx)  # rows run south: d/drow = -d/dnorth
    gn = -gn
    jxx = ndimage.gaussian_filter(ge * ge, sigma_cells)
    jyy = ndimage.gaussian_filter(gn * gn, sigma_cells)
    jxy = ndimage.gaussian_filter(ge * gn, sigma_cells)
    # Angle of the dominant gradient from east, counter-clockwise.
    phi = 0.5 * np.arctan2(2 * jxy, jxx - jyy)
    grad_bearing = (90 - np.degrees(phi)) % 180
    axis = (grad_bearing + 90) % 180
    l1 = 0.5 * (jxx + jyy) + np.sqrt(0.25 * (jxx - jyy) ** 2 + jxy ** 2)
    l2 = 0.5 * (jxx + jyy) - np.sqrt(0.25 * (jxx - jyy) ** 2 + jxy ** 2)
    coh = (l1 - l2) / (l1 + l2 + 1e-9)
    coh = np.where(sand, coh, 0)
    return axis, coh


def grid_from_layers(region, cache):
    Ly = np.load(os.path.join(cache, region, "layers.npz"))
    s, w, n, e = REGIONS[region]["bbox"]
    dem2 = Ly["dem"].astype("float64")
    dx2, dy2 = M.cell_size_m((s + n) / 2, ANALYSIS_ARCSEC)
    slope2 = Ly["slope"]
    sand2 = Ly["sand"]
    cls2 = np.full(dem2.shape, FIRM, "uint8")
    cls2[sand2] = SAND
    cls2[sand2 & (slope2 > CREST_SLOPE_PCT)] = CREST
    cls2[(~sand2) & (slope2 > ROCK_SLOPE_PCT)] = ROCK
    ch = Ly["channel"]
    cls2[ndimage.binary_dilation(ch, iterations=1)] = WADI
    big2 = ndimage.binary_dilation(ch & (Ly["acc"] >= BIG_WADI_KM2), iterations=2)
    cls2[Ly["sabkha"]] = SABKHA
    cls2[Ly["military"] | Ly["water"] | Ly["built"]] = FORBIDDEN
    axis2, coh2 = ridge_axis(dem2, dx2, dy2, sand2)
    track2 = Ly["d_track"] < 45
    road2 = Ly["d_road"] < 45

    f = ANALYSIS_ARCSEC / ROUTE_ARCSEC
    rows, cols = int(round(dem2.shape[0] * f)), int(round(dem2.shape[1] * f))
    zf = (rows / dem2.shape[0], cols / dem2.shape[1])
    # Hazards must not vanish when coarsening: worst class in the 2x2 neighbourhood first.
    prio = np.array([0, 1, 3, 5, 4, 6, 2], "uint8")  # rank per class: forbidden > sabkha > wadi > crest > rock > sand > firm
    inv = np.argsort(prio)
    worst = ndimage.maximum_filter(prio[cls2], size=2)
    cls = inv[ndimage.zoom(worst, zf, order=0)].astype("uint8")
    track = ndimage.zoom(ndimage.maximum_filter(track2.astype("uint8"), size=2), zf, order=0).astype(bool)
    road = ndimage.zoom(ndimage.maximum_filter(road2.astype("uint8"), size=2), zf, order=0).astype(bool)
    big = ndimage.zoom(ndimage.maximum_filter(big2.astype("uint8"), size=2), zf, order=0).astype(bool)
    dem = ndimage.zoom(dem2, zf, order=1)
    axis = ndimage.zoom(axis2, zf, order=0)
    coh = ndimage.zoom(coh2, zf, order=1)
    ridge = np.where(coh >= 0.35, np.round(axis) % 180, 255).astype("uint8")
    # A track across a wadi or crest is still the way people drive; never across forbidden ground.
    track &= cls != FORBIDDEN
    road &= cls != FORBIDDEN
    return {"cls": cls, "track": track, "road": road, "big": big, "dem": dem, "ridge": ridge, "coh": coh, "bbox": (s, w, n, e)}


def write_bin(g, path, region):
    rows, cols = g["cls"].shape
    z0 = float(np.floor(g["dem"].min()))
    elev = np.clip(np.round((g["dem"] - z0) * 4), 0, 65535).astype("<u2")
    b0 = g["cls"] | (g["track"] * TRACK).astype("uint8") | (g["road"] * ROAD).astype("uint8") | (g["big"] * BIGWADI).astype("uint8")
    cells = np.empty((rows, cols, 4), "uint8")
    cells[..., 0] = b0
    cells[..., 1] = g["ridge"]
    cells[..., 2:4] = elev.view("uint8").reshape(rows, cols, 2)
    s, w, n, e = g["bbox"]
    header = json.dumps({"region": region, "rows": rows, "cols": cols, "south": s, "west": w, "north": n, "east": e,
                         "arcsec": ROUTE_ARCSEC, "z0": z0, "version": 1}).encode()
    raw = b"SARYRT1\0" + struct.pack("<I", len(header)) + header + cells.tobytes()
    with open(path, "wb") as f:
        f.write(zlib.compress(raw, 9))
    return len(raw)


# ---- reference router (mirrors DesertRouter.swift) ------------------------------------------

MODES = ("easy", "short", "balanced")


def cell_effort(cls, flags, ridge, bearing, grade, rain):
    """Cost multiplier per metre of moving INTO a cell, and the reason it is hard (or None).
    Returns (None, reason) for a refused move."""
    if cls == FORBIDDEN:
        return None, "forbidden"
    if flags & BIGWADI and rain and not flags & ROAD:
        return None, "wadi"
    if abs(grade) > MAX_GRADE and not flags & (TRACK | ROAD):
        return None, "down" if grade < 0 else "up"
    if flags & ROAD:
        base, reason = ROAD_EFFORT, None
    elif flags & TRACK:
        base, reason = TRACK_EFFORT, None
    else:
        base = EFFORT[cls] * (3.0 if rain and cls == WADI else 1.0)
        reason = {CREST: "crest", SABKHA: "sabkha", WADI: "wadi", ROCK: "rock"}.get(cls)
        if cls in (SAND, CREST) and ridge != 255:
            cross = abs(math.sin(math.radians(bearing - ridge)))
            base *= 1 + 1.6 * cross
            if cross > 0.75 and reason is None:
                reason = "against"
    g = abs(grade)
    base *= 1 + (g / 0.10) ** 2
    if g > HARD_GRADE and reason is None:
        reason = "down" if grade < 0 else "up"
    return base, reason


def step_cost(mode, effort, dist):
    if mode == "short":
        return dist
    if mode == "balanced":
        return dist * math.sqrt(effort)
    return dist * effort


class Grid:
    def __init__(self, g):
        self.cls, self.dem, self.ridge = g["cls"], g["dem"], g["ridge"]
        self.flags = (g["track"] * TRACK | g["road"] * ROAD | g.get("big", np.zeros_like(g["track"])) * BIGWADI).astype("uint8")
        self.rows, self.cols = self.cls.shape
        s, w, n, e = g["bbox"]
        self.bbox = g["bbox"]
        self.dx, self.dy = M.cell_size_m((s + n) / 2, ROUTE_ARCSEC)

    def rc(self, lat, lng):
        s, w, n, e = self.bbox
        r = int((n - lat) / (n - s) * self.rows)
        c = int((lng - w) / (e - w) * self.cols)
        return min(max(r, 0), self.rows - 1), min(max(c, 0), self.cols - 1)

    def latlng(self, r, c):
        s, w, n, e = self.bbox
        return n - (r + 0.5) * (n - s) / self.rows, w + (c + 0.5) * (e - w) / self.cols


NB = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]


def route(G, a, b, mode, rain=False, max_expand=3_000_000):
    """A* from cell a to cell b. Returns the list of cells, or None."""
    rows, cols = G.rows, G.cols
    ar, ac = a
    br, bc = b
    best = {a: 0.0}
    prev = {}
    floor = {"short": 1.0, "balanced": math.sqrt(min(TRACK_EFFORT, ROAD_EFFORT)), "easy": min(TRACK_EFFORT, ROAD_EFFORT)}[mode]

    def h(r, c):
        return floor * math.hypot((r - br) * G.dy, (c - bc) * G.dx)

    heap = [(h(ar, ac), 0.0, ar, ac)]
    n = 0
    while heap:
        f, g, r, c = heapq.heappop(heap)
        if (r, c) == b:
            path = [b]
            while path[-1] in prev:
                path.append(prev[path[-1]])
            return path[::-1]
        if g > best.get((r, c), 1e18):
            continue
        n += 1
        if n > max_expand:
            return None
        for dr, dc in NB:
            rr, cc = r + dr, c + dc
            if not (0 <= rr < rows and 0 <= cc < cols):
                continue
            dist = math.hypot(dr * G.dy, dc * G.dx)
            bearing = math.degrees(math.atan2(dc * G.dx, -dr * G.dy)) % 360
            grade = (float(G.dem[rr, cc]) - float(G.dem[r, c])) / dist
            eff, _ = cell_effort(int(G.cls[rr, cc]), int(G.flags[rr, cc]), int(G.ridge[rr, cc]), bearing, grade, rain)
            if eff is None:
                continue
            ng = g + step_cost(mode, eff, dist)
            if ng < best.get((rr, cc), 1e18):
                best[(rr, cc)] = ng
                prev[(rr, cc)] = (r, c)
                heapq.heappush(heap, (ng + h(rr, cc), ng, rr, cc))
    return None


def summarize(G, path, rain=False):
    """Distance, time, share on a known track, and the hard stretches with their reasons."""
    dist = time_h = on_track = 0.0
    hard = []
    cur = None
    for (r, c), (rr, cc) in zip(path, path[1:]):
        d = math.hypot((rr - r) * G.dy, (cc - c) * G.dx)
        bearing = math.degrees(math.atan2((cc - c) * G.dx, -(rr - r) * G.dy)) % 360
        grade = (float(G.dem[rr, cc]) - float(G.dem[r, c])) / d
        cls, fl = int(G.cls[rr, cc]), int(G.flags[rr, cc])
        _, reason = cell_effort(cls, fl, int(G.ridge[rr, cc]), bearing, grade, rain)
        if fl & ROAD:
            v = ROAD_SPEED
        elif fl & TRACK:
            v = TRACK_SPEED
            on_track += d
        else:
            v = SPEED.get(cls, 10)
            if reason == "against":
                v *= 0.6
        dist += d
        time_h += d / 1000 / v
        if reason:
            if cur and cur["reason"] == reason and cur["end"] == (r, c):
                cur["cells"].append((rr, cc))
                cur["end"] = (rr, cc)
                cur["m"] += d
            else:
                cur = {"reason": reason, "cells": [(r, c), (rr, cc)], "end": (rr, cc), "m": d}
                hard.append(cur)
        else:
            cur = None
    hard = [h for h in hard if h["m"] >= 120]
    return {"distance_m": dist, "time_min": time_h * 60, "track_pct": 100 * on_track / max(dist, 1), "hard": hard}


def main(region, cache, out_dir):
    g = grid_from_layers(region, cache)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"routes-{region}.bin")
    raw = write_bin(g, path, region)
    cls, counts = np.unique(g["cls"], return_counts=True)
    print(region, g["cls"].shape, "raw", raw, "zlib", os.path.getsize(path),
          {CLASS_NAMES[int(k)]: round(float(v) / g["cls"].size * 100, 1) for k, v in zip(cls, counts)},
          "track%", round(float(g["track"].mean()) * 100, 2), "ridged%", round(float((g["ridge"] != 255).mean()) * 100, 1))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
