"""«دروب البر» for the whole Kingdom: the route grid (routes.py, format SARYRT1, 3 arc-seconds) cut into
1° x 1° tiles that the app downloads on demand (apps/tiles serves them; DesertTileStore in
Sources/Explore/CampSites/DesertRouter.swift fetches, verifies and stitches them).

    python -I tiles.py list [--boundary ksa.geojson]          tile names that hold Saudi land, one per line
    python -I tiles.py build <tile> <cache_dir> <out_dir>      routes-<tile>.bin from <cache>/<tile>/layers.npz
    python -I tiles.py manifest <out_dir> --version V [--built-from built_from.json]

A tile name is `t{lat}_{lng}`, its south-west corner in integer degrees (`t25_46` = 25..26 N, 46..47 E).
Each tile is computed on its bbox grown by regions.TILE_HALO_DEG (fetch_rasters / build --route-layers
take the tile name like a region) and cropped to the exact degree square, so tiles do not overlap and
all sit on one global 3-arc-second lattice; the app stitches neighbours by lattice index. See
national.sh for the whole run and README.md ("Routes for the whole Kingdom") for machine size and upload.

manifest.json:
    {"format": "SARYRT1", "version": V, "arcsec": 3, "tile_deg": 1, "halo_deg": 0.05,
     "attribution": "...", "built_from": {...}, "generated_at": "...Z",
     "tiles": [{"id": "t25_46", "bbox": [s, w, n, e], "bytes": N, "sha256": "...", "rows": R, "cols": C}, ...]}
`bytes` and `sha256` are of the file as served (the zlib stream), which the app checks before use.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regions import ROUTE_ARCSEC, TILE_DEG, TILE_HALO_DEG, ksa_tiles, parse_tile_id, tile_bbox  # noqa: E402

MAGIC = b"SARYRT1\0"
ATTRIBUTION = ("ESA WorldCover 2021 (CC BY 4.0) · Copernicus DEM GLO-30 © DLR e.V. 2010-2014 and © Airbus Defence and "
               "Space GmbH 2014-2018 provided under COPERNICUS by the EU and ESA · Contains modified Copernicus Sentinel "
               "data 2025-2026 · © OpenStreetMap contributors (ODbL)")
DEFAULT_BUILT_FROM = {
    "datasets": ["Copernicus DEM GLO-30", "ESA WorldCover 10m 2021 v200", "Sentinel-2 L2A (Earth Search)",
                 "OpenStreetMap gcc-states (Geofabrik)"],
    "pipeline": "scripts/camp-sites (fetch_rasters, build --route-layers, routes, tiles)",
}


def tile_file(tile):
    return f"routes-{tile}.bin"


def read_header(path):
    """The SARYRT1 header JSON of a written grid (inflates only the first bytes)."""
    d = zlib.decompressobj()
    with open(path, "rb") as f:
        raw = d.decompress(f.read(1 << 16), 1 << 16)
    if raw[:8] != MAGIC:
        raise ValueError(f"{path}: not a SARYRT1 grid")
    n = struct.unpack("<I", raw[8:12])[0]
    return json.loads(raw[12:12 + n])


def build_tile(tile, cache, out_dir):
    """Route grid of the haloed tile, cropped to the exact tile, written as routes-<tile>.bin."""
    import routes as RT  # numpy/scipy: build time only

    sw = parse_tile_id(tile)
    if sw is None:
        raise ValueError(f"not a tile name: {tile}")
    g = RT.crop(RT.grid_from_layers(tile, cache), tile_bbox(*sw))
    expected = round(TILE_DEG * 3600 / ROUTE_ARCSEC)
    if g["cls"].shape != (expected, expected):
        raise ValueError(f"{tile}: cropped grid {g['cls'].shape}, expected {expected}x{expected}")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, tile_file(tile))
    tmp = path + ".part"
    RT.write_bin(g, tmp, tile)
    os.replace(tmp, path)  # a half-written tile never looks finished (national.sh resumes on existing files)
    return path


def build_manifest(out_dir, version, built_from=None, now=None):
    """manifest.json for every routes-t*.bin in out_dir. Raises on a file whose header does not match its
    name (a tile under the wrong name would route people over the wrong ground)."""
    tiles = []
    for name in sorted(os.listdir(out_dir)):
        if not (name.startswith("routes-t") and name.endswith(".bin")):
            continue
        tile = name[len("routes-"):-len(".bin")]
        sw = parse_tile_id(tile)
        if sw is None:
            continue
        path = os.path.join(out_dir, name)
        h = read_header(path)
        s, w, n, e = tile_bbox(*sw)
        if (h.get("region") != tile or abs(h["south"] - s) > 1e-9 or abs(h["west"] - w) > 1e-9
                or abs(h["north"] - n) > 1e-9 or abs(h["east"] - e) > 1e-9 or h["arcsec"] != ROUTE_ARCSEC):
            raise ValueError(f"{name}: header {h} does not match tile {tile}")
        data = open(path, "rb").read()
        tiles.append({"id": tile, "bbox": [s, w, n, e], "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "rows": h["rows"], "cols": h["cols"]})
    tiles.sort(key=lambda t: parse_tile_id(t["id"]))
    now = now or dt.datetime.now(dt.timezone.utc)
    return {"format": "SARYRT1", "version": version, "arcsec": ROUTE_ARCSEC, "tile_deg": TILE_DEG, "halo_deg": TILE_HALO_DEG,
            "attribution": ATTRIBUTION, "built_from": built_from or DEFAULT_BUILT_FROM,
            "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "tiles": tiles}


def write_manifest(out_dir, version, built_from=None):
    m = build_manifest(out_dir, version, built_from)
    tmp = os.path.join(out_dir, "manifest.json.part")
    with open(tmp, "w") as f:
        json.dump(m, f, ensure_ascii=False, indent=1)
    os.replace(tmp, os.path.join(out_dir, "manifest.json"))
    return m


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("--boundary", help="GeoJSON of the exact Kingdom boundary (default: the coarse outline in regions.py)")
    p = sub.add_parser("build")
    p.add_argument("tile")
    p.add_argument("cache")
    p.add_argument("out")
    p = sub.add_parser("manifest")
    p.add_argument("out")
    p.add_argument("--version", required=True)
    p.add_argument("--built-from", help="JSON file merged into built_from (e.g. the OSM extract md5)")
    a = ap.parse_args(argv)
    if a.cmd == "list":
        outline = None
        if a.boundary:
            from shapely.geometry import shape
            from shapely.ops import unary_union
            gj = json.load(open(a.boundary))
            feats = gj.get("features") or [gj]
            outline = unary_union([shape(f.get("geometry", f)) for f in feats])
        print("\n".join(ksa_tiles(outline)))
    elif a.cmd == "build":
        print(build_tile(a.tile, a.cache, a.out))
    else:
        built_from = dict(DEFAULT_BUILT_FROM)
        if a.built_from:
            built_from.update(json.load(open(a.built_from)))
        m = write_manifest(a.out, a.version, built_from)
        print(len(m["tiles"]), "tiles", sum(t["bytes"] for t in m["tiles"]), "bytes")


if __name__ == "__main__":
    main()
