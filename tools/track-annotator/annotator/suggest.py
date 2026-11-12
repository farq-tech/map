"""Pre-annotation: model-suggested track lines the owner accepts / deletes / fixes.

Backends (auto picks the first available):
  sam_road  the SpaceNet-trained SAM-Road checkpoint from the research folder, run LOCALLY (MPS/CPU)
            in the research ``.venv-sam``. Out of domain for desert tracks (measured earlier: ~12 % coverage,
            ~66 % precision on Mapbox z17) -> suggestions are a starting point, not truth.
  ridge     classical Sato/Meijering ridge filter (TRACKS-EXPERIMENTS.md found these at random level
            for AUTOMATIC detection; as a drawing aid they still save clicks). Always available.

Output ``suggestions.geojson`` (WGS84, provenance ``model_suggested``, per-line confidence). It is never
edited afterwards, so the original model output stays available next to the owner's final ``tracks.geojson``.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from shapely.geometry import LineString, MultiLineString
from shapely.ops import linemerge, unary_union

from . import config, export, store
from .geo import Grid, utm_crs_for

RESEARCH_ROOT = Path(os.environ.get(
    "SAM_ROAD_ROOT", "~/farq-map/research/sary-albarq-road-extraction")).expanduser()
GSD = 1.0  # metres per pixel fed to the models (SAM-Road's training scale)
MIN_LINE_M = 30.0


def _sam_paths():
    return (RESEARCH_ROOT / ".venv-sam/bin/python", RESEARCH_ROOT / "data/spacenet_vitb_256_e10.ckpt",
            RESEARCH_ROOT / "vendor/sam_road/sam_ckpts/sam_vit_b_01ec64.pth")


def available_backends() -> dict:
    py, ck, sam = _sam_paths()
    return {"sam_road": py.is_file() and ck.is_file() and sam.is_file(), "ridge": True}


def _prepare(sample_id: str):
    meta = store.read_metadata(sample_id)
    grid = store.grid_of(meta)
    rgb = store.read_rgb(sample_id)
    lon, lat = grid.centre_lonlat()
    urgb, valid, ugrid = export.warp_to_utm(rgb, grid, GSD, utm_crs_for(lon, lat))
    return meta, urgb, valid, ugrid


# --------------------------------------------------------------------- vectorising
def _pixel_lines_to_lonlat(lines_px: list[tuple[np.ndarray, float]], ugrid: Grid) -> list[dict]:
    feats = []
    for k, (xy, conf) in enumerate(lines_px):
        lon, lat = ugrid.pixel_to_lonlat(xy[:, 0] + 0.5, xy[:, 1] + 0.5)
        coords = [[round(float(a), 9), round(float(b), 9)] for a, b in zip(lon, lat)]
        length = float(np.sum(np.hypot(*np.diff(xy, axis=0).T))) * GSD
        feats.append({"type": "Feature",
                      "properties": {"id": f"sg{k:03d}", "kind": "centerline", "source": "model_suggested",
                                     "confidence": round(float(conf), 3), "length_m": round(length, 1)},
                      "geometry": {"type": "LineString", "coordinates": coords}})
    return feats


def _skeleton_to_lines(skel: np.ndarray, score: np.ndarray) -> list[tuple[np.ndarray, float]]:
    """Trace a 1-px skeleton into polylines between junction/end pixels (8-neighbourhood)."""
    import networkx as nx
    ys, xs = np.nonzero(skel)
    pts = set(zip(xs.tolist(), ys.tolist()))
    g = nx.Graph()
    for x, y in pts:
        for dx, dy in ((1, 0), (0, 1), (1, 1), (1, -1)):
            if (x + dx, y + dy) in pts:
                g.add_edge((x, y), (x + dx, y + dy))
    lines = []
    seen = set()
    key = {n for n in g if g.degree(n) != 2}
    for comp in nx.connected_components(g):
        sub = g.subgraph(comp)
        starts = [n for n in sub if n in key] or [next(iter(sub))]
        for s in starts:
            for nb in sub.neighbors(s):
                if (s, nb) in seen:
                    continue
                path = [s, nb]
                seen.add((s, nb)); seen.add((nb, s))
                while path[-1] not in key and path[-1] != s:
                    nxt = [n for n in sub.neighbors(path[-1]) if n != path[-2]]
                    if not nxt:
                        break
                    seen.add((path[-1], nxt[0])); seen.add((nxt[0], path[-1]))
                    path.append(nxt[0])
                a = np.array(path, float)
                if len(a) >= 3:
                    lines.append(a)
    out = []
    for a in lines:
        a = _smooth_simplify(a)
        sc = float(np.mean(score[a[:, 1].astype(int).clip(0, score.shape[0] - 1), a[:, 0].astype(int).clip(0, score.shape[1] - 1)]))
        out.append((a, sc))
    return out


def _smooth_simplify(a: np.ndarray, tol: float = 2.0) -> np.ndarray:
    ls = LineString(a).simplify(tol)
    return np.array(ls.coords)


# --------------------------------------------------------------------- backends
def run_ridge(urgb: np.ndarray, valid: np.ndarray) -> tuple[list[tuple[np.ndarray, float]], dict]:
    from skimage.color import rgb2gray
    from skimage.filters import apply_hysteresis_threshold, meijering, sato
    from skimage.morphology import remove_small_objects, skeletonize
    g = rgb2gray(urgb)
    sig = (1.5, 2.0, 3.0)  # ~3-6 m wide tracks at 1 m/px
    r = np.maximum(sato(g, sigmas=sig, black_ridges=False), sato(g, sigmas=sig, black_ridges=True))
    r2 = meijering(g, sigmas=sig, black_ridges=False)
    resp = r / (np.percentile(r, 99.5) + 1e-9)
    resp = np.clip(0.7 * resp + 0.3 * r2 / (np.percentile(r2, 99.5) + 1e-9), 0, 1)
    resp[valid == 0] = 0
    lo, hi = np.percentile(resp[valid > 0], [95, 99.2])
    mask = apply_hysteresis_threshold(resp, lo, hi)
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        mask = remove_small_objects(mask, 60)
    skel = skeletonize(mask)
    lines = [(a, c) for a, c in _skeleton_to_lines(skel, resp)
             if float(np.sum(np.hypot(*np.diff(a, axis=0).T))) * GSD >= MIN_LINE_M]
    return lines, {"backend": "ridge", "method": "Sato+Meijering hysteresis (p95/p99.2) + skeleton", "device": "cpu"}


def run_sam_road(urgb: np.ndarray, valid: np.ndarray, device: str = "mps") -> tuple[list[tuple[np.ndarray, float]], dict]:
    py, ck, _ = _sam_paths()
    h, w = urgb.shape[:2]
    n = max(h, w)
    sq = np.zeros((n, n, 3), np.uint8)
    sq[:h, :w] = urgb
    with tempfile.TemporaryDirectory() as td:
        inp, outp = Path(td) / "in.npy", Path(td) / "out.npz"
        np.save(inp, sq)
        env = {**os.environ, "PYTORCH_ENABLE_MPS_FALLBACK": "1"}
        cmd = [str(py), str(Path(__file__).resolve().parent.parent / "scripts/sam_road_runner.py"),
               "--root", str(RESEARCH_ROOT), "--image", str(inp), "--out", str(outp), "--device", device]
        r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=1800)
        if r.returncode != 0:
            raise RuntimeError("SAM-Road فشل: " + (r.stderr or r.stdout)[-400:])
        z = np.load(outp, allow_pickle=False)
        nodes, edges, road = z["nodes_rc"], z["edges"], z["road_mask"][:h, :w].astype(np.float32) / 255.0
        info = [str(x) for x in z["meta"]]
    segs = []
    for a, b in edges:
        (r0, c0), (r1, c1) = nodes[a], nodes[b]
        if (r0, c0) != (r1, c1) and 0 <= r0 < h and 0 <= c0 < w and 0 <= r1 < h and 0 <= c1 < w:
            segs.append(LineString([(c0, r0), (c1, r1)]))
    lines = []
    if segs:
        merged = linemerge(unary_union(segs))
        parts = list(merged.geoms) if isinstance(merged, MultiLineString) else [merged]
        for p in parts:
            a = np.array(p.coords)
            if p.length * GSD < MIN_LINE_M:
                continue
            a = _smooth_simplify(a, 1.5)
            sc = float(np.mean(road[a[:, 1].astype(int).clip(0, h - 1), a[:, 0].astype(int).clip(0, w - 1)]))
            lines.append((a, sc))
    return lines, {"backend": "sam_road", "checkpoint": "spacenet_vitb_256_e10.ckpt", "checkpoint_sha256": info[0],
                   "device": info[1], "model_seconds": float(info[2]),
                   "domain_note": "SpaceNet-3 urban roads: out of domain for desert tracks"}


def suggest(sample_id: str, backend: str = "auto", device: str = "mps") -> dict:
    avail = available_backends()
    if backend == "auto":
        backend = "sam_road" if avail["sam_road"] else "ridge"
    if backend == "sam_road" and not avail["sam_road"]:
        raise RuntimeError("نقطة SAM-Road غير متاحة؛ استعمل backend=ridge")
    t0 = time.perf_counter()
    meta, urgb, valid, ugrid = _prepare(sample_id)
    lines, info = run_sam_road(urgb, valid, device) if backend == "sam_road" else run_ridge(urgb, valid)
    feats = _pixel_lines_to_lonlat(lines, ugrid)
    fc = {"type": "FeatureCollection", "sample_id": sample_id, "features": feats, **info,
          "gsd_m": GSD, "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
          "runtime_s": round(time.perf_counter() - t0, 1),
          "provenance": "model_suggested — not ground truth; original model output, never edited"}
    sdir = store.sample_dir(sample_id)
    store._write_geojson(sdir / "suggestions.geojson", fc)
    meta = store.read_metadata(sample_id)
    meta["suggestion"] = {k: fc[k] for k in ("backend", "created_utc", "runtime_s")} | {"n_lines": len(feats), "device": info.get("device")}
    meta["suggestion_state"] = {"rejected_ids": []}  # a fresh run resets the review log
    store._write_json(sdir / "metadata.json", meta)
    return fc


# --------------------------------------------------------------------- background jobs
JOBS: dict[str, dict] = {}


def start_job(sample_id: str, backend: str = "auto") -> str:
    jid = uuid.uuid4().hex[:8]
    JOBS[jid] = {"id": jid, "sample_id": sample_id, "state": "running", "started": time.time(), "backend": backend}

    def work():
        try:
            fc = suggest(sample_id, backend)
            JOBS[jid].update(state="done", n_lines=len(fc["features"]), runtime_s=fc["runtime_s"], backend=fc["backend"])
        except Exception as e:  # noqa: BLE001
            JOBS[jid].update(state="error", error=str(e)[:400])

    threading.Thread(target=work, daemon=True).start()
    return jid


def score_window(c: dict, backend: str = "ridge", allow_network: bool = False) -> dict | None:
    """Run a backend on a CANDIDATE window (no sample is created) and store model-vs-OSM disagreement.

    Only windows whose tiles are all cached are scored unless ``allow_network`` (then the daily budget applies).
    """
    from . import collect, tiles
    t = c["tiles"]
    if not allow_network and tiles.count_missing(t["z"], t["x0"], t["y0"], t["nx"], t["ny"]):
        return None
    rgb, grid = tiles.fetch_mosaic(t["z"], t["x0"], t["y0"], t["nx"], t["ny"])
    lon, lat = grid.centre_lonlat()
    urgb, valid, ugrid = export.warp_to_utm(rgb, grid, GSD, utm_crs_for(lon, lat))
    if backend == "sam_road" and available_backends()["sam_road"]:
        lines, info = run_sam_road(urgb, valid)
    else:
        lines, info = run_ridge(urgb, valid)
    sug = [f["geometry"]["coordinates"] for f in _pixel_lines_to_lonlat(lines, ugrid)]
    osm = [l["xy"] for l in c.get("osm_lines", [])]
    d = collect.disagreement(sug, osm)
    rec = {**d, "backend": info["backend"], "n_suggested": len(sug), "n_osm": len(osm),
           "scored_utc": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    collect.save_score(c["id"], rec)
    return rec
