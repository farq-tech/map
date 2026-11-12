#!/usr/bin/env python3
"""Build config/candidates.json: REAL tile windows worth annotating.

Inputs (read-only, outside git):
  --osm  saudi_osm_desert_tracks_weak_labels.geojson  (research pipeline output, OSM ODbL)
Windows are 3x3 z17 tiles (~830 m). Per window we sum the OSM track length by class and turn it
into a *hint* per annotation type. Hints are weak labels, never ground truth:
  sandy   <- track_grade4/5 (soft)           dirt   <- track, track_grade2/3
  rocky   <- track_grade1/2 (hard; low conf) mixed  <- track_grade3 (+ mixed-class windows)
  winding <- ways with sinuosity >= 1.25     faint  <- path, track_grade5
The selection caps windows per 10 km region cell so candidates spread over many regions.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from annotator.geo import lonlat_to_tile, region_cell, tile_to_lonlat  # noqa: E402

Z, N = 17, 3
CLASS_HINT = {  # fclass -> {type: (weight, confidence)}
    "track_grade5": {"sandy": 1.0, "faint": 0.5},
    "track_grade4": {"sandy": 1.0},
    "track_grade3": {"dirt": 1.0, "mixed": 1.0},
    "track_grade2": {"dirt": 1.0, "rocky": 0.5},
    "track_grade1": {"rocky": 1.0, "dirt": 0.5},
    "track": {"dirt": 1.0},
    "path": {"faint": 1.0},
}
CONF = {"sandy": 0.7, "dirt": 0.5, "rocky": 0.25, "mixed": 0.6, "winding": 0.6, "faint": 0.4}
STUDY_AREAS = [  # earlier sat-tracks-sample rounds + blind check (centres only; no GPS trace data)
    ("camps", 25.1444, 46.6553, {"faint": 700}, "منطقة دراسة سابقة (z17 مخزنة): مخيمات وأسوار على حافة النفود"),
    ("dunes", 25.1378, 46.6495, {"sandy": 800, "faint": 500}, "منطقة دراسة سابقة: حقل كثبان"),
    ("track", 25.1558, 46.6563, {"dirt": 900, "faint": 400}, "منطقة دراسة سابقة: درب ترابي يخرج من الزفلت"),
    ("blind", 25.2320, 46.5710, {"dirt": 600, "faint": 600}, "نقطة الاختبار الأعمى السابقة"),
]


def window_of(fx: float, fy: float) -> tuple[int, int]:
    return int(fx // N) * N, int(fy // N) * N


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--osm", required=True)
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "config" / "candidates.json"))
    ap.add_argument("--per-type", type=int, default=40)
    ap.add_argument("--per-region", type=int, default=2)
    ap.add_argument("--min-m", type=float, default=400.0)
    a = ap.parse_args()

    fc = json.load(open(a.osm))
    win_cls: dict = defaultdict(lambda: defaultdict(float))
    win_wind: dict = defaultdict(float)
    for f in fc["features"]:
        cls = f["properties"].get("fclass")
        if cls not in CLASS_HINT:
            continue
        geoms = [f["geometry"]["coordinates"]] if f["geometry"]["type"] == "LineString" else f["geometry"]["coordinates"]
        for coords in geoms:
            if len(coords) < 2:
                continue
            pts = np.array([lonlat_to_tile(x, y, Z) for x, y, *_ in coords])
            lat = coords[len(coords) // 2][1]
            m_per_tile = 156543.03392 * math.cos(math.radians(lat)) / 2 ** Z * 512 / 2
            seg = np.hypot(*(pts[1:] - pts[:-1]).T) * m_per_tile
            total = seg.sum()
            chord = float(np.hypot(*(pts[-1] - pts[0])) * m_per_tile)
            wind = total >= 300 and chord > 0 and total / chord >= 1.25
            # sample points along the way every ~15 m, attribute their length share to windows
            for p0, p1, sl in zip(pts[:-1], pts[1:], seg):
                k = max(1, int(sl // 15))
                for t in (np.arange(k) + 0.5) / k:
                    q = p0 + (p1 - p0) * t
                    w = window_of(q[0], q[1])
                    share = sl / k
                    win_cls[w][cls] += share
                    if wind:
                        win_wind[w] += share
    print(f"windows with OSM tracks: {len(win_cls)}", file=sys.stderr)

    cands = {}
    for (x0, y0), cl in win_cls.items():
        total = sum(cl.values())
        if total < a.min_m:
            continue
        hint = defaultdict(float)
        for c, m in cl.items():
            for t, wgt in CLASS_HINT[c].items():
                hint[t] += m * wgt
        if win_wind.get((x0, y0)):
            hint["winding"] = win_wind[(x0, y0)]
        w, n = tile_to_lonlat(x0, y0, Z)[0], tile_to_lonlat(x0, y0, Z)[1]
        e, s = tile_to_lonlat(x0 + N, y0 + N, Z)
        cx, cy = (w + e) / 2, (n + s) / 2
        cands[(x0, y0)] = {
            "id": f"w{Z}_{x0}_{y0}_{N}x{N}", "tiles": {"z": Z, "x0": x0, "y0": y0, "nx": N, "ny": N},
            "centre": [round(cx, 6), round(cy, 6)], "bbox": [round(w, 6), round(s, 6), round(e, 6), round(n, 6)],
            "region_cell": region_cell(cx, cy), "source": "osm_weak",
            "type_hint_m": {t: round(v, 1) for t, v in hint.items()},
            "confidence": {t: CONF[t] for t in hint},
            "hint_note": "OSM: " + "، ".join(f"{c} {m:.0f} م" for c, m in sorted(cl.items(), key=lambda kv: -kv[1])),
        }

    chosen: dict = {}
    for t in CONF:
        ranked = sorted((c for c in cands.values() if c["type_hint_m"].get(t, 0) >= 150),
                        key=lambda c: -c["type_hint_m"][t])
        per_region: dict = defaultdict(int)
        taken = 0
        for c in ranked:
            if per_region[c["region_cell"]] >= a.per_region:
                continue
            per_region[c["region_cell"]] += 1
            chosen[c["id"]] = c
            taken += 1
            if taken >= a.per_type:
                break
        print(f"  {t}: {taken} windows (of {len(ranked)} eligible)", file=sys.stderr)

    for name, lat, lon, hint, note in STUDY_AREAS:
        fx, fy = lonlat_to_tile(lon, lat, Z)
        x0, y0 = int(round(fx - N / 2)), int(round(fy - N / 2))
        w, n = tile_to_lonlat(x0, y0, Z)
        e, s = tile_to_lonlat(x0 + N, y0 + N, Z)
        cx, cy = (w + e) / 2, (n + s) / 2
        cid = f"w{Z}_{x0}_{y0}_{N}x{N}"
        chosen[cid] = {
            "id": cid, "tiles": {"z": Z, "x0": x0, "y0": y0, "nx": N, "ny": N},
            "centre": [round(cx, 6), round(cy, 6)], "bbox": [round(w, 6), round(s, 6), round(e, 6), round(n, 6)],
            "region_cell": region_cell(cx, cy), "source": "study_area",
            "type_hint_m": hint, "confidence": {t: 0.6 for t in hint}, "hint_note": note,
        }

    out = {
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "tool": "scripts/build_candidates.py",
        "source": "OSM weak labels (research pipeline) + earlier study-area centres",
        "attribution": "© OpenStreetMap contributors (ODbL 1.0); hints only, not ground truth",
        "window_spec": {"zoom": Z, "nx": N, "ny": N, "scale": 2},
        "windows": sorted(chosen.values(), key=lambda c: c["id"]),
    }
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"wrote {a.out}: {len(chosen)} windows, {len({c['region_cell'] for c in chosen.values()})} regions", file=sys.stderr)


if __name__ == "__main__":
    main()
