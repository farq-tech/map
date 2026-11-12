"""Data / mask quality report. Reads the files back from disk (not in-memory state).

Two separate verdicts:
  integrity    - hard checks (alignment, georeferencing, widths, graph consistency, no leakage)
  sufficiency  - is there enough, balanced data per split / type to even consider training?
``ready_for_training`` requires both and no programmatic fixture data. Nothing here trains anything.
"""
from __future__ import annotations

import json
import pickle
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image
from shapely.geometry import LineString

from . import collect, config, rasterize, store
from .geo import Grid, line_length_m, transformer, utm_crs_for, xform


def _nearest_dist_m(lon, lat, lines_lonlat: list[list]) -> np.ndarray:
    """Distance (m) from points to the nearest of the polylines, in a local UTM CRS."""
    utm = utm_crs_for(float(np.mean(lon)), float(np.mean(lat)))
    t = transformer("EPSG:4326", utm).transform
    geoms = [xform(LineString(c), "EPSG:4326", utm) for c in lines_lonlat]
    from shapely import points as shp_points
    from shapely.ops import unary_union
    u = unary_union(geoms)
    x, y = t(lon, lat)
    from shapely import distance
    return np.asarray(distance(shp_points(np.stack([x, y], 1)), u))


def _line_samples(coords, grid: Grid, step_px: float = 1.0) -> np.ndarray:
    col, row = grid.lonlat_to_pixel([c[0] for c in coords], [c[1] for c in coords])
    ls = LineString(np.stack([col, row], 1))
    n = max(2, int(ls.length / step_px))
    return np.array([ls.interpolate(d, normalized=True).coords[0] for d in np.linspace(0, 1, n)])


def median_width_px(adj: dict, road: np.ndarray, T: int) -> float | None:
    """Median rendered line width in px, measured on the mask along the graph (2*DT-1)."""
    from scipy.ndimage import distance_transform_edt
    dt = distance_transform_edt(road > 0)
    vals = []
    for n, ns in adj.items():
        for k in ns:
            (y0, x0), (y1, x1) = (T - n[0], n[1]), (T - k[0], k[1])
            m = max(2, int(np.hypot(x1 - x0, y1 - y0)))
            xs = np.clip(np.linspace(x0, x1, m).round().astype(int), 0, T - 1)
            ys = np.clip(np.linspace(y0, y1, m).round().astype(int), 0, T - 1)
            vals.extend((2 * dt[ys, xs] - 1).tolist())
    return round(float(np.median(vals)), 2) if vals else None


def roundtrip_error_px(grid: Grid, n: int = 200) -> float:
    rng = np.random.default_rng(0)
    c = rng.uniform(0, grid.width, n)
    r = rng.uniform(0, grid.height, n)
    lon, lat = grid.pixel_to_lonlat(c, r)
    c2, r2 = grid.lonlat_to_pixel(lon, lat)
    return float(max(np.abs(c2 - c).max(), np.abs(r2 - r).max()))


def alignment_stats(grid: Grid, mask: np.ndarray, fc: dict, tol_px: float = 1.0) -> dict:
    """(a) mask pixels -> geo -> distance to the drawn lines;  (b) line samples -> mask hit rate."""
    lines = [f["geometry"]["coordinates"] for f in rasterize.centerline_features(fc)]
    res = grid.ground_res_m()
    out = {"mask_pixels": int((mask > 0).sum())}
    if not lines or not out["mask_pixels"]:
        return {**out, "p95_offset_px": None, "max_offset_px": None, "line_recall": None}
    lon, lat = rasterize.mask_to_lonlat_points(grid, mask, 4000)
    d = _nearest_dist_m(lon, lat, lines) / res
    hits, tot = 0, 0
    dil = mask > 0
    # 1-px tolerance for the recall test
    from scipy.ndimage import binary_dilation
    dil = binary_dilation(dil, iterations=int(np.ceil(tol_px)))
    for c in lines:
        s = _line_samples(c, grid)
        ok = (s[:, 0] >= 0) & (s[:, 0] < grid.width) & (s[:, 1] >= 0) & (s[:, 1] < grid.height)
        s = s[ok]
        if len(s):
            hits += int(dil[s[:, 1].astype(int), s[:, 0].astype(int)].sum())
            tot += len(s)
    return {**out, "p95_offset_px": round(float(np.percentile(d, 95)), 3), "max_offset_px": round(float(d.max()), 3),
            "line_recall": round(hits / tot, 4) if tot else None}


def check_sample(sample_id: str) -> dict:
    """Quality of one annotated sample on its native grid (used by the UI and CLI)."""
    gate = collect.load_targets()["quality_gate"]
    m = store.read_metadata(sample_id)
    sdir = store.sample_dir(sample_id)
    grid = store.grid_of(m)
    fc = store.read_tracks(sample_id)
    problems = []
    img = store.read_rgb(sample_id)
    rt = roundtrip_error_px(grid)
    if rt > gate["max_roundtrip_px"]:
        problems.append(f"خطأ ذهاب/عودة بكسل↔جغرافيا {rt:.2e} px")
    if float(img.std()) < gate["min_image_std"]:
        problems.append("الصورة شبه فارغة/متجانسة")
    out = {"sample_id": sample_id, "roundtrip_px": rt, "image_std": round(float(img.std()), 2)}
    mp = sdir / "mask.png"
    if not rasterize.centerline_features(fc):
        out.update(empty=True, problems=problems + ["لا مسارات"], ok=False)
        return out
    mask = np.array(Image.open(mp))
    out["coverage"] = round(float((mask > 0).mean()), 6)
    lo, hi = gate["coverage_range"]
    if mask.max() == 0:
        problems.append("القناع فارغ")
    elif not lo <= out["coverage"] <= hi:
        problems.append(f"تغطية القناع غير معتادة {out['coverage']:.4f}")
    al = alignment_stats(grid, mask, fc, tol_px=1.0)
    out.update(al)
    if al["p95_offset_px"] is not None:
        if al["p95_offset_px"] > gate["max_p95_offset_px"] + (m["annotation"]["mask_width_m"] / grid.ground_res_m()) / 2:
            problems.append(f"انحراف القناع عن الخط p95={al['p95_offset_px']} px")
        if al["line_recall"] is not None and al["line_recall"] < gate["min_line_recall"]:
            problems.append(f"الخط لا يقع على القناع (recall={al['line_recall']})")
    # width sanity (physical): area / length
    length_px = sum(line_length_m(f["geometry"]["coordinates"]) for f in rasterize.centerline_features(fc)) / grid.ground_res_m()
    if length_px:
        out["mean_width_m"] = round(float((mask > 0).sum()) / length_px * grid.ground_res_m(), 2)
    # vertices outside the image
    outside = 0
    total = 0
    for f in fc["features"]:
        c, r = grid.lonlat_to_pixel([p[0] for p in f["geometry"]["coordinates"]], [p[1] for p in f["geometry"]["coordinates"]])
        total += len(c)
        outside += int(((c < -0.5) | (c > grid.width + 0.5) | (r < -0.5) | (r > grid.height + 0.5)).sum())
    out["vertices_outside_image"] = outside
    if outside:
        problems.append(f"{outside}/{total} نقطة خارج حدود الصورة")
    out.update(problems=problems, ok=not problems)
    return out


# ------------------------------------------------------------------------------ export
def check_export(root: Path) -> dict:
    from . import splits as sp
    root = Path(root)
    gate = collect.load_targets()["quality_gate"]
    man = json.loads((root / "manifest.json").read_text())
    gsd = man["params"]["gsd_m"]
    T = man["params"]["tile_px"]
    rgb_dir = root / "spacenet" / f"RGB_{gsd:.1f}_meter"
    proc = root / "spacenet" / "processed"
    ext = root / "extras"
    per_tile = []
    fails = defaultdict(list)
    cls_px = defaultdict(lambda: defaultdict(int))
    cls_len = defaultdict(lambda: defaultdict(float))
    cls_tiles = defaultdict(lambda: defaultdict(int))
    tiles_geom = []
    for rec in man["tiles"]:
        tid, split = rec["id"], rec["split"]
        geo = json.loads((ext / f"{tid}__geo.json").read_text())
        grid = Grid.from_dict(geo)
        fc = json.loads((ext / f"{tid}__tracks.geojson").read_text())
        img = np.array(Image.open(rgb_dir / f"{tid}__rgb.png"))
        road = np.array(Image.open(proc / f"road_mask_{tid}.png"))
        kp = np.array(Image.open(proc / f"keypoint_mask_{tid}.png"))
        tmask = np.array(Image.open(ext / f"{tid}__type_mask.png"))
        adj = pickle.load(open(rgb_dir / f"{tid}__gt_graph.p", "rb"))
        t = {"id": tid, "split": split}
        probs = []
        if img.shape != (T, T, 3) or road.shape != (T, T) or kp.shape != (T, T):
            probs.append("أحجام غير مطابقة")
        if float(img.std()) < gate["min_image_std"]:
            probs.append("صورة متجانسة/سوداء")
        if not adj:
            probs.append("رسم فارغ")
        asym = sum(1 for n, ns in adj.items() for k in ns if n not in adj.get(k, []))
        oob = sum(1 for n in adj if not (0 <= n[0] <= T and 0 <= n[1] <= T))
        if asym:
            probs.append(f"رسم غير متناظر ({asym})")
        if oob:
            probs.append(f"عقد خارج البلاطة ({oob})")
        rt = roundtrip_error_px(grid)
        if rt > gate["max_roundtrip_px"]:
            probs.append(f"ذهاب/عودة {rt:.2e}")
        t["coverage"] = round(float((road > 0).mean()), 6)
        lo, hi = gate["coverage_range"]
        if road.max() == 0:
            probs.append("قناع فارغ")
        elif not lo <= t["coverage"] <= hi:
            probs.append(f"تغطية غير معتادة {t['coverage']}")
        # width sanity: median over centreline samples of 2*DT-1 (distance transform) ~ rendered line width
        t["mean_width_px"] = median_width_px(adj, road, T)
        if t["mean_width_px"] is not None:
            wlo, whi = gate["width_px_range"]
            if not wlo <= t["mean_width_px"] <= whi:
                probs.append(f"عرض الخط {t['mean_width_px']} px خارج {wlo}-{whi}")
        if fc["features"]:
            al = alignment_stats(grid, road, fc, tol_px=1.0)
            t.update({k: al[k] for k in ("p95_offset_px", "max_offset_px", "line_recall")})
            if al["p95_offset_px"] is not None:
                if al["p95_offset_px"] > gate["max_p95_offset_px"] or al["max_offset_px"] > gate["max_offset_px"]:
                    probs.append(f"انحراف القناع p95={al['p95_offset_px']} max={al['max_offset_px']} px")
                if al["line_recall"] < gate["min_line_recall"]:
                    probs.append(f"recall الخط={al['line_recall']}")
        # class balance
        seen = set()
        for tname, idx in config.TYPE_INDEX.items():
            n = int((tmask == idx).sum())
            if n:
                cls_px[split][tname] += n
                seen.add(tname)
        for f in rasterize.centerline_features(fc):
            cls_len[split][f["properties"]["track_type"]] += line_length_m(f["geometry"]["coordinates"])
        for tname in seen:
            cls_tiles[split][tname] += 1
        t["problems"] = probs
        for p in probs:
            fails[tid].append(p)
        per_tile.append(t)
        tiles_geom.append({"id": tid, "footprint": sp.tile_footprint_m(grid.corners_lonlat())})
    # leakage again from the files on disk
    assign = {r["id"]: r["split"] for r in man["tiles"]}
    leak = sp.check_leakage(tiles_geom, assign, man["params"]["buffer_m"])
    counts = {s: sum(1 for r in man["tiles"] if r["split"] == s) for s in sp.SPLITS}
    n_blocks = len({b for b, v in man["split_report"]["blocks"].items()})
    # class balance table
    balance = {}
    flags = []
    for s in sp.SPLITS:
        tot_px = sum(cls_px[s].values()) or 1
        balance[s] = {t: {"tiles": cls_tiles[s].get(t, 0), "length_km": round(cls_len[s].get(t, 0.0) / 1000, 3),
                          "pixels": cls_px[s].get(t, 0), "pixel_share": round(cls_px[s].get(t, 0) / tot_px, 4)}
                      for t in config.TRACK_TYPES}
    for t in config.TRACK_TYPES:
        if balance["train"][t]["tiles"] < gate["min_tiles_per_type_train"]:
            flags.append(f"النوع {config.TRACK_TYPES[t]} ({t}): {balance['train'][t]['tiles']} بلاطة تدريب فقط "
                         f"(الحد {gate['min_tiles_per_type_train']})")
        elif balance["train"][t]["pixel_share"] < gate["under_represented_share"]:
            flags.append(f"النوع {config.TRACK_TYPES[t]} ممثَّل بأقل من {gate['under_represented_share']:.0%} من بكسلات التدريب")
        for s in ("validation", "test"):
            if counts[s] and not balance[s][t]["tiles"]:
                flags.append(f"النوع {config.TRACK_TYPES[t]} غائب من {s}")
    integrity_issues = [f"{k}: {'; '.join(v)}" for k, v in fails.items()] + leak["issues"]
    suff = []
    for s, need in gate["min_tiles"].items():
        if counts[s] < need:
            suff.append(f"{s}: {counts[s]} بلاطة < {need}")
    if n_blocks < gate["min_blocks"]:
        suff.append(f"كتل مكانية {n_blocks} < {gate['min_blocks']}")
    suff += [f for f in flags if "بلاطة تدريب فقط" in f or "غائب" in f]
    if man.get("has_fixture_data"):
        suff.append("تحتوي بيانات اختبار برمجية (fixture) — ليست وسوم المالك")
    report = {
        "export_version": man["export_version"],
        "counts": counts,
        "n_tiles": len(per_tile),
        "empty_masks": sum(1 for t in per_tile if any("فارغ" in p for p in t["problems"])),
        "integrity_passed": not integrity_issues,
        "integrity_issues": integrity_issues,
        "sufficiency_passed": not suff,
        "sufficiency_issues": suff,
        "ready_for_training": (not integrity_issues) and (not suff),
        "leakage": leak,
        "class_balance": balance,
        "balance_flags": flags,
        "coverage": {"min": min((t["coverage"] for t in per_tile), default=None),
                     "max": max((t["coverage"] for t in per_tile), default=None),
                     "mean": round(float(np.mean([t["coverage"] for t in per_tile])), 6) if per_tile else None},
        "width_px": {"min": min((t["mean_width_px"] for t in per_tile if t.get("mean_width_px") is not None), default=None),
                     "max": max((t["mean_width_px"] for t in per_tile if t.get("mean_width_px") is not None), default=None)},
        "alignment": {"max_p95_offset_px": max((t.get("p95_offset_px") or 0 for t in per_tile), default=None),
                      "max_offset_px": max((t.get("max_offset_px") or 0 for t in per_tile), default=None),
                      "min_line_recall": min((t.get("line_recall") or 1 for t in per_tile), default=None)},
        "tiles": per_tile,
        "training_note": "لا تدريب قبل ready_for_training=true. هذه المهمة لا تدرّب أي نموذج.",
    }
    (root / "quality_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    (root / "quality_report.md").write_text(report_markdown(report))
    return report


def report_markdown(r: dict) -> str:
    ok = lambda b: "نجح" if b else "فشل"
    L = [f"# تقرير جودة البيانات — {r['export_version']}", "",
         f"- السلامة (محاذاة، جيوريفرنس، عرض الخط، تسرب): **{ok(r['integrity_passed'])}**",
         f"- الكفاية (عدد البلاطات/الأنواع): **{ok(r['sufficiency_passed'])}**",
         f"- **جاهز للتدريب: {'نعم' if r['ready_for_training'] else 'لا'}**", "",
         f"البلاطات: {r['n_tiles']} — تدريب {r['counts']['train']} / تحقق {r['counts']['validation']} / اختبار {r['counts']['test']}",
         f"- أقنعة فارغة: {r['empty_masks']}",
         f"- تغطية القناع: {r['coverage']['min']} – {r['coverage']['max']} (متوسط {r['coverage']['mean']})",
         f"- عرض الخط (px): {r['width_px']['min']} – {r['width_px']['max']}",
         f"- أقصى انحراف p95 للقناع عن الخط: {r['alignment']['max_p95_offset_px']} px؛ الأقصى {r['alignment']['max_offset_px']} px؛ أدنى recall {r['alignment']['min_line_recall']}",
         f"- أقرب مسافة بين الأقسام: {r['leakage']['min_distance_m']}", ""]
    if r["integrity_issues"]:
        L += ["## مشاكل السلامة", *[f"- {i}" for i in r["integrity_issues"]], ""]
    if r["sufficiency_issues"]:
        L += ["## نواقص الكفاية", *[f"- {i}" for i in r["sufficiency_issues"]], ""]
    L += ["## توازن الأنواع", "", "| القسم | النوع | بلاطات | كم | بكسلات | حصة |", "|---|---|---|---|---|---|"]
    for s, d in r["class_balance"].items():
        for t, v in d.items():
            L.append(f"| {s} | {config.TRACK_TYPES[t]} | {v['tiles']} | {v['length_km']} | {v['pixels']} | {v['pixel_share']:.1%} |")
    return "\n".join(L) + "\n"
