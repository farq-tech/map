#!/usr/bin/env python3
"""Fetch the raw open data for «دليل البر» into a work directory (never into the repo).

    python3 scripts/desert-gazetteer/fetch.py /path/to/work

Writes:
  work/osm/raw.json                 Overpass answers to queries/*.overpassql, merged (OpenStreetMap, ODbL 1.0)
  work/geonames/SA.txt              GeoNames country dump (CC BY 4.0)
  work/geonames/alt/SA.txt          GeoNames alternate names for SA (language-tagged)
  work/provenance.json              where/when each file came from + sha256 (copied to sources.json by build.py)

Standard library only. Overpass is asked politely (User-Agent, backoff, mirrors).
"""
import glob
import hashlib
import io
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
UA = "SaryAlbarq-desert-gazetteer/1.0 (https://github.com/farq-tech/map)"
OVERPASS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
GEONAMES = {
    "geonames/SA.zip": "https://download.geonames.org/export/dump/SA.zip",
    "geonames/alt/SA.zip": "https://download.geonames.org/export/dump/alternatenames/SA.zip",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def get(url, data=None, timeout=900):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def overpass(query):
    body = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for attempt in range(9):
        url = OVERPASS[attempt % len(OVERPASS)]
        try:
            obj = json.loads(get(url, body))
            if "elements" not in obj:
                raise ValueError("no elements")
            if obj.get("remark") and ("error" in obj["remark"].lower() or "timed out" in obj["remark"].lower()):
                raise ValueError(obj["remark"])
            return url, obj
        except Exception as e:  # noqa: BLE001 (any failure → back off and try the next mirror)
            last = e
            wait = min(240, 10 * 2 ** (attempt // len(OVERPASS)))
            print(f"overpass {url}: {e}; retry in {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise SystemExit(f"Overpass failed: {last}")


def fetch_overpass(work):
    """Each queries/*.overpassql (small, tag-indexed), merged and deduplicated by element."""
    elements, seen, parts, base = [], set(), [], None
    for path in sorted(glob.glob(os.path.join(HERE, "queries", "*.overpassql"))):
        url, obj = overpass(open(path, encoding="utf-8").read())
        base = obj.get("osm3s", {}).get("timestamp_osm_base") or base
        n = 0
        for el in obj["elements"]:
            k = (el["type"], el["id"])
            if k not in seen:
                seen.add(k)
                elements.append(el)
                n += 1
        parts.append({"query": os.path.basename(path), "url": url, "elements": len(obj["elements"]), "new": n})
        print(f"{os.path.basename(path)}: {len(obj['elements'])} elements ({n} new)", file=sys.stderr)
    out = os.path.join(work, "osm", "raw.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"osm3s": {"timestamp_osm_base": base}, "elements": elements}, f, ensure_ascii=False)
    return {"osm_base": base, "queries": parts, "elements": len(elements), "sha256": sha256(out)}


def fetch_geonames(work):
    info = {}
    for rel, url in GEONAMES.items():
        path = os.path.join(work, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(get(url, timeout=300))
        with zipfile.ZipFile(path) as z:
            z.extract("SA.txt", os.path.dirname(path))
        info[rel] = {"url": url, "sha256": sha256(path)}
    return info


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    work = os.path.abspath(sys.argv[1])
    os.makedirs(work, exist_ok=True)
    prov = {"fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if os.environ.get("SKIP_OSM") != "1":
        prov["osm"] = fetch_overpass(work)
    if os.environ.get("SKIP_GEONAMES") != "1":
        prov["geonames"] = fetch_geonames(work)
    old = {}
    p = os.path.join(work, "provenance.json")
    if os.path.exists(p):
        old = json.load(open(p))
    old.update(prov)
    json.dump(old, open(p, "w"), indent=2, ensure_ascii=False)
    print(json.dumps(old, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
