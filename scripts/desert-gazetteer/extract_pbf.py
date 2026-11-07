#!/usr/bin/env python3
"""OSM from a Geofabrik extract instead of Overpass (same selection, same raw.json shape).

    python3 scripts/desert-gazetteer/extract_pbf.py /path/to/gcc-states-latest.osm.pbf /path/to/work

Overpass is the first choice (fetch.py); public Overpass servers are often at capacity, so this
reads the Geofabrik `gcc-states` extract (OpenStreetMap, ODbL 1.0) with pyosmium and keeps what
lies inside Saudi Arabia's admin_level=2 boundary from the same file. Needs `pip install osmium`.
"""
import hashlib
import json
import os
import sys

import osmium

import gazetteer as gz


def ring(r):
    return [{"lat": round(n.lat, 6), "lon": round(n.lon, 6)} for n in r]


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    pbf, work = sys.argv[1], os.path.abspath(sys.argv[2])
    elements, sa = [], []
    fp = osmium.FileProcessor(pbf).with_locations().with_areas()
    for o in fp:
        tags = {t.k: t.v for t in o.tags}
        if o.is_area():
            if tags.get("boundary") == "administrative" and tags.get("admin_level") == "2" and tags.get("ISO3166-1") == "SA":
                sa += [[[n.lon, n.lat] for n in r] for r in o.outer_rings()]
                continue
            if not gz.osm_candidate(tags):
                continue
            outers = [ring(r) for r in o.outer_rings()]
            if o.from_way():
                elements.append({"type": "way", "id": o.orig_id(), "tags": tags, "geometry": outers[0] if outers else []})
            else:
                elements.append({"type": "relation", "id": o.orig_id(), "tags": tags,
                                 "members": [{"type": "way", "role": "outer", "geometry": g} for g in outers]})
        elif o.is_node():
            if gz.osm_candidate(tags) and o.location.valid():
                elements.append({"type": "node", "id": o.id, "lat": o.location.lat, "lon": o.location.lon, "tags": tags})
        elif o.is_way():
            if gz.osm_candidate(tags) and not o.is_closed():
                try:
                    elements.append({"type": "way", "id": o.id, "tags": tags, "geometry": ring(o.nodes)})
                except osmium.InvalidLocationError:
                    pass
    if not sa:
        raise SystemExit("no Saudi admin_level=2 boundary in the extract")
    sa = [r for r in gz.compact_rings(sa, max_points=6000)]

    def point(el):
        if el["type"] == "node":
            return [el["lon"], el["lat"]]
        g = el.get("geometry") or (el["members"][0]["geometry"] if el.get("members") else [])
        if not g:
            return None
        xs, ys = [p["lon"] for p in g], [p["lat"] for p in g]
        return [sum(xs) / len(xs), sum(ys) / len(ys)]

    kept = [el for el in elements if (p := point(el)) and gz.inside_any(p, sa)]
    out = os.path.join(work, "osm", "raw.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    h = hashlib.sha256()
    with open(pbf, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    hdr = osmium.io.Reader(pbf, osmium.osm.osm_entity_bits.NOTHING).header()
    base = hdr.get("osmosis_replication_timestamp")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"osm3s": {"timestamp_osm_base": base}, "elements": kept}, f, ensure_ascii=False)
    prov_path = os.path.join(work, "provenance.json")
    prov = json.load(open(prov_path)) if os.path.exists(prov_path) else {}
    prov["osm"] = {"source": "geofabrik", "file": os.path.basename(os.path.realpath(pbf)), "osm_base": base,
                   "pbf_sha256": h.hexdigest(), "elements": len(kept), "outside_saudi_dropped": len(elements) - len(kept)}
    json.dump(prov, open(prov_path, "w"), indent=2, ensure_ascii=False)
    print(json.dumps(prov["osm"], indent=2))


if __name__ == "__main__":
    main()
