"""GeoJSON -> mask alignment: mask pixels of a drawn line must lie within 1-2 px of the line when reprojected."""
import numpy as np
import pytest
from rasterio.transform import Affine

from annotator import geo, rasterize
from tests.conftest import fc_line, lonlat_from_utm


def _grids():
    z = geo.mosaic_grid(17, 82500, 56800, 3, 3)
    utm = geo.Grid("EPSG:32638", Affine(1.0, 0, 500000, 0, -1.0, 2800000), 1200, 1200)
    # geographic CRS grid (like an imported EPSG:4326 GeoTIFF)
    lon0, lat0 = lonlat_from_utm(500000, 2800000)
    deg = geo.Grid("EPSG:4326", Affine(1e-5, 0, lon0, 0, -1e-5, lat0), 1200, 1000)
    return {"mercator": z, "utm": utm, "wgs84": deg}


def _curvy_line(grid):
    cols = np.array([0.15, 0.35, 0.5, 0.65, 0.85]) * grid.width
    rows = np.array([0.8, 0.55, 0.5, 0.35, 0.2]) * grid.height
    lon, lat = grid.pixel_to_lonlat(cols, rows)
    return [[float(a), float(b)] for a, b in zip(lon, lat)]


@pytest.mark.parametrize("name", ["mercator", "utm", "wgs84"])
def test_mask_pixels_lie_near_the_line(name):
    g = _grids()[name]
    fc = {"type": "FeatureCollection", "features": [fc_line(_curvy_line(g))]}
    masks = rasterize.make_masks(g, fc, width_m=3.0)
    assert masks["mask"].max() == 255
    res = g.ground_res_m()
    half_px = (3.0 / 2) / res
    lon, lat = rasterize.mask_to_lonlat_points(g, masks["mask"], 6000)
    from annotator.quality import _nearest_dist_m
    d = _nearest_dist_m(lon, lat, [fc["features"][0]["geometry"]["coordinates"]]) / res
    assert d.max() <= half_px + 1.0, (name, d.max(), half_px)


@pytest.mark.parametrize("name", ["mercator", "utm", "wgs84"])
def test_line_samples_land_on_mask_and_width_is_physical(name):
    g = _grids()[name]
    coords = _curvy_line(g)
    fc = {"type": "FeatureCollection", "features": [fc_line(coords)]}
    mask = rasterize.make_masks(g, fc, width_m=3.0)["mask"]
    from annotator.quality import _line_samples
    s = _line_samples(coords, g)
    assert (mask[s[:, 1].astype(int), s[:, 0].astype(int)] > 0).mean() > 0.995
    # physical width: area / length ~ 3 m (max(width, res) so >= 1 px)
    length_m = geo.line_length_m(coords)
    area_m2 = (mask > 0).sum() * g.ground_res_m() ** 2
    assert abs(area_m2 / length_m - max(3.0, g.ground_res_m())) / 3.0 < 0.2


def test_edges_and_types():
    g = _grids()["utm"]
    c = _curvy_line(g)
    left = [[x, y + 2e-5] for x, y in c]
    fc = {"type": "FeatureCollection", "features": [
        fc_line(c, track_type="sandy", fid="a"),
        fc_line(left, kind="edge", fid="e1", track_id="a")]}
    m = rasterize.make_masks(g, fc)
    assert set(np.unique(m["types"])) == {0, 1}  # sandy -> class 1
    assert m["edges"].max() == 255 and (m["edges"] > 0).sum() < (m["mask"] > 0).sum()


def test_overlay_renders_same_size(tmp_path):
    g = _grids()["utm"]
    fc = {"type": "FeatureCollection", "features": [fc_line(_curvy_line(g))]}
    m = rasterize.make_masks(g, fc)
    rgb = np.full((g.height, g.width, 3), 90, np.uint8)
    im = rasterize.render_overlay(rgb, g, fc, m, max_side=4000)
    assert im.size == (g.width, g.height)
    assert np.asarray(im)[..., 0].max() > 90
