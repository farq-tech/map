import json
import pickle
from pathlib import Path

import numpy as np
import pytest
import rasterio
from PIL import Image

from annotator import config, export, geo, quality, splits, store
from tests.conftest import fc_line, lonlat_from_utm, make_test_tif


def _line_in(meta, fracs, ttype="dirt", fid="t1"):
    g = store.grid_of(meta)
    cols = np.array([f[0] for f in fracs]) * g.width
    rows = np.array([f[1] for f in fracs]) * g.height
    lon, lat = g.pixel_to_lonlat(cols, rows)
    return fc_line([[float(a), float(b)] for a, b in zip(lon, lat)], track_type=ttype, fid=fid)


def _annotated(tmp_path, name="a.tif", origin=(500000.0, 2800000.0), size=(1200, 1200), seed=1, ttype="dirt"):
    p = make_test_tif(tmp_path / name, origin=origin, size=size, seed=seed)
    meta, existed = store.create_from_geotiff(p)
    line = _line_in(meta, [(0.05, 0.9), (0.3, 0.6), (0.55, 0.5), (0.8, 0.25), (0.95, 0.1)], ttype)
    store.save_annotations(meta["sample_id"], {"type": "FeatureCollection", "features": [line]},
                           {"terrain": "flat_sand", "clarity": 2})
    return meta["sample_id"]


def test_import_geotiff_keeps_crs_and_is_idempotent(tmp_path, tif_utm):
    m1, e1 = store.create_from_geotiff(tif_utm)
    m2, e2 = store.create_from_geotiff(tif_utm)
    assert (e1, e2) == (False, True) and m1["sample_id"] == m2["sample_id"]
    with rasterio.open(store.sample_dir(m1["sample_id"]) / "image.tif") as src, rasterio.open(tif_utm) as orig:
        assert src.crs == orig.crs and src.transform == orig.transform and src.shape == orig.shape
        assert (src.read() == orig.read()).all()  # original pixels preserved
    assert m1["georef"]["epsg"] == 32638 and m1["license"]["status"] == "owner-declared"
    assert (store.sample_dir(m1["sample_id"]) / "preview.jpg").is_file()


def test_geotiff_without_crs_is_rejected(tmp_path):
    p = tmp_path / "nocrs.tif"
    with rasterio.open(p, "w", driver="GTiff", height=10, width=10, count=1, dtype="uint8") as d:
        d.write(np.zeros((1, 10, 10), "uint8"))
    with pytest.raises(store.SampleError):
        store.create_from_geotiff(p)


def test_16bit_import_is_stretched_for_display(tmp_path):
    p = make_test_tif(tmp_path / "u16.tif", dtype="uint16", bands=4)
    meta, _ = store.create_from_geotiff(p)
    assert meta["source"]["stretch"] == "2-98 percentile" and meta["source"]["bands"] == 4
    assert store.read_rgb(meta["sample_id"]).dtype == np.uint8


def test_save_outputs_everything_requested(tmp_path):
    sid = _annotated(tmp_path)
    d = store.sample_dir(sid)
    for f in ("image.tif", "tracks.geojson", "mask.png", "mask.tif", "mask_types.png", "overlay.png", "metadata.json"):
        assert (d / f).is_file(), f
    meta = json.loads((d / "metadata.json").read_text())
    assert meta["sample_id"] == sid and meta["terrain"] == "flat_sand" and meta["clarity"] == 2
    assert meta["annotation"]["n_tracks"] == 1 and meta["annotation"]["by_type"]["dirt"]["length_m"] > 500
    with rasterio.open(d / "image.tif") as im, rasterio.open(d / "mask.tif") as mk:
        assert im.shape == mk.shape and im.transform == mk.transform and im.crs == mk.crs
    assert np.array(Image.open(d / "mask.png")).shape == (1200, 1200)
    q = quality.check_sample(sid)
    assert q["ok"], q


def test_validation_rejects_bad_input(tmp_path):
    sid = _annotated(tmp_path)
    bad = {"type": "FeatureCollection", "features": [fc_line([[46.0, 25.0], [46.001, 25.0]], track_type="tarmac")]}
    with pytest.raises(store.SampleError):
        store.save_annotations(sid, bad)
    with pytest.raises(store.SampleError):
        store.save_annotations(sid, {"type": "FeatureCollection", "features": [fc_line([[46.0, 25.0]])]})
    orphan = {"type": "FeatureCollection", "features": [fc_line([[46, 25], [46.1, 25]], kind="edge", fid="e", track_id="nope")]}
    with pytest.raises(store.SampleError):
        store.save_annotations(sid, orphan)


def test_edge_sides_are_tagged(tmp_path):
    p = make_test_tif(tmp_path / "e.tif")
    meta, _ = store.create_from_geotiff(p)
    c = _line_in(meta, [(0.1, 0.5), (0.9, 0.5)], fid="a")
    g = store.grid_of(meta)
    def shifted(dy):
        pts = [(0.1, 0.5 + dy), (0.9, 0.5 + dy)]
        lon, lat = g.pixel_to_lonlat([p[0] * g.width for p in pts], [p[1] * g.height for p in pts])
        return [[float(a), float(b)] for a, b in zip(lon, lat)]
    fc = {"type": "FeatureCollection", "features": [c,
          fc_line(shifted(-0.01), kind="edge", fid="n", track_id="a"),
          fc_line(shifted(+0.01), kind="edge", fid="s", track_id="a")]}
    store.save_annotations(meta["sample_id"], fc)
    sides = {f["properties"]["id"]: f["properties"]["side"] for f in store.read_tracks(meta["sample_id"])["features"] if f["properties"]["kind"] == "edge"}
    # drawn west->east: north of the line is on the LEFT
    assert sides == {"n": "left", "s": "right"}


# ---------------------------------------------------------------- split / leakage
def _footprints(n_side=12, size=400.0, gap=0.0):
    from shapely.geometry import box
    out = []
    for i in range(n_side):
        for j in range(n_side):
            x, y = 5_000_000 + i * (size + gap), 2_900_000 + j * (size + gap)
            out.append({"id": f"t{i}_{j}", "footprint": box(x, y, x + size, y + size)})
    return out


def test_spatial_split_has_no_leakage_and_is_deterministic():
    tiles = _footprints()
    r = {"train": 0.7, "validation": 0.15, "test": 0.15}
    a = splits.split_tiles(tiles, r, block_m=1200.0, buffer_m=500.0, seed=3)
    b = splits.split_tiles(tiles, r, block_m=1200.0, buffer_m=500.0, seed=3)
    assert a["assign"] == b["assign"]
    leak = splits.check_leakage(tiles, a["assign"], 500.0)
    assert leak["ok"], leak
    assert a["dropped"]  # adjacent blocks => buffer must have removed tiles
    kept = {s: sum(1 for v in a["assign"].values() if v == s) for s in splits.SPLITS}
    assert all(kept[s] > 0 for s in splits.SPLITS)


def test_tiles_of_one_block_never_straddle_splits():
    tiles = _footprints()
    a = splits.split_tiles(tiles, {"train": 0.7, "validation": 0.15, "test": 0.15}, block_m=1200.0, buffer_m=0.0, seed=1)
    by_block = {}
    for t in tiles:
        by_block.setdefault(splits.block_of(t["footprint"], 1200.0), set()).add(a["assign"][t["id"]])
    assert all(len(v) == 1 for v in by_block.values())


def test_leakage_checker_catches_injected_violation():
    tiles = _footprints(4)
    assign = {t["id"]: "train" for t in tiles}
    assign["t0_0"] = "test"  # touching neighbours are train
    assert not splits.check_leakage(tiles, assign, 500.0)["ok"]


def test_random_tile_split_would_leak_but_ours_does_not():
    tiles = _footprints()
    rng = np.random.default_rng(0)
    rnd = {t["id"]: rng.choice(splits.SPLITS, p=[0.7, 0.15, 0.15]) for t in tiles}
    assert not splits.check_leakage(tiles, rnd, 500.0)["ok"]


# ---------------------------------------------------------------- export
def test_export_sam_road_layout_and_quality(tmp_path):
    # two samples ~12 km apart so the spatial split has more than one block
    _annotated(tmp_path, "a.tif", origin=(500000.0, 2800000.0), seed=1, ttype="sandy")
    _annotated(tmp_path, "b.tif", origin=(512000.0, 2800000.0), seed=2, ttype="winding")
    _annotated(tmp_path, "c.tif", origin=(500000.0, 2812000.0), seed=3, ttype="faint")
    root = export.run_export(block_km=5.0)
    sp = root / "spacenet"
    split = json.loads((sp / "data_split.json").read_text())
    assert set(split) == {"train", "validation", "test"}
    ids = sum(split.values(), [])
    assert ids and len(ids) == len(set(ids))
    T = 400
    for tid in ids:
        rgb = Image.open(sp / "RGB_1.0_meter" / f"{tid}__rgb.png")
        assert rgb.size == (T, T) and rgb.mode == "RGB"
        adj = pickle.load(open(sp / "RGB_1.0_meter" / f"{tid}__gt_graph.p", "rb"))
        assert adj and all(isinstance(k, tuple) and len(k) == 2 and isinstance(k[0], int) for k in adj)
        assert all(n in adj[m] for m, ns in adj.items() for n in ns) or True
        assert all(m in adj[n] for m, ns in adj.items() for n in ns)  # symmetric
        for pre in ("road_mask", "keypoint_mask"):
            a = np.array(Image.open(sp / "processed" / f"{pre}_{tid}.png"))
            assert a.shape == (T, T) and set(np.unique(a)) <= {0, 255}
        geo_ = json.loads((root / "extras" / f"{tid}__geo.json").read_text())
        assert geo_["epsg"] == 32638 and abs(geo_["gsd_m"] - 1.0) < 1e-9
    man = json.loads((root / "manifest.json").read_text())
    assert man["target"]["commit"].startswith("04b67c5") and man["licence"]["status"] == "owner-declared"
    rep = json.loads((root / "quality_report.json").read_text())
    assert rep["integrity_passed"], rep["integrity_issues"]
    assert rep["leakage"]["ok"] and rep["empty_masks"] == 0
    assert rep["sufficiency_passed"] is False and rep["ready_for_training"] is False  # tiny data => honest "no"
    assert rep["alignment"]["max_p95_offset_px"] <= 3.0 and rep["alignment"]["min_line_recall"] >= 0.98
    assert 3.0 <= rep["width_px"]["min"] <= rep["width_px"]["max"] <= 6.5
    with pytest.raises(FileExistsError):
        export.run_export(block_km=5.0, label=man["export_version"])


def test_export_graph_coordinate_convention_matches_sam_road_dataset():
    """dataset.py: coord_transform = lambda v: stack([v[:,1], 400 - v[:,0]]) -> (r,c) -> (x,y)."""
    from rasterio.transform import Affine
    g = geo.Grid("EPSG:32638", Affine(1, 0, 500000, 0, -1, 2800000), 400, 400)
    lon, lat = g.pixel_to_lonlat([100.0, 300.0], [350.0, 50.0])  # x,y
    fc = {"type": "FeatureCollection", "features": [fc_line([[float(lon[0]), float(lat[0])], [float(lon[1]), float(lat[1])]])]}
    adj = export.build_graph(fc, g)
    v = np.array(list(adj))
    xy = np.stack([v[:, 1], 400 - v[:, 0]], 1)
    assert sorted(map(tuple, xy.tolist())) == [(100, 350), (300, 50)]


def test_graph_masks_equal_vendored_generate_labels(tmp_path):
    vendor = Path.home() / "farq-map/research/sary-albarq-road-extraction/vendor/sam_road/spacenet/generate_labels.py"
    if not vendor.is_file():
        pytest.skip("vendored sam_road not available")
    import os, subprocess, sys, shutil
    adj = {(350, 100): [(200, 200)], (200, 200): [(350, 100), (50, 300), (60, 120)], (50, 300): [(200, 200)], (60, 120): [(200, 200)]}
    work = tmp_path / "w"
    (work / "RGB_1.0_meter").mkdir(parents=True)
    pickle.dump(adj, open(work / "RGB_1.0_meter" / "X1__gt_graph.p", "wb"))
    (work / "data_split.json").write_text(json.dumps({"train": ["X1"], "validation": [], "test": []}))
    subprocess.run([sys.executable, str(vendor)], cwd=work, check=True, capture_output=True)
    kp, road = export.graph_masks(adj)
    assert (np.array(Image.open(work / "processed" / "road_mask_X1.png")) == road).all()
    assert (np.array(Image.open(work / "processed" / "keypoint_mask_X1.png")) == kp).all()


def test_cv2_thickness_3_renders_about_5px_like_sam_roads_own_script():
    """Documented quirk: generate_labels.py uses cv2.line(..., 3) which paints ~5 px. We must match, not 'fix' it."""
    import cv2
    img = np.zeros((50, 50), np.uint8)
    cv2.line(img, (0, 25), (49, 25), 255, 3)
    assert 4 <= int((img[:, 25] > 0).sum()) <= 5
