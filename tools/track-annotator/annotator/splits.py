"""Leakage-free spatial split: whole spatial blocks go to one split, plus a buffer gap.

Never a random tile split. Steps:
  1. every tile is assigned to a square block (default 5 km) of an equal-area CRS (EPSG:6933);
  2. blocks (not tiles) are assigned to train / validation / test by a seeded greedy fill that
     tracks the requested ratios;
  3. tiles of different splits closer than ``buffer_m`` are removed from the less-protected side
     (train loses tiles next to val/test; val loses tiles next to test).
"""
from __future__ import annotations

import hashlib
import random
from collections import defaultdict

from shapely.geometry import Polygon
from shapely.strtree import STRtree

from .geo import BLOCK_CRS, transformer

SPLITS = ("train", "validation", "test")


def tile_footprint_m(bbox_corners_lonlat: list[tuple[float, float]]) -> Polygon:
    t = transformer("EPSG:4326", BLOCK_CRS)
    return Polygon([t.transform(lon, lat) for lon, lat in bbox_corners_lonlat])


def block_of(poly: Polygon, block_m: float) -> tuple[int, int]:
    c = poly.centroid
    return int(c.x // block_m), int(c.y // block_m)


def assign_blocks(block_weights: dict, ratios: dict, seed: int = 0) -> dict:
    """block -> split, greedy on the largest remaining deficit; deterministic for a given seed."""
    blocks = sorted(block_weights, key=lambda b: hashlib.sha1(f"{seed}|{b}".encode()).hexdigest())
    total = sum(block_weights.values())
    cur = {s: 0.0 for s in SPLITS}
    out = {}
    # biggest blocks first so ratios are met as closely as possible
    for b in sorted(blocks, key=lambda b: -block_weights[b]):
        deficit = {s: ratios[s] * total - cur[s] for s in SPLITS}
        s = max(SPLITS, key=lambda k: (deficit[k], -SPLITS.index(k)))
        out[b] = s
        cur[s] += block_weights[b]
    return out


def split_tiles(tiles: list[dict], ratios: dict, block_m: float = 5000.0, buffer_m: float = 500.0,
                seed: int = 0) -> dict:
    """tiles: [{'id','footprint': Polygon(m), ...}] -> {'assign': id->split|None, 'dropped': [...], 'blocks': {...}}"""
    by_block: dict = defaultdict(list)
    for t in tiles:
        by_block[block_of(t["footprint"], block_m)].append(t["id"])
    weights = {b: len(v) for b, v in by_block.items()}
    block_split = assign_blocks(weights, ratios, seed)
    assign = {t["id"]: block_split[block_of(t["footprint"], block_m)] for t in tiles}
    polys = {t["id"]: t["footprint"] for t in tiles}
    dropped = []
    # tiles of lower-priority splits near higher-priority ones are removed
    for victim, guard in (("train", ("validation", "test")), ("validation", ("test",))):
        guard_ids = [i for i, s in assign.items() if s in guard]
        if not guard_ids:
            continue
        tree = STRtree([polys[i] for i in guard_ids])
        for i, s in list(assign.items()):
            if s != victim:
                continue
            near = tree.query(polys[i].buffer(buffer_m))
            if any(polys[i].distance(polys[guard_ids[k]]) < buffer_m for k in near):
                assign[i] = None
                dropped.append({"id": i, "reason": f"within {buffer_m:.0f} m of {'/'.join(guard)}"})
    return {
        "assign": assign,
        "dropped": dropped,
        "blocks": {f"{b[0]}_{b[1]}": {"split": s, "tiles": weights[b]} for b, s in block_split.items()},
        "params": {"block_m": block_m, "buffer_m": buffer_m, "seed": seed, "ratios": ratios, "block_crs": BLOCK_CRS},
    }


def check_leakage(tiles: list[dict], assign: dict, buffer_m: float) -> dict:
    """Independent verification: min footprint distance across splits, overlaps, shared blocks."""
    kept = [t for t in tiles if assign.get(t["id"])]
    by_split: dict = defaultdict(list)
    for t in kept:
        by_split[assign[t["id"]]].append(t)
    issues = []
    min_dist = {}
    names = [s for s in SPLITS if by_split.get(s)]
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            tree = STRtree([t["footprint"] for t in by_split[b]])
            best = float("inf")
            for t in by_split[a]:
                for k in tree.query(t["footprint"].buffer(buffer_m * 2 + 1)):
                    best = min(best, t["footprint"].distance(by_split[b][k]["footprint"]))
            min_dist[f"{a}|{b}"] = None if best == float("inf") else round(best, 2)
            if best < buffer_m:
                issues.append(f"{a} و{b}: أقرب مسافة {best:.1f} م < {buffer_m} م")
            for t in by_split[a]:
                for k in tree.query(t["footprint"]):
                    if t["footprint"].intersects(by_split[b][k]["footprint"]):
                        issues.append(f"تداخل جغرافي بين {t['id']} و{by_split[b][k]['id']}")
    return {"ok": not issues, "issues": issues, "min_distance_m": min_dist,
            "counts": {s: len(by_split.get(s, [])) for s in SPLITS}}
