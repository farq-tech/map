"""GeoJSON (WGS84) -> pixel-aligned masks in the image's OWN grid, plus overlay rendering.

Widths are physical: lines are buffered in a local UTM metric CRS (so 3 m is 3 m on the
ground regardless of the chip CRS), then moved to the chip CRS and rasterised with the
chip's affine transform. No pixel-grid resampling happens anywhere.
"""
from __future__ import annotations

import numpy as np
from PIL import Image, ImageDraw
from rasterio import features as rfeatures
from shapely.geometry import LineString, shape

from . import config
from .geo import Grid, utm_crs_for, xform


def _line_polygon(coords, grid: Grid, width_m: float):
    """Buffer a lon/lat polyline by width_m/2 on the ground; return polygon in grid CRS."""
    lon0, lat0 = coords[0]
    utm = utm_crs_for(lon0, lat0)
    line = xform(LineString(coords), "EPSG:4326", utm)
    if line.length == 0:
        return None
    poly = line.buffer(width_m / 2.0, cap_style="round", quad_segs=6)
    return xform(poly, utm, grid.crs)


def rasterize_polygons(grid: Grid, shapes: list[tuple]) -> np.ndarray:
    if not shapes:
        return np.zeros((grid.height, grid.width), np.uint8)
    return rfeatures.rasterize(
        shapes, out_shape=(grid.height, grid.width), transform=grid.transform,
        fill=0, dtype="uint8", all_touched=False)


def centerline_features(fc: dict) -> list[dict]:
    return [f for f in fc.get("features", []) if f["properties"].get("kind") == "centerline"]


def edge_features(fc: dict) -> list[dict]:
    return [f for f in fc.get("features", []) if f["properties"].get("kind") == "edge"]


def make_masks(grid: Grid, fc: dict, width_m: float = config.MASK_WIDTH_M_DEFAULT,
               edge_width_m: float = 1.0) -> dict[str, np.ndarray]:
    """Return {'mask': 0/255, 'types': class-index (0 = bg), 'edges': 0/255}."""
    res = grid.ground_res_m()
    shapes = []
    # draw clearer tracks last so they win overlaps
    cls = sorted(centerline_features(fc), key=lambda f: -int(f["properties"].get("clarity", 2)))
    for f in cls:
        poly = _line_polygon(f["geometry"]["coordinates"], grid, max(width_m, res))
        if poly is not None and not poly.is_empty:
            shapes.append((poly, config.TYPE_INDEX[f["properties"]["track_type"]]))
    types = rasterize_polygons(grid, shapes)
    mask = (types > 0).astype(np.uint8) * 255
    eshapes = []
    for f in edge_features(fc):
        poly = _line_polygon(f["geometry"]["coordinates"], grid, max(edge_width_m, res))
        if poly is not None and not poly.is_empty:
            eshapes.append((poly, 255))
    edges = rasterize_polygons(grid, eshapes)
    return {"mask": mask, "types": types, "edges": edges}


def lines_to_pixels(grid: Grid, coords) -> np.ndarray:
    lon = [c[0] for c in coords]
    lat = [c[1] for c in coords]
    col, row = grid.lonlat_to_pixel(lon, lat)
    return np.stack([col, row], axis=1)


TYPE_COLORS = {
    "sandy": (255, 196, 0), "dirt": (255, 120, 40), "rocky": (170, 170, 170),
    "mixed": (190, 90, 255), "winding": (0, 220, 120), "faint": (255, 70, 120),
}


def render_overlay(rgb: np.ndarray, grid: Grid, fc: dict, masks: dict, max_side: int = 2048) -> Image.Image:
    """RGB image + translucent mask + centrelines/edges drawn from the GeoJSON (independent of the mask)."""
    base = Image.fromarray(rgb).convert("RGBA")
    m = Image.fromarray(masks["mask"])
    tint = Image.new("RGBA", base.size, (255, 40, 40, 0))
    alpha = m.point(lambda v: 110 if v else 0)
    tint.putalpha(alpha)
    out = Image.alpha_composite(base, tint)
    d = ImageDraw.Draw(out)
    for f in centerline_features(fc):
        pts = [tuple(p) for p in lines_to_pixels(grid, f["geometry"]["coordinates"])]
        d.line(pts, fill=TYPE_COLORS.get(f["properties"].get("track_type"), (255, 255, 0)) + (255,), width=2)
    for f in edge_features(fc):
        pts = [tuple(p) for p in lines_to_pixels(grid, f["geometry"]["coordinates"])]
        d.line(pts, fill=(0, 230, 255, 255), width=1)
    out = out.convert("RGB")
    if max(out.size) > max_side:
        s = max_side / max(out.size)
        out = out.resize((int(out.width * s), int(out.height * s)), Image.LANCZOS)
    return out


def mask_to_lonlat_points(grid: Grid, mask: np.ndarray, max_points: int = 20000):
    """Pixel-centre lon/lat of mask pixels (for misalignment checks)."""
    rows, cols = np.nonzero(mask)
    if len(rows) > max_points:
        idx = np.random.default_rng(0).choice(len(rows), max_points, replace=False)
        rows, cols = rows[idx], cols[idx]
    lon, lat = grid.pixel_to_lonlat(cols + 0.5, rows + 0.5)
    return np.asarray(lon), np.asarray(lat)


def geom_of(f: dict):
    return shape(f["geometry"])
