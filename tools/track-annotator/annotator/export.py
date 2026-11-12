"""Versioned export in the SAM-Road SpaceNet layout (+ geo sidecars), spatially split.

Target (verified against the vendored repo, see README / manifest):
  htcr/sam_road @ 04b67c503f120ecff2b2dc5a2041ea6d300e306a (CVPRW 2024), `spacenet` loader:
    spacenet/RGB_1.0_meter/{id}__rgb.png        RGB tile, 400x400
    spacenet/RGB_1.0_meter/{id}__gt_graph.p     pickle: {(r,c): [(r,c), ...]} sat2graph adjacency,
                                                r = IMAGE_SIZE - y, c = x  (dataset.py coord_transform)
    spacenet/processed/road_mask_{id}.png       cv2.line width 3  (spacenet/generate_labels.py)
    spacenet/processed/keypoint_mask_{id}.png   degree != 2 nodes, radius 3
    spacenet/data_split.json                    {"train": [...], "validation": [...], "test": [...]}
  SAM-Road++ (earth-insights/samroadplus) states the same layout in its README ("refer to the sam_road repo").
"""
from __future__ import annotations

import hashlib
import json
import pickle
import shutil
from datetime import datetime, timezone
from pathlib import Path

import cv2
import networkx as nx
import numpy as np
import rasterio
from PIL import Image
from rasterio.enums import Resampling
from rasterio.transform import Affine
from rasterio.warp import calculate_default_transform, reproject
from shapely.geometry import LineString, MultiLineString, box
from shapely.ops import substring, unary_union

from . import __version__, collect, config, rasterize, splits, store
from .geo import Grid, utm_crs_for

SAM_ROAD_TARGET = {
    "repo": "https://github.com/htcr/sam_road",
    "commit": "04b67c503f120ecff2b2dc5a2041ea6d300e306a",
    "commit_date": "2024-08-10",
    "layout": "spacenet",
    "evidence": ["vendor/sam_road/README.md (Data Preparation)", "dataset.py: SatMapDataset spacenet branch",
                 "spacenet/generate_labels.py (IMAGE_SIZE=400, KEYPOINT_RADIUS=3, ROAD_WIDTH=3)",
                 "config/toponet_vitb_256_spacenet.yaml"],
    "also_compatible_with": "SAM-Road++ (README: data prep 'refer to the sam_road repo'); not run here",
}
IMAGE_SIZE = 400
KEYPOINT_RADIUS = 3
ROAD_WIDTH = 3


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# --------------------------------------------------------------- resampling to a metric grid
def warp_to_utm(rgb: np.ndarray, grid: Grid, gsd: float, utm: str) -> tuple[np.ndarray, np.ndarray, Grid]:
    """Reproject (H,W,3) uint8 to ``utm`` at exactly ``gsd`` m/px. Returns (rgb, valid_mask, grid)."""
    x0, y0, x1, y1 = grid.bounds_native()
    t, w, h = calculate_default_transform(grid.crs, utm, grid.width, grid.height, x0, y0, x1, y1,
                                          resolution=gsd)
    # snap origin to the gsd lattice so tiles from neighbouring samples line up
    t = Affine(gsd, 0, np.floor(t.c / gsd) * gsd, 0, -gsd, np.ceil(t.f / gsd) * gsd)
    w, h = int(w) + 1, int(h) + 1
    out = np.zeros((h, w, 3), np.uint8)
    res = Resampling.average if gsd > grid.ground_res_m() * 1.2 else Resampling.bilinear
    for b in range(3):
        reproject(rgb[..., b], out[..., b], src_transform=grid.transform, src_crs=grid.crs,
                  dst_transform=t, dst_crs=utm, resampling=res)
    valid = np.zeros((h, w), np.uint8)
    reproject(np.ones((grid.height, grid.width), np.uint8), valid, src_transform=grid.transform, src_crs=grid.crs,
              dst_transform=t, dst_crs=utm, resampling=Resampling.nearest)
    return out, valid, Grid(utm, t, w, h)


def tile_origins(n: int, size: int, stride: int) -> list[int]:
    if n < size:
        return []
    pos = list(range(0, n - size + 1, stride))
    # edge-snapped extra tile only if a meaningful strip (>= 25 % of a tile) would be left uncovered
    if n - (pos[-1] + size) >= size // 4:
        pos.append(n - size)
    return pos


# --------------------------------------------------------------- graph
def build_graph(fc: dict, tgrid: Grid) -> dict:
    """Centrelines -> sat2graph adjacency in SAM-Road SpaceNet coordinates, clipped to the tile."""
    T = tgrid.width
    clip = box(0, 0, T - 1, T - 1)
    lines = []
    for f in rasterize.centerline_features(fc):
        col, row = tgrid.lonlat_to_pixel([c[0] for c in f["geometry"]["coordinates"]],
                                         [c[1] for c in f["geometry"]["coordinates"]])
        ls = LineString(np.stack([col, row], 1))
        inter = ls.intersection(clip)
        if inter.is_empty:
            continue
        parts = [inter] if inter.geom_type == "LineString" else [g for g in getattr(inter, "geoms", []) if g.geom_type == "LineString"]
        lines += [p for p in parts if p.length > 0]
    if not lines:
        return {}
    noded = unary_union(lines)  # splits at crossings so intersections become graph nodes
    segs = [noded] if noded.geom_type == "LineString" else list(noded.geoms)
    adj: dict = {}
    for s in segs:
        # floor, not round: cv2 paints pixel *index* i whose centre is i+0.5, so floor() minimises the half-pixel bias
        pts = [(int(np.floor(x + 1e-6)), int(np.floor(y + 1e-6))) for x, y in s.coords]
        for a, b in zip(pts[:-1], pts[1:]):
            if a == b:
                continue
            na, nb = (T - a[1], a[0]), (T - b[1], b[0])  # (r, c) with r = T - y
            adj.setdefault(na, [])
            adj.setdefault(nb, [])
            if nb not in adj[na]:
                adj[na].append(nb)
            if na not in adj[nb]:
                adj[nb].append(na)
    return adj


def graph_masks(adj: dict, size: int = IMAGE_SIZE) -> tuple[np.ndarray, np.ndarray]:
    """Exactly generate_labels.py: key nodes (degree != 2) radius 3, edges width 3."""
    g = nx.Graph()
    for n, neis in adj.items():
        for nei in neis:
            g.add_edge((int(n[1]), size - int(n[0])), (int(nei[1]), size - int(nei[0])))
    key = [n for n, d in g.degree() if d != 2]
    kp = np.zeros((size, size), np.uint8)
    for p in key:
        cv2.circle(kp, p, KEYPOINT_RADIUS, 255, -1)
    road = np.zeros((size, size), np.uint8)
    for (x1, y1), (x2, y2) in g.edges():
        cv2.line(road, (x1, y1), (x2, y2), 255, ROAD_WIDTH)
    return kp, road


def _clip_fc(fc: dict, tgrid: Grid) -> dict:
    """Tracks clipped to the tile, back in WGS84 (sidecar for audit)."""
    tb = box(0, 0, tgrid.width, tgrid.height)
    feats = []
    for f in fc["features"]:
        col, row = tgrid.lonlat_to_pixel([c[0] for c in f["geometry"]["coordinates"]],
                                         [c[1] for c in f["geometry"]["coordinates"]])
        inter = LineString(np.stack([col, row], 1)).intersection(tb)
        parts = [inter] if inter.geom_type == "LineString" else [g for g in getattr(inter, "geoms", []) if g.geom_type == "LineString"]
        for p in parts:
            if p.is_empty or p.length == 0:
                continue
            xs, ys = zip(*p.coords)
            lon, lat = tgrid.pixel_to_lonlat(np.array(xs), np.array(ys))
            feats.append({"type": "Feature", "properties": dict(f["properties"]),
                          "geometry": {"type": "LineString", "coordinates": [[round(float(a), 9), round(float(b), 9)] for a, b in zip(lon, lat)]}})
    return {"type": "FeatureCollection", "features": feats}


# --------------------------------------------------------------- main
def run_export(gsd: float = 1.0, tile: int = IMAGE_SIZE, stride: int | None = None, include_fixtures: bool = False,
               keep_empty: bool = False, seed: int = 0, block_km: float = 5.0, buffer_m: float = 500.0,
               out_root: Path | None = None, label: str | None = None) -> Path:
    tg = collect.load_targets()
    ratios = tg["split"]
    stride = stride or tile
    samples = [m for m in store.list_samples(include_fixtures=include_fixtures)
               if (m.get("annotation") or {}).get("n_tracks")]
    if not samples:
        raise ValueError("لا توجد عينات موسومة للتصدير")
    # ---- 1. tile everything in memory-light fashion, collect candidates
    cand = []  # dicts with arrays
    for m in samples:
        sid = m["sample_id"]
        grid = store.grid_of(m)
        fc = store.read_tracks(sid)
        rgb = store.read_rgb(sid)
        lon, lat = grid.centre_lonlat()
        utm = utm_crs_for(lon, lat)
        urgb, valid, ugrid = warp_to_utm(rgb, grid, gsd, utm)
        for ri, r in enumerate(tile_origins(ugrid.height, tile, stride)):
            for ci, c in enumerate(tile_origins(ugrid.width, tile, stride)):
                if valid[r:r + tile, c:c + tile].mean() < 0.98:
                    continue
                tt = ugrid.transform @ Affine.translation(c, r)
                tgrid = Grid(utm, tt, tile, tile)
                corners = tgrid.corners_lonlat()
                cand.append({"id": f"{sid}_r{ri:02d}c{ci:02d}", "sample_id": sid, "row": r, "col": c,
                             "grid": tgrid, "fc": fc, "rgb": urgb[r:r + tile, c:c + tile].copy(),
                             "footprint": splits.tile_footprint_m(corners), "meta": m})
    # ---- 2. graphs / masks, drop empty
    kept, empty = [], []
    for t in cand:
        adj = build_graph(t["fc"], t["grid"])
        if not adj and not keep_empty:
            empty.append(t["id"])
            continue
        t["adj"] = adj
        kept.append(t)
    if not kept:
        raise ValueError("كل البلاطات فارغة (لا مسار داخلها)")
    # ---- 3. spatial split
    sp = splits.split_tiles(kept, ratios, block_m=block_km * 1000.0, buffer_m=buffer_m, seed=seed)
    leak = splits.check_leakage(kept, sp["assign"], buffer_m)
    # ---- 4. write
    inputs_hash = hashlib.sha256(json.dumps(
        [(m["sample_id"], m["image_sha256"], m["annotation"]["tracks_sha256"]) for m in samples]
        + [gsd, tile, stride, seed, block_km, buffer_m, keep_empty], sort_keys=True).encode()).hexdigest()
    version = label or f"v{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{inputs_hash[:8]}"
    root = (out_root or config.EXPORT_DIR) / version
    if root.exists():
        raise FileExistsError(f"الإصدار موجود: {root}")
    rgb_dir = root / "spacenet" / f"RGB_{gsd:.1f}_meter"
    proc_dir = root / "spacenet" / "processed"
    ext = root / "extras"
    for d in (rgb_dir, proc_dir, ext):
        d.mkdir(parents=True, exist_ok=True)
    split_ids: dict = {s: [] for s in splits.SPLITS}
    records = []
    for t in kept:
        s = sp["assign"][t["id"]]
        if s is None:
            continue
        tid = t["id"]
        Image.fromarray(t["rgb"]).save(rgb_dir / f"{tid}__rgb.png")
        with open(rgb_dir / f"{tid}__gt_graph.p", "wb") as fh:
            pickle.dump(t["adj"], fh, protocol=4)
        kp, road = graph_masks(t["adj"], tile)
        cv2.imwrite(str(proc_dir / f"keypoint_mask_{tid}.png"), kp)
        cv2.imwrite(str(proc_dir / f"road_mask_{tid}.png"), road)
        masks = rasterize.make_masks(t["grid"], t["fc"], width_m=ROAD_WIDTH * gsd)
        Image.fromarray(masks["types"]).save(ext / f"{tid}__type_mask.png")
        clipped = _clip_fc(t["fc"], t["grid"])
        (ext / f"{tid}__tracks.geojson").write_text(json.dumps(clipped))
        geo = {**t["grid"].to_dict(), "bbox_wgs84": list(t["grid"].bbox_wgs84()), "gsd_m": gsd,
               "sample_id": t["sample_id"], "pixel_offset_in_sample_warp": [t["col"], t["row"]], "split": s}
        (ext / f"{tid}__geo.json").write_text(json.dumps(geo))
        split_ids[s].append(tid)
        types = sorted({f["properties"]["track_type"] for f in rasterize.centerline_features(clipped)})
        records.append({"id": tid, "sample_id": t["sample_id"], "split": s, "types": types,
                        "terrain": t["meta"].get("terrain"), "clarity": t["meta"].get("clarity"),
                        "region_cell": t["meta"]["region_cell"], "centre_wgs84": list(t["grid"].centre_lonlat()),
                        "mask_coverage": round(float((road > 0).mean()), 6), "n_nodes": len(t["adj"])})
    (root / "spacenet" / "data_split.json").write_text(json.dumps({k: sorted(v) for k, v in split_ids.items()}, indent=1))
    manifest = {
        "export_version": version,
        "created_utc": _now(),
        "tool": f"track-annotator {__version__}",
        "target": SAM_ROAD_TARGET,
        "params": {"gsd_m": gsd, "tile_px": tile, "stride_px": stride, "road_width_px": ROAD_WIDTH,
                   "keypoint_radius_px": KEYPOINT_RADIUS, "include_fixtures": include_fixtures,
                   "keep_empty": keep_empty, "seed": seed, "block_km": block_km, "buffer_m": buffer_m,
                   "ratios": ratios, "crs": "per-tile UTM (see extras/*__geo.json); labels WGS84"},
        "inputs_sha256": inputs_hash,
        "licence": dict(config.LICENSE_NOTE),
        "sources": sorted({m["source"]["type"] for m in samples}),
        "samples": [{"sample_id": m["sample_id"], "image_sha256": m["image_sha256"],
                     "tracks_sha256": m["annotation"]["tracks_sha256"], "fixture": m.get("fixture", False),
                     "terrain": m.get("terrain")} for m in samples],
        "counts": {"samples": len(samples), "tiles_candidate": len(cand), "tiles_empty_dropped": len(empty),
                   "tiles_buffer_dropped": len(sp["dropped"]), **{f"tiles_{s}": len(v) for s, v in split_ids.items()}},
        "tiles": records,
        "split_report": {"blocks": sp["blocks"], "params": sp["params"], "buffer_dropped": sp["dropped"],
                         "empty_dropped": empty, "leakage_check": leak},
        "has_fixture_data": any(m.get("fixture") for m in samples),
    }
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    (root / "README_EXPORT.md").write_text(
        f"# {version}\n\nانسخ المجلد `spacenet/` إلى جذر مستودع sam_road (commit {SAM_ROAD_TARGET['commit'][:8]}) ثم "
        f"درّب بالإعداد `config/toponet_vitb_256_spacenet.yaml`. لا تبدأ التدريب قبل `quality_report.md` = جاهز.\n"
        f"ملاحظة: اسم المجلد `RGB_{gsd:.1f}_meter` — إن لم يكن gsd=1.0 عدّل `rgb_pattern` في dataset.py.\n")
    from . import quality
    quality.check_export(root)
    return root
