#!/usr/bin/env python3
"""Extract desert-relevant vector layers from an OsmAnd .obf into compact GeoJSON.gz.

Runs the OsmAnd MapCreator ``BinaryInspector`` tile by tile (default 0.5 deg, zoom 16), parses its text
output as a stream and keeps only:

* tracks  : highway=track/path/bridleway/unclassified/service (service/unclassified only when unpaved/long)
* fayad_wadi_sabkha : water / wadi / sabkha / dune / sand features and anything named with
  fayad / rawdah / khabra / sabkha / shaib / wadi / nafud ... words.

Every object is also counted (type + whether its id is a plain OSM way id) so that a later step can
measure how much of the file is plain OSM data.

Design points
* The inspector prints whole objects (not clipped) and repeats them across tiles. An object is therefore
  *owned* by the single tile that contains its first coordinate; no cross-tile de-dup is needed.
* One tile = one file ``<work>/tiles/<key>.json.gz`` (atomic write) -> resume support: re-run to continue.
* One Java process at a time by default (``--jobs 1``), ``nice -n 10``, ``-Xmx3g``.
* ``--merge`` assembles tracks.geojson.gz, fayad_wadi_sabkha.geojson.gz and manifest.json.

Usage
  extract_obf.py --obf Saudi-arabia_asia.obf --inspector-dir tools/creator --work out [--jobs 1] [--priority-only]
  extract_obf.py ... --merge
Third-party data (the obf and everything extracted from it) must never be committed to git.
"""
from __future__ import annotations

import argparse
import collections
import gzip
import json
import math
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

KSA_FOCUS = (34.5, 16.0, 56.0, 32.5)          # lon0, lat0, lon1, lat1
STEP = 0.5

# priority regions (lon0, lat0, lon1, lat1), processed first
PRIORITY = {
    "thumamah": (46.0, 25.0, 47.0, 26.0),
    "riyadh_east": (46.5, 24.0, 48.5, 26.0),
    "nafud": (39.0, 27.0, 43.5, 29.5),
    "dahna": (45.5, 22.0, 49.0, 27.0),
    "qassim": (43.0, 25.5, 45.5, 27.5),
    "hail": (40.5, 26.0, 42.5, 28.5),
}

TRACK_HW = {"track", "path", "bridleway", "unclassified", "service"}
UNPAVED = {"unpaved", "dirt", "sand", "gravel", "ground", "compacted", "fine_gravel", "earth", "grass", "mud", "rock",
           "pebblestone", "salt", "dirt/sand"}
# types that are always kept in the fayad/wadi/sabkha layer
WATER_ALWAYS = {"natural-water", "natural-wetland", "natural-sand", "natural-dune", "natural-desert", "waterway-wadi",
                "landuse-salt_pond", "natural-spring", "natural-hot_spring", "natural-valley", "natural-ridge",
                "natural-bare_rock", "natural-scree", "natural-plateau", "man_made-water_well", "natural-crater",
                "natural-earth_bank", "natural-cliff", "natural-mud", "natural-rock"}
# waterways kept only when they carry a name
WATER_IF_NAMED = {"waterway-river", "waterway-stream", "waterway-drain", "waterway-canal", "waterway-ditch",
                  "waterway-dam", "waterway-weir"}
NAME_RE = re.compile(r"(فيض|روض|خبر|خب[رى]ة|سبخ|شعيب|شعيبة|وادي|وادى|نفود|نفد|عرق|قاع|ثمد|غدير|مستنقع|ثرم|رقعة|حزم|"
                     r"رمال|الدهناء|الصمان|طعس|sabkha|sabkhah|fayd|rawdah|rawda|khabra|shuaib|shaib|wadi|nafud|nufud)",
                     re.I)
NAME_CLASS = [("rawdah", re.compile(r"روض|rawd", re.I)), ("fayda", re.compile(r"فيض|fayd", re.I)),
              ("khabra", re.compile(r"خب[رى]|khabr", re.I)), ("sabkha", re.compile(r"سبخ|sabkh", re.I)),
              ("shuaib", re.compile(r"شعيب|shuaib|shaib", re.I)), ("wadi", re.compile(r"وادي|وادى|wadi", re.I)),
              ("nafud_ard", re.compile(r"نفود|نفد|عرق|رمال|nafud|nufud", re.I)),
              ("qaa_thamad", re.compile(r"قاع|ثمد|غدير|مستنقع", re.I))]

HEAD_RE = re.compile(
    r"^(?P<kind>[A-Za-z]+)(?: Lat (?P<lat>-?[\d.]+) Lon (?P<lon>-?[\d.]+))? types \[(?P<types>[^\]]*)\]"
    r"(?: add_types \[(?P<add>[^\]]*)\])?(?: Names \[(?P<names>.*)\])? id (?P<id>-?\d+) osmid (?P<osmid>-?\d+)"
    r"(?: lat/lon : (?P<coords>.*))?$")
TOK_RE = re.compile(r"([^,\[\]()]+?)\s*\((\d+)\)")
PAIR_RE = re.compile(r"(-?[\d.]+(?:E-?\d+)?) / (-?[\d.]+(?:E-?\d+)?)")
NAME_SPLIT = re.compile(r"(?:^|, )([A-Za-z_:\-]+)\(\d+\) - ")


def tile_list(focus=KSA_FOCUS, step=STEP):
    lon0, lat0, lon1, lat1 = focus
    tiles = []
    x = lon0
    while x < lon1 - 1e-9:
        y = lat0
        while y < lat1 - 1e-9:
            tiles.append((round(x, 4), round(y, 4)))
            y += step
        x += step
    return tiles


def tile_key(t, step=STEP):
    return f"{t[0]:07.3f}_{t[1]:07.3f}"


def priority_rank(t, step=STEP):
    cx, cy = t[0] + step / 2, t[1] + step / 2
    for i, (_, (a, b, c, d)) in enumerate(PRIORITY.items()):
        if a <= cx <= c and b <= cy <= d:
            return i
    return len(PRIORITY)


def haversine_km(coords):
    r = 6371.0088
    tot = 0.0
    for (lon1, lat1), (lon2, lat2) in zip(coords, coords[1:]):
        p1, p2 = math.radians(lat1), math.radians(lat2)
        dp, dl = p2 - p1, math.radians(lon2 - lon1)
        a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
        tot += 2 * r * math.asin(min(1.0, math.sqrt(a)))
    return tot


def parse_names(raw):
    if not raw:
        return {}
    parts = NAME_SPLIT.split(raw)
    out = {}
    # parts = [pre, key1, val1, key2, val2, ...]
    for i in range(1, len(parts) - 1, 2):
        out[parts[i]] = parts[i + 1].strip()
    return out


def simplify(coords, max_pts):
    if len(coords) <= max_pts:
        return coords
    k = len(coords) / max_pts
    idx = sorted({min(len(coords) - 1, int(i * k)) for i in range(max_pts)} | {len(coords) - 1})
    return [coords[i] for i in idx]


def parse_tile_stream(lines, bounds):
    """lines: iterable of str. bounds=(l, b, r, t) of the owning tile. Returns dict."""
    l, b, r, t = bounds
    stats = collections.defaultdict(lambda: [0, 0, 0])   # first type -> [n, plain_way_id, no_osmid]
    kinds = collections.Counter()
    tracks, water = [], []
    seen = set()
    n_all = n_owned = 0
    for line in lines:
        if not line or line[0] not in "WPAM":
            continue
        n_all += 1
        i = line.find("lat/lon : ")
        if i < 0:
            continue
        m0 = PAIR_RE.search(line, i)
        if not m0:
            continue
        flat, flon = float(m0.group(1)), float(m0.group(2))
        if not (l <= flon < r and b <= flat < t):
            continue                                   # owned by a neighbouring tile
        m = HEAD_RE.match(line.rstrip("\n"))
        if not m:
            stats["__unparsed__"][0] += 1
            continue
        oid, osmid = int(m.group("id")), int(m.group("osmid"))
        if oid in seen:
            continue
        seen.add(oid)
        n_owned += 1
        types = [x[0].strip() for x in TOK_RE.findall(m.group("types") or "")]
        add = [x[0].strip() for x in TOK_RE.findall(m.group("add") or "")]
        main = types[0] if types else "(none)"
        st = stats[main]
        st[0] += 1
        plain = osmid > 0 and (oid >> 7) == osmid
        if plain:
            st[1] += 1
        if osmid <= 0:
            st[2] += 1
        kinds[m.group("kind")] += 1
        names = parse_names(m.group("names"))
        nm = names.get("name") or names.get("name:ar") or ""
        hw = next((x.split("-", 1)[1] for x in types if x.startswith("highway-")), None)
        keep_track = hw in TRACK_HW
        wtype = next((x for x in types if x in WATER_ALWAYS or x in WATER_IF_NAMED), None)
        alltxt = " ".join(names.get(k, "") for k in ("name", "name:ar", "name:en", "alt_name", "old_name") if k in names)
        named_hit = bool(alltxt) and bool(NAME_RE.search(alltxt))
        keep_water = bool(wtype and (wtype in WATER_ALWAYS or nm)) or named_hit
        if not (keep_track or keep_water):
            continue
        coords = [[float(lo), float(la)] for la, lo in PAIR_RE.findall(line, i)]   # printed "lat / lon" -> [lon, lat]
        if not coords:
            continue
        props = {"id": oid, "osmid": osmid, "plain": plain, "kind": m.group("kind"), "t": types, "a": add}
        if nm:
            props["name"] = nm
        for k in ("name:en", "name:ar"):
            if k in names:
                props[k] = names[k]
        if keep_track:
            surf = next((x.split("-", 1)[1] for x in add + types if x.startswith("surface-")), None)
            tt = next((x.split("-", 1)[1] for x in add + types if x.startswith("tracktype-")), None)
            props.update(hw=hw, surface=surf, tracktype=tt)
            length = haversine_km(coords) * 1000
            if hw in ("unclassified", "service") and not (surf in UNPAVED or tt or length >= 500):
                continue
            props["length_m"] = round(length, 1)
            tracks.append({"type": "Feature", "properties": props,
                           "geometry": {"type": "LineString", "coordinates": simplify(coords, 400)}})
        if keep_water:
            props["wtype"] = wtype
            props["name_class"] = [c for c, rx in NAME_CLASS if rx.search(alltxt)]
            closed = len(coords) >= 4 and coords[0] == coords[-1]
            if m.group("kind") in ("Point", "Poi"):
                geom = {"type": "Point", "coordinates": coords[0]}
            elif closed or m.group("kind") in ("Area", "Multipolygon"):
                ring = simplify(coords, 120)
                if ring[0] != ring[-1]:
                    ring = ring + [ring[0]]
                geom = {"type": "Polygon", "coordinates": [ring]}
                props["perimeter_m"] = round(haversine_km(coords) * 1000, 1)
            else:
                geom = {"type": "LineString", "coordinates": simplify(coords, 200)}
                props["length_m"] = round(haversine_km(coords) * 1000, 1)
            water.append({"type": "Feature", "properties": props, "geometry": geom})
    return {"printed": n_all, "owned": n_owned, "kinds": kinds, "stats": {k: v for k, v in stats.items()},
            "tracks": tracks, "water": water}


def run_tile(args, t):
    key = tile_key(t)
    outp = args.work / "tiles" / f"{key}.json.gz"
    if outp.exists():
        return key, "skip", 0.0
    b = (t[0], t[1], t[0] + STEP, t[1] + STEP)
    cmd = ["nice", "-n", "10", "java", "-Xmx3g", "-cp", "./OsmAndMapCreator.jar:./lib/*",
           "net.osmand.obf.BinaryInspector", "-vmap", "-vmapobjects", "-vmapcoordinates", f"-zoom={args.zoom}",
           f"-bbox={b[0]},{b[3]},{b[2]},{b[1]}", str(args.obf)]
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=args.inspector_dir, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    res = parse_tile_stream((ln.decode("utf-8", "replace") for ln in p.stdout), b)
    rc = p.wait()
    if rc != 0:
        raise RuntimeError(f"inspector rc={rc} tile {key}")
    res.update(tile=key, bounds=b, zoom=args.zoom, seconds=round(time.time() - t0, 1))
    tmp = outp.with_suffix(".tmp")
    with gzip.open(tmp, "wt", encoding="utf-8", compresslevel=6) as f:
        json.dump(res, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, outp)
    return key, "ok", res["seconds"]


def extract(args):
    (args.work / "tiles").mkdir(parents=True, exist_ok=True)
    tiles = tile_list()
    if args.priority_only:
        tiles = [t for t in tiles if priority_rank(t) < len(PRIORITY)]
    tiles.sort(key=lambda t: (priority_rank(t), t))
    todo = [t for t in tiles if not (args.work / "tiles" / f"{tile_key(t)}.json.gz").exists()]
    log = open(args.work / "extract.log", "a", buffering=1)
    print(f"{time.strftime('%F %T')} tiles total={len(tiles)} todo={len(todo)} jobs={args.jobs}", file=log)
    done = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for key, st, sec in ex.map(lambda t: run_tile(args, t), todo):
            done += 1
            el = time.time() - t0
            eta = el / done * (len(todo) - done)
            print(f"{time.strftime('%T')} {done}/{len(todo)} {key} {st} {sec}s eta={eta/60:.1f}min", file=log)
    print("done", file=log)


def merge(args):
    files = sorted((args.work / "tiles").glob("*.json.gz"))
    tracks, water = [], []
    stats = collections.defaultdict(lambda: [0, 0, 0])
    kinds = collections.Counter()
    covered = []
    for f in files:
        d = json.load(gzip.open(f, "rt", encoding="utf-8"))
        covered.append(d["bounds"])
        tracks += d["tracks"]
        water += d["water"]
        kinds.update(d["kinds"])
        for k, v in d["stats"].items():
            s = stats[k]
            for i in range(3):
                s[i] += v[i]

    def dump(path, feats):
        with gzip.open(path, "wt", encoding="utf-8", compresslevel=9) as fh:
            json.dump({"type": "FeatureCollection", "features": feats}, fh, ensure_ascii=False, separators=(",", ":"))

    dump(args.work / "tracks.geojson.gz", tracks)
    dump(args.work / "fayad_wadi_sabkha.geojson.gz", water)
    tr_cls = collections.defaultdict(lambda: {"n": 0, "km": 0.0, "plain_osm_way_id": 0, "named": 0})
    for ft in tracks:
        p = ft["properties"]
        c = tr_cls[p["hw"]]
        c["n"] += 1
        c["km"] += p["length_m"] / 1000
        c["plain_osm_way_id"] += 1 if p["plain"] else 0
        c["named"] += 1 if p.get("name") else 0
    w_cls = collections.defaultdict(lambda: {"n": 0, "plain_osm_way_id": 0})
    name_cls = collections.Counter()
    for ft in water:
        p = ft["properties"]
        k = p.get("wtype") or "named_only"
        w_cls[k]["n"] += 1
        w_cls[k]["plain_osm_way_id"] += 1 if p["plain"] else 0
        for c in p.get("name_class", []):
            name_cls[c] += 1
    n_total = sum(v[0] for v in stats.values())
    n_plain = sum(v[1] for v in stats.values())
    n_noid = sum(v[2] for v in stats.values())
    manifest = {
        "source": args.source_label, "rights": args.rights, "zoom": args.zoom, "tile_step_deg": STEP,
        "tiles_done": len(files), "tiles_planned": len(tile_list()),
        "coverage_bounds": [min(b[0] for b in covered), min(b[1] for b in covered),
                            max(b[2] for b in covered), max(b[3] for b in covered)] if covered else None,
        "objects_owned_total": n_total, "objects_plain_osm_way_id": n_plain, "objects_without_osmid": n_noid,
        "objects_other_id_structure": n_total - n_plain - n_noid,
        "kinds": dict(kinds),
        "tracks": {"features": len(tracks), "km_total": round(sum(v["km"] for v in tr_cls.values()), 1),
                   "by_highway": {k: {**v, "km": round(v["km"], 1)} for k, v in tr_cls.items()}},
        "fayad_wadi_sabkha": {"features": len(water), "by_type": dict(w_cls), "by_name_class": dict(name_cls)},
        "type_counts_main": {k: v for k, v in sorted(stats.items(), key=lambda kv: -kv[1][0])[:300]},
    }
    (args.work / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    print(json.dumps({k: manifest[k] for k in ("tiles_done", "tiles_planned", "objects_owned_total",
                                                "objects_plain_osm_way_id", "objects_without_osmid")}, indent=1))
    print("tracks", manifest["tracks"]["features"], manifest["tracks"]["km_total"], "km; water", len(water))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--obf", type=Path, required=True)
    ap.add_argument("--inspector-dir", type=Path, required=True, help="folder with OsmAndMapCreator.jar and lib/")
    ap.add_argument("--work", type=Path, required=True, help="output folder (outside git!)")
    ap.add_argument("--zoom", type=int, default=16)
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--priority-only", action="store_true")
    ap.add_argument("--merge", action="store_true", help="only assemble outputs from finished tiles")
    ap.add_argument("--source-label", default="rahal_export_2026-11-12 (OsmAnd obf Saudi-arabia_asia, edition 2026-11-01)")
    ap.add_argument("--rights", default="owner-declared: explicit permission")
    args = ap.parse_args()
    args.obf, args.inspector_dir, args.work = args.obf.resolve(), args.inspector_dir.resolve(), args.work.resolve()
    if args.merge:
        merge(args)
    else:
        extract(args)
        merge(args)


if __name__ == "__main__":
    sys.exit(main())
