"""Pilot regions for «أماكن مقترحة للكشتة» (camp sites) and «مخطط دروب البر» (off-road routes).

Bounding boxes are (south, west, north, east) in degrees, WGS84.
The analysis grid is 2 arc-seconds (~56 m E-W x 62 m N-S at 25°N) for the camp-site model
and 3 arc-seconds (~85 x 93 m) for the route cost grid bundled in the app.
"""

import math
import re


class _Regions(dict):
    """The pilot regions by name; a national tile name (`t25_46`, see `tile_region`) resolves to its
    haloed bbox on demand, so every step (fetch_rasters, build, routes) runs on a tile unchanged."""

    def __missing__(self, name):
        tile = parse_tile_id(name)
        if tile is None:
            raise KeyError(name)
        return tile_region(*tile)


REGIONS = _Regions({
    "thumamah": {
        "name": "الثمامة وشمال الرياض",
        "bbox": (25.0, 46.4, 25.4, 46.9),
    },
    "nafud": {
        "name": "النفود الكبير (جنوب حائل)",
        "bbox": (28.0, 41.0, 28.6, 41.8),
    },
    "dahna": {
        "name": "عروق الدهناء (طريق الشرقية)",
        # The Dahna sand belt where the Riyadh–Dammam highway crosses it (~47.6–47.9°E).
        "bbox": (24.85, 47.45, 25.25, 47.95),
    },
})

ANALYSIS_ARCSEC = 2   # camp-site model grid
ROUTE_ARCSEC = 3      # route cost grid (app bundle)


def grid_shape(bbox, arcsec):
    s, w, n, e = bbox
    rows = round((n - s) * 3600 / arcsec)
    cols = round((e - w) * 3600 / arcsec)
    return rows, cols


# ---- national tiles («دروب البر» for the whole Kingdom) ----------------------------------------
#
# 1° x 1° tiles named by their south-west corner in integer degrees: `t25_46` covers 25..26 N,
# 46..47 E. Each tile is computed on a bbox grown by TILE_HALO_DEG on every side (so slopes, the
# dune-ridge structure tensor, distances to tracks and the 2x2 coarsening see their neighbours) and
# then cropped to the exact tile. Output tiles therefore do NOT overlap: they sit on one global
# 3-arc-second lattice (cell edges at multiples of 1/1200°) and the app stitches them by lattice
# index (`DesertGrid.stitch`). Flow accumulation (wadi size) still only sees the halo: a wadi that
# drains a catchment much larger than the halo is under-sized near tile edges (documented limit).

TILE_DEG = 1
TILE_HALO_DEG = 0.05            # 3 arc-min = 60 route cells = 90 analysis cells
TILE_RE = re.compile(r"^t(\d{1,2})_(\d{1,3})$")
# Kingdom land bbox (generous); tiles are further filtered by KSA_OUTLINE.
KSA_BBOX = (16, 34, 33, 56)     # (south, west, north, east), integer degrees

# A coarse outline of the Kingdom (lng, lat), clockwise from the head of the Gulf of Aqaba. Only
# used to skip 1° tiles that hold no Saudi land; it is buffered by KSA_OUTLINE_BUFFER_DEG, so its
# vertices need not be exact (an extra tile of sea or desert across the border costs one build and
# is harmless: water is forbidden ground). Pass an exact boundary (GeoJSON) to tiles.py to override.
KSA_OUTLINE = [
    (34.95, 29.36), (36.07, 29.19), (36.50, 29.50), (36.75, 29.87), (37.50, 30.00), (37.67, 30.33),
    (38.00, 30.50), (37.00, 31.50), (39.00, 32.00), (39.30, 32.23), (40.40, 31.95), (42.00, 31.10),
    (44.70, 29.20), (46.55, 29.10), (47.45, 28.95), (48.42, 28.53), (49.60, 27.10), (50.15, 26.65),
    (50.20, 26.15), (50.00, 25.60), (50.80, 24.75), (51.60, 24.25), (52.60, 22.95), (55.10, 22.60),
    (55.67, 22.00), (55.00, 20.00), (52.00, 19.00), (49.10, 18.60), (48.20, 18.20), (47.00, 16.95),
    (46.40, 17.25), (45.20, 17.40), (44.00, 17.40), (43.30, 17.55), (42.80, 16.40), (42.70, 16.70),
    (41.80, 17.80), (40.80, 19.50), (39.60, 20.90), (39.15, 21.50), (38.50, 23.50), (38.05, 24.10),
    (37.20, 25.00), (36.50, 26.00), (35.50, 27.50), (34.60, 28.10), (34.85, 28.90),
]
KSA_OUTLINE_BUFFER_DEG = 0.5


def tile_id(lat, lng):
    """The tile holding (lat, lng): `t{floor(lat)}_{floor(lng)}`."""
    return f"t{math.floor(lat)}_{math.floor(lng)}"


def parse_tile_id(name):
    """(south, west) integer degrees of a tile name, or None."""
    m = TILE_RE.match(name or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def tile_bbox(lat0, lng0):
    """The exact (unhaloed) bbox of the tile whose south-west corner is (lat0, lng0)."""
    return (float(lat0), float(lng0), float(lat0 + TILE_DEG), float(lng0 + TILE_DEG))


def tile_region(lat0, lng0, halo=TILE_HALO_DEG):
    s, w, n, e = tile_bbox(lat0, lng0)
    return {"name": f"مربع {lat0}°N {lng0}°E", "bbox": (s - halo, w - halo, n + halo, e + halo),
            "tile": (s, w, n, e), "halo": halo}


def tiles_covering(bbox):
    """Tile (south, west) corners of every tile that intersects bbox (an edge on an integer degree
    does not pull in the neighbour)."""
    s, w, n, e = bbox
    lats = range(math.floor(s), math.ceil(n))
    lngs = range(math.floor(w), math.ceil(e))
    return [(la, lo) for la in lats for lo in lngs]


def ksa_tiles(outline=None, buffer_deg=KSA_OUTLINE_BUFFER_DEG):
    """Names of the tiles in KSA_BBOX that touch the (buffered) outline, south to north, west to east.
    `outline` is a shapely geometry (exact boundary) or None for the coarse KSA_OUTLINE."""
    from shapely.geometry import Polygon, box  # build-time only

    shape = (outline if outline is not None else Polygon(KSA_OUTLINE)).buffer(buffer_deg)
    return [tile_id(la, lo) for la, lo in tiles_covering(KSA_BBOX)
            if shape.intersects(box(lo, la, lo + TILE_DEG, la + TILE_DEG))]
