#!/usr/bin/env python3
"""End-to-end run through the SAME HTTP API the browser UI uses.

Fetches a real Mapbox z17@2x chip over a desert area, draws a few tracks programmatically
(clearly marked ``fixture``: these are test drawings, NOT the owner's annotations), saves,
runs the smart-collection analysis, export, split and quality report.

    python scripts/e2e_demo.py --base http://127.0.0.1:8791 --out docs/e2e
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from annotator.geo import Grid  # noqa: E402

# pixel polylines (x, y) on the 1536x1536 chip centred at 25.1558N 46.6563E (visually picked)
TRACKS = [
    ("dirt", 1, [(2, 1182), (300, 1208), (600, 1252), (900, 1290), (1050, 1310), (1250, 1340), (1533, 1372)]),
    ("winding", 1, [(320, 122), (450, 160), (580, 205), (700, 225), (820, 205), (950, 130), (1040, 80),
                    (1150, 45), (1250, 48), (1370, 70), (1450, 100), (1530, 115)]),
    ("faint", 3, [(650, 640), (640, 760), (590, 880), (470, 1010), (330, 1170)]),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8791")
    ap.add_argument("--out", default="docs/e2e")
    ap.add_argument("--lon", type=float, default=46.6563)
    ap.add_argument("--lat", type=float, default=25.1558)
    a = ap.parse_args()
    c = httpx.Client(base_url=a.base, timeout=120)
    r = c.post("/api/samples/mosaic", json={"lon": a.lon, "lat": a.lat, "nx": 3, "ny": 3, "fixture": True}).json()
    meta = r["metadata"]
    sid = meta["sample_id"]
    print("sample:", sid, "existing" if r["existing"] else "created", "| budget:", c.get("/api/config").json()["budget"])
    grid = Grid.from_dict(meta["georef"])

    def ll(pts):
        lon, lat = grid.pixel_to_lonlat([p[0] for p in pts], [p[1] for p in pts])
        return [[float(x), float(y)] for x, y in zip(lon, lat)]

    feats = []
    for i, (ttype, clarity, pts) in enumerate(TRACKS):
        fid = f"demo{i}"
        feats.append({"type": "Feature", "properties": {"id": fid, "kind": "centerline", "track_type": ttype, "clarity": clarity},
                      "geometry": {"type": "LineString", "coordinates": ll(pts)}})
    # optional edges for the first track (parallel offsets of ~7 px)
    for j, dy in enumerate((-7, 7)):
        pts = [(x, y + dy) for x, y in TRACKS[0][2]]
        feats.append({"type": "Feature", "properties": {"id": f"demoE{j}", "kind": "edge", "track_id": "demo0"},
                      "geometry": {"type": "LineString", "coordinates": ll(pts)}})
    fc = {"type": "FeatureCollection", "features": feats}
    res = c.put(f"/api/samples/{sid}/annotations", json={"geojson": fc, "terrain": "gravel_plain", "clarity": 2,
                                                         "notes": "FIXTURE: programmatic test drawing, not owner annotation"})
    res.raise_for_status()
    res = res.json()
    print("quality:", json.dumps(res["quality"], ensure_ascii=False))

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    sdir = Path(__file__).resolve().parent.parent / "data" / "samples" / sid
    for name in ("tracks.geojson", "metadata.json", "overlay.png"):
        src = c.get(f"/api/samples/{sid}/file/{name}")
        (out / name).write_bytes(src.content)
    for name in ("image.tif", "mask.png", "mask.tif"):
        print(f"  {name}: {(sdir / name).stat().st_size} bytes" if (sdir / name).exists() else f"  {name}: (server data dir differs)")
    print("files in sample dir:", sorted(p.name for p in sdir.iterdir()) if sdir.exists() else "n/a")

    st = c.get("/api/collection/status").json()
    print("annotated (non-fixture) samples:", st["annotated_samples"])
    b = c.get("/api/collection/batch").json()
    print("batch:", b["batch_id"], "windows:", len(b["windows"]), "missing:", [m["type"] for m in b["missing_types"]])
    ex = c.post("/api/export", json={"include_fixtures": True}).json()
    print("export:", json.dumps(ex, ensure_ascii=False))
    root = Path(ex["path"])
    for name in ("quality_report.md", "manifest.json"):
        shutil.copy(root / name, out / f"export_{name}")
    print((root / "quality_report.md").read_text())


if __name__ == "__main__":
    main()
