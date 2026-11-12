import numpy as np
from rasterio.transform import Affine

from annotator import geo


def test_mosaic_grid_matches_tile_corners():
    z, x0, y0 = 17, 82500, 56800
    g = geo.mosaic_grid(z, x0, y0, 3, 3)
    lon, lat = g.pixel_to_lonlat(0, 0)
    lon_t, lat_t = geo.tile_to_lonlat(x0, y0, z)
    assert abs(lon - lon_t) < 1e-9 and abs(lat - lat_t) < 1e-9
    lon, lat = g.pixel_to_lonlat(g.width, g.height)
    lon_t, lat_t = geo.tile_to_lonlat(x0 + 3, y0 + 3, z)
    assert abs(lon - lon_t) < 1e-9 and abs(lat - lat_t) < 1e-9


def test_roundtrip_mercator_and_utm():
    g1 = geo.mosaic_grid(17, 82500, 56800, 3, 3)
    g2 = geo.Grid("EPSG:32638", Affine(1.0, 0, 500000, 0, -1.0, 2800000), 1000, 1000)
    for g in (g1, g2):
        rng = np.random.default_rng(3)
        c, r = rng.uniform(0, g.width, 500), rng.uniform(0, g.height, 500)
        lon, lat = g.pixel_to_lonlat(c, r)
        c2, r2 = g.lonlat_to_pixel(lon, lat)
        assert np.abs(c2 - c).max() < 1e-6 and np.abs(r2 - r).max() < 1e-6


def test_geo_to_pixel_to_geo_precision_is_sub_millimetre():
    g = geo.mosaic_grid(17, 82500, 56800, 3, 3)
    lon0, lat0 = g.centre_lonlat()
    c, r = g.lonlat_to_pixel(lon0 + 1e-4, lat0 + 1e-4)
    lon1, lat1 = g.pixel_to_lonlat(c, r)
    _, _, d = geo.GEOD.inv(lon0 + 1e-4, lat0 + 1e-4, float(lon1), float(lat1))
    assert d < 1e-3  # metres


def test_ground_resolution_of_z17_2x_at_saudi_latitudes():
    # tile at ~25.5N, 46.6E
    x, y = geo.lonlat_to_tile(46.6, 25.5, 17)
    g = geo.mosaic_grid(17, int(x), int(y), 3, 3)
    assert 0.52 < g.ground_res_m() < 0.56  # documented ~0.54 m/px


def test_utm_zone_for_saudi():
    assert geo.utm_epsg(46.6, 25.1) == 32638
    assert geo.utm_epsg(39.2, 21.5) == 32637


def test_line_length_geodesic():
    # 0.001 deg lat ~ 110.6 m
    assert abs(geo.line_length_m([(46.0, 25.0), (46.0, 25.001)]) - 110.7) < 0.5
