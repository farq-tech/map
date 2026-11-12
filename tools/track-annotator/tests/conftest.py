"""Test isolation: every test session uses a temp data dir and never touches the network or the real token."""
import os
import tempfile
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="annotator-tests-")
os.environ["ANNOTATOR_DATA"] = str(Path(_TMP) / "data")
os.environ["ANNOTATOR_EXPORTS"] = str(Path(_TMP) / "exports")
os.environ["TILE_FALLBACK_DIRS"] = str(Path(_TMP) / "no-fallback")
os.environ["MAPBOX_ACCESS_TOKEN"] = "pk.TESTTOKEN_not_real"

import numpy as np  # noqa: E402
import pytest  # noqa: E402
import rasterio  # noqa: E402
from rasterio.transform import Affine  # noqa: E402

from annotator import config  # noqa: E402


@pytest.fixture(autouse=True)
def clean_dirs():
    import shutil
    for d in (config.SAMPLES_DIR, config.BATCH_DIR, config.EXPORT_DIR, config.DATA_DIR / "cache"):
        shutil.rmtree(d, ignore_errors=True)
    config.ensure_dirs()
    yield


def make_test_tif(path, crs="EPSG:32638", origin=(500000.0, 2800000.0), res=1.0, size=(1200, 1200),
                  dtype="uint8", bands=3, seed=1):
    """TEST-ONLY raster with smooth texture so geometry code has pixels to chew on. Not product imagery."""
    rng = np.random.default_rng(seed)
    h, w = size
    base = rng.normal(120, 20, (bands, h // 8 + 1, w // 8 + 1))
    arr = np.kron(base, np.ones((1, 8, 8)))[:, :h, :w]
    arr = np.clip(arr, 1, 254).astype("uint8") if dtype == "uint8" else (arr * 40).astype(dtype)
    t = Affine(res, 0, origin[0], 0, -res, origin[1])
    with rasterio.open(path, "w", driver="GTiff", height=h, width=w, count=bands, dtype=dtype,
                       crs=crs, transform=t) as dst:
        dst.write(arr)
    return path


@pytest.fixture
def tif_utm(tmp_path):
    return make_test_tif(tmp_path / "utm.tif")


def lonlat_from_utm(x, y, epsg=32638):
    from pyproj import Transformer
    return Transformer.from_crs(f"EPSG:{epsg}", "EPSG:4326", always_xy=True).transform(x, y)


def fc_line(coords, track_type="dirt", clarity=2, kind="centerline", fid="t1", track_id=None):
    p = {"id": fid, "kind": kind, "track_type": track_type, "clarity": clarity}
    if track_id:
        p["track_id"] = track_id
    return {"type": "Feature", "properties": p, "geometry": {"type": "LineString", "coordinates": coords}}
