"""Georeferencing primitives: Web-Mercator tile grid, pixel<->geo, UTM, geodesic length.

Pixel convention (rasterio / GDAL): (col, row) = (0, 0) is the TOP-LEFT CORNER of the
top-left pixel; pixel centres are at +0.5.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from functools import lru_cache

import numpy as np
from pyproj import CRS, Geod, Transformer
from rasterio.transform import Affine

WEBMERC_HALF = 20037508.342789244
GEOD = Geod(ellps="WGS84")


@dataclass(frozen=True)
class Grid:
    """A raster grid: CRS + affine transform + size."""

    crs: str  # "EPSG:3857" or a WKT string
    transform: Affine
    width: int
    height: int

    # -- transformers -------------------------------------------------
    def _to_native(self) -> Transformer:
        return _transformer("EPSG:4326", self.crs)

    def _from_native(self) -> Transformer:
        return _transformer(self.crs, "EPSG:4326")

    # -- conversions --------------------------------------------------
    def lonlat_to_pixel(self, lon, lat):
        x, y = self._to_native().transform(np.asarray(lon, float), np.asarray(lat, float))
        inv = ~self.transform
        col = inv.a * x + inv.b * y + inv.c
        row = inv.d * x + inv.e * y + inv.f
        return col, row

    def pixel_to_lonlat(self, col, row):
        col = np.asarray(col, float)
        row = np.asarray(row, float)
        t = self.transform
        x = t.a * col + t.b * row + t.c
        y = t.d * col + t.e * row + t.f
        lon, lat = self._from_native().transform(x, y)
        return lon, lat

    # -- derived ------------------------------------------------------
    def bounds_native(self) -> tuple[float, float, float, float]:
        t = self.transform
        xs = [t.c, t.c + t.a * self.width, t.c + t.b * self.height, t.c + t.a * self.width + t.b * self.height]
        ys = [t.f, t.f + t.d * self.width, t.f + t.e * self.height, t.f + t.d * self.width + t.e * self.height]
        return min(xs), min(ys), max(xs), max(ys)

    def corners_lonlat(self) -> list[tuple[float, float]]:
        cols = [0, self.width, self.width, 0]
        rows = [0, 0, self.height, self.height]
        lon, lat = self.pixel_to_lonlat(cols, rows)
        return [(float(a), float(b)) for a, b in zip(lon, lat)]

    def bbox_wgs84(self) -> tuple[float, float, float, float]:
        c = self.corners_lonlat()
        lons = [p[0] for p in c]
        lats = [p[1] for p in c]
        return min(lons), min(lats), max(lons), max(lats)

    def centre_lonlat(self) -> tuple[float, float]:
        lon, lat = self.pixel_to_lonlat(self.width / 2, self.height / 2)
        return float(lon), float(lat)

    def ground_res_m(self) -> float:
        """True ground metres per pixel (geodesic, measured at the grid centre)."""
        cx, cy = self.width / 2, self.height / 2
        lon0, lat0 = self.pixel_to_lonlat(cx, cy)
        lon1, lat1 = self.pixel_to_lonlat(cx + 100, cy)
        lon2, lat2 = self.pixel_to_lonlat(cx, cy + 100)
        _, _, dx = GEOD.inv(lon0, lat0, lon1, lat1)
        _, _, dy = GEOD.inv(lon0, lat0, lon2, lat2)
        return float((dx + dy) / 200.0)

    def to_dict(self) -> dict:
        t = self.transform
        return {
            "crs": self.crs,
            "epsg": CRS.from_user_input(self.crs).to_epsg(),
            "transform": [t.a, t.b, t.c, t.d, t.e, t.f],
            "width": self.width,
            "height": self.height,
        }

    @staticmethod
    def from_dict(d: dict) -> "Grid":
        crs = d.get("crs") or f"EPSG:{d['epsg']}"
        return Grid(crs, Affine(*d["transform"]), int(d["width"]), int(d["height"]))


@lru_cache(maxsize=64)
def _transformer(src: str, dst: str) -> Transformer:
    return Transformer.from_crs(CRS.from_user_input(src), CRS.from_user_input(dst), always_xy=True)


def transformer(src: str, dst: str) -> Transformer:
    return _transformer(src, dst)


# -- Web Mercator tile grid --------------------------------------------------
def tile_origin_m(z: int, x: int, y: int) -> tuple[float, float, float]:
    """(left, top, tile_size_m) of XYZ tile in EPSG:3857."""
    size = 2 * WEBMERC_HALF / (2 ** z)
    return -WEBMERC_HALF + x * size, WEBMERC_HALF - y * size, size


def lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[float, float]:
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y


def tile_to_lonlat(x: float, y: float, z: int) -> tuple[float, float]:
    n = 2 ** z
    lon = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    return lon, lat


def mosaic_grid(z: int, x0: int, y0: int, nx: int, ny: int, tile_px: int = 512) -> Grid:
    """Exact EPSG:3857 grid of an nx*ny mosaic of XYZ tiles (no resampling)."""
    left, top, size = tile_origin_m(z, x0, y0)
    res = size / tile_px
    return Grid("EPSG:3857", Affine(res, 0.0, left, 0.0, -res, top), nx * tile_px, ny * tile_px)


def utm_epsg(lon: float, lat: float) -> int:
    zone = int((lon + 180) // 6) + 1
    return (32600 if lat >= 0 else 32700) + zone


def utm_crs_for(lon: float, lat: float) -> str:
    return f"EPSG:{utm_epsg(lon, lat)}"


def line_length_m(coords: list[tuple[float, float]]) -> float:
    if len(coords) < 2:
        return 0.0
    lons = [c[0] for c in coords]
    lats = [c[1] for c in coords]
    return float(GEOD.line_length(lons, lats))


# Equal-area CRS used for spatial blocks (metric, global, single formula).
BLOCK_CRS = "EPSG:6933"


def block_xy(lon: float, lat: float) -> tuple[float, float]:
    x, y = _transformer("EPSG:4326", BLOCK_CRS).transform(lon, lat)
    return float(x), float(y)


def region_cell(lon: float, lat: float, size_m: float = 10000.0) -> str:
    x, y = block_xy(lon, lat)
    return f"r{int(x // size_m)}_{int(y // size_m)}"


def xform(geom, src: str, dst: str):
    """Reproject a shapely geometry (always_xy)."""
    import shapely
    t = _transformer(src, dst)

    def f(a):
        x, y = t.transform(a[:, 0], a[:, 1])
        return np.column_stack([x, y])

    return shapely.transform(geom, f)
