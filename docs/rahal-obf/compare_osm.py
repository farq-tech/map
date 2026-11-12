#!/usr/bin/env python3
"""Measure how much of an OBF extraction is NEW compared with an OSM extract.

Inputs
  --tracks     tracks.geojson.gz              (from extract_obf.py)
  --water      fayad_wadi_sabkha.geojson.gz   (from extract_obf.py)
  --osm-pbf    OSM .pbf (e.g. Geofabrik gcc-states-latest.osm.pbf; read with pyosmium)
  --weak-labels optional OSM-derived GeoJSON (saudi_osm_desert_tracks_weak_labels.geojson) - second geometric reference
Outputs (in --out)
  compare_report.json        all numbers
  tracks_scored.json.gz      per OBF track: osmid-in-OSM, tag agreement, cover15/cover30 (share of length within 15/30 m of OSM)

Tests
  1. id test      : does the OBF osmid exist as an OSM way (highway/waterway/natural/...)? and do tags agree?
  2. geometry test: densify OBF tracks every ~12 m, share of points within 15/30 m of ANY OSM highway,
                    and of OSM track/path/bridleway only.
  3. reverse test : share of OSM track/path ways (inside the OBF coverage) whose id is present in the OBF extraction.
  4. names test   : OBF named water/wadi/fayad features whose name exists in OSM.
Needs: pyosmium, shapely>=2, numpy. Third-party data must stay outside git.
"""
from __future__ import annotations

import argparse
import collections
import gzip
import json
import math
import sys
import time
from array import array
from pathlib import Path

import numpy as np
import shapely
from shapely import STRtree

TRACKISH = {"track", "path", "bridleway"}
FOCUS = (33.5, 15.5, 56.5, 33.0)
M_LAT = 110574.0
M_LON = 111320.0
MAX_WAY_ID = 1 << 34


def log(*a):
    print(time.strftime("%T"), *a, file=sys.stderr, flush=True)


def load_gz(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return json.load(f)


# ------------------------------------------------------------------ OSM reading
def read_osm(pbf):
    import osmium
    fp = osmium.FileProcessor(str(pbf)).with_locations().with_filter(
        osmium.filter.KeyFilter("highway", "waterway", "natural", "water", "place", "landuse", "man_made", "amenity", "historic"))
    way_ids = array("q")                       # ids of ways carrying one of the keys (any)
    hw = {}                                    # way id -> (highway, name, tracktype, surface)  (all highway ways)
    geoms = []                                 # (is_trackish, np.array [[lon,lat],...])
    gids = []
    names = set()
    n_nodes = n_ways = n_rels = 0
    for o in fp:
        t = o.tags
        nm = t.get("name")
        if o.is_node():
            n_nodes += 1
            if nm:
                names.add(nm.strip())
            continue
        if o.is_relation():
            n_rels += 1
            if nm:
                names.add(nm.strip())
            continue
        if not o.is_way():
            continue
        n_ways += 1
        way_ids.append(o.id)
        if nm:
            names.add(nm.strip())
        h = t.get("highway")
        if h is None:
            continue
        hw[o.id] = (h, nm or "", t.get("tracktype", ""), t.get("surface", ""))
        try:
            xy = np.array([(n.lon, n.lat) for n in o.nodes], dtype="float64")
        except Exception:
            continue
        if len(xy) < 2 or not (FOCUS[0] <= xy[0, 0] <= FOCUS[2] and FOCUS[1] <= xy[0, 1] <= FOCUS[3]):
            continue
        geoms.append((h in TRACKISH, xy))
        gids.append(o.id)
    log(f"osm read: nodes={n_nodes} ways={n_ways} rels={n_rels} highway_ways={len(hw)} geoms={len(geoms)} names={len(names)}")
    return np.frombuffer(way_ids, dtype="int64").copy(), hw, geoms, np.array(gids, dtype="int64"), names


# ------------------------------------------------------------------ geometry helpers
def densify(coords, step_m=12.0):
    """coords [[lon,lat]...] -> (points Nx2 lon/lat, weights in metres each)"""
    c = np.asarray(coords, dtype="float64")
    if len(c) < 2:
        return c, np.zeros(len(c))
    lat0 = math.radians(c[:, 1].mean())
    dx = np.diff(c[:, 0]) * M_LON * math.cos(lat0)
    dy = np.diff(c[:, 1]) * M_LAT
    seg = np.hypot(dx, dy)
    pts, w = [], []
    for i, L in enumerate(seg):
        n = max(1, int(math.ceil(L / step_m)))
        f = (np.arange(n) + 0.5) / n
        pts.append(c[i] + (c[i + 1] - c[i]) * f[:, None])
        w.append(np.full(n, L / n))
    return np.vstack(pts), np.concatenate(w)


def cell_of(lon, lat):
    return (np.floor(lon).astype(int), np.floor(lat).astype(int))


def osm_cells(geoms, margin=0.02):
    """geoms: list of (trackish, xy). Returns dict 1-degree cell -> indices of OSM ways whose bbox (+margin) touches it."""
    # bbox of every OSM way -> cells
    cells = collections.defaultdict(list)
    for gi, (_, xy) in enumerate(geoms):
        x0, y0 = xy.min(0) - margin
        x1, y1 = xy.max(0) + margin
        for cx in range(int(math.floor(x0)), int(math.floor(x1)) + 1):
            for cy in range(int(math.floor(y0)), int(math.floor(y1)) + 1):
                cells[(cx, cy)].append(gi)
    return cells


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tracks", type=Path, required=True)
    ap.add_argument("--water", type=Path, required=True)
    ap.add_argument("--osm-pbf", type=Path, required=True)
    ap.add_argument("--weak-labels", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--step", type=float, default=12.0)
    ap.add_argument("--reuse-scored", action="store_true", help="reuse cover_* fields from an existing tracks_scored.json.gz")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)

    tr = load_gz(a.tracks)["features"]
    wt = load_gz(a.water)["features"]
    log(f"obf tracks={len(tr)} water={len(wt)}")
    way_ids, hw, geoms, gids, names = read_osm(a.osm_pbf)
    way_ids.sort()

    def way_exists(i):
        j = np.searchsorted(way_ids, i)
        return j < len(way_ids) and way_ids[j] == i

    # ---- 1. id test
    id_stats = collections.Counter()
    agree = collections.Counter()
    by_hw = collections.defaultdict(collections.Counter)
    scored = []
    for k, ft in enumerate(tr):
        p = ft["properties"]
        osmid = p["osmid"]
        rec = {"i": k, "id": p["id"], "osmid": osmid, "hw": p["hw"], "len": p["length_m"], "name": p.get("name", "")}
        if osmid <= 0:
            cls = "no_osmid"
        elif osmid >= MAX_WAY_ID or not p["plain"]:
            cls = "synthetic_id"
        elif osmid in hw:
            cls = "osm_way_found"
            h, nm, tt, sf = hw[osmid]
            rec["osm_hw"] = h
            agree["hw_same" if h == p["hw"] else "hw_differs"] += 1
            if p.get("name") or nm:
                agree["name_same" if (p.get("name", "") == nm) else "name_differs"] += 1
            if p.get("tracktype") or tt:
                agree["tracktype_same" if (p.get("tracktype") or "") == tt else "tracktype_differs"] += 1
            if p.get("surface") or sf:
                agree["surface_same" if (p.get("surface") or "") == sf else "surface_differs"] += 1
        elif way_exists(osmid):
            cls = "osm_way_other_key"
        else:
            cls = "osmid_not_in_osm"
        id_stats[cls] += 1
        by_hw[p["hw"]][cls] += 1
        rec["id_cls"] = cls
        scored.append(rec)
    log("id test", dict(id_stats))

    # ---- 2. geometry test (slow: ~30 min for the whole country; --reuse-scored skips it)
    scored_path = a.out / "tracks_scored.json.gz"
    wgeoms = []
    if a.reuse_scored and scored_path.exists():
        old = load_gz(scored_path)
        for r, o in zip(scored, old):
            r.update({k: v for k, v in o.items() if k.startswith("cover_") or k in ("len_geo", "osm_ways_800m")})
        wgeoms = [1] if "cover_weak30" in old[0] else []
        log("geometry stage reused from", scored_path)
    else:
        cells_osm = osm_cells(geoms)
        wgeoms, cells_weak = [], {}
        if a.weak_labels and a.weak_labels.exists():
            for f in json.load(open(a.weak_labels))["features"]:
                g = f["geometry"]
                parts = [g["coordinates"]] if g["type"] == "LineString" else g["coordinates"]
                for part in parts:
                    if len(part) >= 2:
                        wgeoms.append((False, np.array(part, dtype="float64")))
            cells_weak = osm_cells(wgeoms)
            log(f"weak-label geoms={len(wgeoms)}")
        log(f"osm cells={len(cells_osm)}")
        # densify obf tracks
        all_pts, all_w, owner = [], [], []
        for k, ft in enumerate(tr):
            pts, w = densify(ft["geometry"]["coordinates"], a.step)
            all_pts.append(pts)
            all_w.append(w)
            owner.append(np.full(len(pts), k, dtype="int32"))
        P = np.vstack(all_pts)
        W = np.concatenate(all_w)
        O = np.concatenate(owner)
        d_all = np.full(len(P), np.inf)
        d_trk = np.full(len(P), np.inf)
        d_weak = np.full(len(P), np.inf)
        # one reference point per track (its middle sample) for the neighbourhood-density measure
        first = np.zeros(len(tr), dtype=int)
        cnt = np.bincount(O, minlength=len(tr))
        first[1:] = np.cumsum(cnt)[:-1]
        mid_pt = first + cnt // 2
        is_mid = np.zeros(len(P), dtype=bool)
        is_mid[mid_pt[cnt > 0]] = True
        dens = np.zeros(len(tr), dtype=int)       # OSM highway ways within 800 m of the track middle
        cx, cy = np.floor(P[:, 0]).astype(int), np.floor(P[:, 1]).astype(int)
        key = cx * 1000 + cy
        order = np.argsort(key, kind="stable")
        ks, starts = np.unique(key[order], return_index=True)
        ends = list(starts[1:]) + [len(order)]
        log(f"points={len(P)} cells_with_points={len(ks)}")
        for n, (kk, s, e) in enumerate(zip(ks, starts, ends)):
            idx = order[s:e]
            c = (int(P[idx[0], 0] // 1), int(P[idx[0], 1] // 1))
            gl = cells_osm.get(c, [])
            gw = cells_weak.get(c, [])
            if not gl and not gw:
                continue
            lon_c, lat_c = c[0] + 0.5, c[1] + 0.5
            kx = M_LON * math.cos(math.radians(lat_c))

            def pr(xy):
                return np.column_stack(((xy[:, 0] - lon_c) * kx, (xy[:, 1] - lat_c) * M_LAT))

            g_all = [shapely.linestrings(pr(geoms[g][1])) for g in gl]
            g_trk = [g for g, gi in zip(g_all, gl) if geoms[gi][0]]
            g_weak = [shapely.linestrings(pr(wgeoms[g][1])) for g in gw]
            pts = shapely.points(pr(P[idx]))
            for geomlist, dst in ((g_all, d_all), (g_trk, d_trk), (g_weak, d_weak)):
                if not geomlist:
                    continue
                tree = STRtree(geomlist)
                res = tree.query_nearest(pts, max_distance=30.0, return_distance=True, all_matches=False)
                dst[idx[res[0][0]]] = res[1]
            sel = idx[is_mid[idx]]
            if len(sel) and g_all:
                tree_all = STRtree(g_all)
                pr_pts = shapely.points(pr(P[sel]))
                pairs = tree_all.query(pr_pts, predicate="dwithin", distance=800.0)
                np.add.at(dens, O[sel][pairs[0]], 1)
            if n % 50 == 0:
                log(f"cell {n}/{len(ks)} osm_ways_in_cell={len(gl)} pts={len(idx)}")

        L = np.bincount(O, weights=W, minlength=len(tr))
        out = {}
        for name, d in (("all", d_all), ("trk", d_trk), ("weak", d_weak)):
            for th in (15, 30):
                out[f"{name}{th}"] = np.bincount(O, weights=W * (d <= th), minlength=len(tr))
        for k, rec in enumerate(scored):
            rec["len_geo"] = round(float(L[k]), 1)
            rec["osm_ways_800m"] = int(dens[k])
            for nm_, arr in out.items():
                rec["cover_" + nm_] = round(float(arr[k] / L[k]), 3) if L[k] > 0 else 0.0
        with gzip.open(a.out / "tracks_scored.json.gz", "wt", encoding="utf-8") as f:
            json.dump(scored, f, ensure_ascii=False, separators=(",", ":"))

    L = np.array([r["len_geo"] for r in scored])
    out = {k[6:]: L * np.array([r.get(k, 0.0) for r in scored]) for k in scored[0] if k.startswith("cover_")}
    tot_m = float(L.sum())

    def km(x):
        return round(float(x) / 1000, 1)

    geo = {"obf_track_km": km(tot_m)}
    ref = {"all": "osm_highway(pbf)", "trk": "osm_track_path(pbf)", "weak": "weak_labels(aug-2026 OSM snapshot)"}
    for name in ("all", "trk") + (("weak",) if wgeoms else ()):
        for th in (15, 30):
            cov = float(out[f"{name}{th}"].sum())
            geo[f"km_NOT_within_{th}m_of_{ref[name]}"] = km(tot_m - cov)
            geo[f"share_new_{th}m_vs_{ref[name]}"] = round(1 - cov / tot_m, 4)
    by_class = {}
    for h in sorted({r["hw"] for r in scored}):
        sel = np.array([r["hw"] == h for r in scored])
        t = float(L[sel].sum())
        by_class[h] = {"n": int(sel.sum()), "km": km(t),
                       "km_new_30m_vs_osm_highway": km(t - out["all30"][sel].sum()),
                       "km_new_15m_vs_osm_highway": km(t - out["all15"][sel].sum()),
                       "km_new_30m_vs_weak_labels": km(t - out["weak30"][sel].sum()) if wgeoms else None}
    long_new = [r for r in scored if r["len_geo"] >= 500 and r["cover_all30"] < 0.3]
    geo["tracks_ge500m_mostly_new_30m"] = {"n": len(long_new), "km": km(sum(r["len_geo"] for r in long_new))}

    # ---- 3. reverse test: are the KSA-clipped OSM weak labels (Aug-2026 snapshot, has osm_id) present in the OBF?
    #      (the pbf spans several countries, the OBF is KSA-centred, so the weak labels are the fair reference)
    weak = rev = None
    if a.weak_labels and a.weak_labels.exists():
        wl = json.load(open(a.weak_labels))["features"]
        wl_ids = {int(f["properties"]["osm_id"]) for f in wl if str(f["properties"].get("osm_id", "")).isdigit()}
        obf_ids = {r["osmid"] for r in scored}
        hit = len(wl_ids & obf_ids)
        rev = {"weak_label_osm_ids": len(wl_ids), "present_in_obf_extraction": hit, "share_present": round(hit / len(wl_ids), 4)}
        weak = {"obf_tracks_whose_osmid_in_weak_labels": len(obf_ids & wl_ids),
                "obf_tracks_NOT_in_weak_labels": len(obf_ids - wl_ids)}

    # ---- 4. water / names
    wstat = collections.Counter()
    wnames = collections.defaultdict(collections.Counter)
    missing_names = []
    for ft in wt:
        p = ft["properties"]
        nm = (p.get("name") or "").strip()
        k = p.get("wtype") or "named_only"
        if not nm:
            wstat["unnamed"] += 1
            continue
        ok = nm in names
        wstat["name_in_osm" if ok else "name_NOT_in_osm"] += 1
        wnames[k]["in" if ok else "out"] += 1
        if not ok and len(missing_names) < 200:
            missing_names.append({"name": nm, "wtype": k, "osmid": p["osmid"], "kind": p["kind"]})
    wid = collections.Counter()
    for ft in wt:
        p = ft["properties"]
        if p["kind"] == "Way" and 0 < p["osmid"] < MAX_WAY_ID and p["plain"]:
            wid["way_id_in_osm" if way_exists(p["osmid"]) else "way_id_NOT_in_osm"] += 1
        elif p["kind"] in ("Area", "Multipolygon"):
            wid["area_or_multipolygon (OsmAnd-generated id)"] += 1
        else:
            wid["point_or_other"] += 1

    report = {
        "osm_reference": a.osm_pbf.name, "obf_tracks": len(tr),
        "id_test_tracks": dict(id_stats),
        "id_test_share_found": round(id_stats["osm_way_found"] / max(1, len(tr)), 4),
        "id_test_by_highway": {k: dict(v) for k, v in by_hw.items()},
        "tag_agreement_for_found_ways": dict(agree),
        "geometry_test": geo, "geometry_by_highway": by_class,
        "reverse_test": rev, "weak_labels_test": weak,
        "water_layer": {"features": len(wt), "name_test": dict(wstat), "name_test_by_type": {k: dict(v) for k, v in wnames.items()},
                        "id_test": dict(wid), "names_not_in_osm_sample": missing_names[:60]},
    }
    (a.out / "compare_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(json.dumps({k: report[k] for k in ("id_test_tracks", "id_test_share_found", "geometry_test", "reverse_test")},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.exit(main())
