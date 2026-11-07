#!/usr/bin/env python3
"""Build the bundled «دليل البر» from the raw files fetch.py saved.

    python3 scripts/desert-gazetteer/build.py /path/to/work

Reads   work/osm/raw.json, work/geonames/SA.txt, work/geonames/alt/SA.txt, work/provenance.json
        apps/ios/SaryAlbarq/Resources/CampSites/camp-sites-*.geojson (scripts/camp-sites output)
Writes  apps/ios/SaryAlbarq/Resources/DesertGazetteer/desert-gazetteer.json  (the app's file)
        scripts/desert-gazetteer/sources.json                               (provenance + counts)
"""
import glob
import json
import os
import sys
from collections import Counter

import gazetteer as gz

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
APP = os.path.join(ROOT, "apps", "ios", "SaryAlbarq", "Resources")
OUT = os.path.join(APP, "DesertGazetteer", "desert-gazetteer.json")

ATTRIBUTION = [
    "© OpenStreetMap contributors (ODbL 1.0)",
    "GeoNames (geonames.org), CC BY 4.0",
]


# ---------------------------------------------------------------- OSM

def osm_geometry(el):
    """(rings, point) of an Overpass `out geom` element; rings may be []."""
    t = el["type"]
    if t == "node":
        return [], [el["lon"], el["lat"]]
    if t == "way":
        g = [[p["lon"], p["lat"]] for p in el.get("geometry") or [] if p]
        if not g:
            return [], None
        if len(g) >= 4 and g[0] == g[-1]:
            ring = g[:-1]
            return [ring], None
        return [], g[len(g) // 2]
    outers = [[[p["lon"], p["lat"]] for p in m.get("geometry") or [] if p]
              for m in el.get("members", []) if m.get("type") == "way" and m.get("role") in ("outer", "")]
    rings = gz.assemble_rings([w for w in outers if w])
    if rings:
        return rings, None
    for m in el.get("members", []):
        if m.get("type") == "node" and "lon" in m:
            return [], [m["lon"], m["lat"]]
        if m.get("geometry"):
            p = next((q for q in m["geometry"] if q), None)
            if p:
                return [], [p["lon"], p["lat"]]
    return [], None


def from_osm(raw):
    out, seen = [], set()
    for el in raw["elements"]:
        key = f"osm:{el['type']}/{el['id']}"
        if key in seen:
            continue
        seen.add(key)
        tags = el.get("tags") or {}
        kind = gz.osm_kind(tags)
        if not kind:
            continue
        rings, pt = osm_geometry(el)
        ar, en, alts = gz.osm_names(tags)
        e = {"id": key, "kind": kind, "name_ar": ar, "name_en": en, "alt": alts, "sources": [{"id": key, "licence": gz.ODBL}]}
        if tags.get("wikidata"):
            e["wikidata"] = tags["wikidata"]
        if rings:
            rings = gz.compact_rings(rings)
        if rings:
            e["polygon"] = rings
            e["bbox"] = [round(v, 4) for v in gz.bbox(rings)]
            e["point"] = [round(v, 5) for v in gz.representative_point(rings)]
        elif pt:
            e["point"] = [round(pt[0], 5), round(pt[1], 5)]
        else:
            continue
        if not in_saudi(e["point"]):
            continue
        out.append(e)
    return out


# ---------------------------------------------------------------- GeoNames

def arabic_alternates(path):
    """geonameid → [Arabic names], preferred first (alternatenames/SA.txt, isolanguage = ar)."""
    names = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) < 4 or c[2] not in ("ar", ""):
                continue
            if c[2] == "" and not gz.has_arabic(c[3]):
                continue
            if not gz.has_arabic(c[3]):
                continue
            pref = len(c) > 4 and c[4] == "1"
            lst = names.setdefault(c[1], [])
            if c[3] not in lst:
                lst.insert(0, c[3]) if pref else lst.append(c[3])
    return names


def from_geonames(main_path, alt_path):
    ar_names = arabic_alternates(alt_path)
    out = []
    with open(main_path, encoding="utf-8") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) < 9:
                continue
            gid, name, ascii_, alts, lat, lng, fclass, code = c[0], c[1], c[2], c[3], float(c[4]), float(c[5]), c[6], c[7]
            ars = ar_names.get(gid, []) or [a for a in alts.split(",") if gz.has_arabic(a)]
            ar = ars[0] if ars else None
            kind = gz.geonames_kind(code, name, ascii_, ar)
            if not kind:
                continue
            latin = [a for a in alts.split(",") if a and not gz.has_arabic(a) and a not in (name, ascii_)]
            alt = ars[1:] + ([name] if name != ascii_ else []) + latin[:4]
            key = f"geonames:{gid}"
            out.append({"id": key, "kind": kind, "name_ar": ar, "name_en": ascii_ or name, "alt": alt,
                        "point": [round(lng, 5), round(lat, 5)], "feature_code": code,
                        "sources": [{"id": key, "licence": gz.CC_BY}]})
    return out


# ---------------------------------------------------------------- camp sites (scripts/camp-sites)

CAMP_REGION_AR = {"thumamah": "الثمامة", "dahna": "الدهناء", "nafud": "النفود"}
AR_DIGITS = str.maketrans("0123456789", "٠١٢٣٤٥٦٧٨٩")


def from_camps(pattern):
    out = []
    for path in sorted(glob.glob(pattern)):
        fc = json.load(open(path, encoding="utf-8"))
        props = fc.get("properties", {})
        region_ar = props.get("name")
        for f in fc["features"]:
            p = f["properties"]
            lng, lat = f["geometry"]["coordinates"][:2]
            near = p.get("near_name")
            short = CAMP_REGION_AR.get(p["region"], region_ar)
            rank_ar = str(p["rank"]).translate(AR_DIGITS)
            ar = f"كشتة قرب {near}" if near else f"كشتة {short} {rank_ar}"
            key = f"camp:{p['id']}"
            out.append({"id": key, "kind": "camp", "name_ar": ar, "name_en": f"Camp spot {p['region'].title()} {p['rank']}",
                        "alt": [], "point": [round(lng, 5), round(lat, 5)], "region": p["region"], "rank": p["rank"],
                        "score": p.get("score"),
                        "sources": [{"id": f"camp-sites:{p['id']}", "licence": "ESA WorldCover CC-BY-4.0; Copernicus DEM GLO-30; Copernicus Sentinel-2; OSM ODbL-1.0"}]})
    return out


# ---------------------------------------------------------------- output

# Saudi Arabia, generously (the Overpass area already is SA; GeoNames SA too).
SA_BBOX = (34.4, 16.3, 55.7, 32.2)


def in_saudi(pt):
    return SA_BBOX[0] <= pt[0] <= SA_BBOX[2] and SA_BBOX[1] <= pt[1] <= SA_BBOX[3]


def finalize(entries):
    out = []
    for e in entries:
        if not (e.get("name_ar") or e.get("name_en")):
            continue
        e["alt"] = [a for a in dict.fromkeys(e.get("alt", [])) if a and a not in (e.get("name_ar"), e.get("name_en"))][:6]
        o = {"id": e["id"], "kind": e["kind"], "name_ar": e.get("name_ar"), "name_en": e.get("name_en")}
        if e["alt"]:
            o["alt"] = e["alt"]
        o["point"] = e["point"]
        for k in ("bbox", "polygon", "wikidata", "region", "rank", "score"):
            if e.get(k) is not None:
                o[k] = e[k]
        o["sources"] = e["sources"]
        out.append(o)
    out.sort(key=lambda o: (gz.KINDS.index(o["kind"]), o["id"]))
    return out


def counts(entries):
    by_kind = Counter(e["kind"] for e in entries)
    by_source = Counter()
    for e in entries:
        for s in {x["id"].split(":")[0] for x in e["sources"]}:
            by_source[s] += 1
    return {"total": len(entries), "by_kind": dict(by_kind), "by_source": dict(by_source),
            "with_polygon": sum(1 for e in entries if e.get("polygon")),
            "with_arabic": sum(1 for e in entries if e.get("name_ar"))}


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    work = os.path.abspath(sys.argv[1])
    raw = json.load(open(os.path.join(work, "osm", "raw.json"), encoding="utf-8"))
    osm = from_osm(raw)
    gn = from_geonames(os.path.join(work, "geonames", "SA.txt"), os.path.join(work, "geonames", "alt", "SA.txt"))
    camps = from_camps(os.path.join(APP, "CampSites", "camp-sites-*.geojson"))
    merged = finalize(gz.merge(osm + gn + camps))
    prov = json.load(open(os.path.join(work, "provenance.json"), encoding="utf-8"))
    doc = {
        "version": 1,
        "built_from": {"osm_base": prov.get("osm", {}).get("osm_base"), "geonames_fetched": prov.get("fetched_at")},
        "attribution": ATTRIBUTION + ["أماكن الكشتة المقترحة: ESA WorldCover (CC BY 4.0) · Copernicus DEM GLO-30 · Copernicus Sentinel-2 · © OpenStreetMap"],
        "kinds": list(gz.KINDS),
        "entries": merged,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    c = counts(merged)
    c["raw"] = {"osm": len(osm), "geonames": len(gn), "camp": len(camps)}
    c["bytes"] = os.path.getsize(OUT)
    json.dump({"provenance": prov, "counts": c}, open(os.path.join(HERE, "sources.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(json.dumps(c, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
